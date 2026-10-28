defmodule DevilsDictionary.Curation.ShelfCitations do
  @moduledoc "Exact observation binding, immutable citations and expiry independent of cleanup."
  import Ecto.Query
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Discovery.{Result, Run, Policy}
  alias DevilsDictionary.Sources.{Source, SourceRecord}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Curation.{Digest, Shelf, ShelfCitation}

  def citable(%{object_id: id}), do: citable(id)

  def citable(id) when is_integer(id) do
    DevilsDictionary.Discovery.citation_results(id)
    |> Enum.map(fn {result, run} -> observation(result, run) end)
  end

  def citable(_), do: []

  def observation(%Result{} = result, %Run{} = run) do
    run = Repo.preload(run, mapping: :source)
    source = run.mapping.source
    revision = bound_revision(result)
    record = result.source_record_id && Repo.get(SourceRecord, result.source_record_id)
    policy = Policy.for!(source.slug)
    captured? = not is_nil(run.retention_policy_sha256)
    real_expiry? = run.expires_at && DateTime.compare(run.expires_at, run.completed_at) == :gt

    expiry =
      if real_expiry?,
        do: run.expires_at,
        else: DateTime.add(run.completed_at, policy.retention_seconds)

    status =
      cond do
        DateTime.compare(
          DateTime.utc_now(),
          min_time(expiry, DateTime.add(run.completed_at, policy.retention_seconds))
        ) != :lt ->
          :retention_expired

        not source.active ->
          :source_inactive

        not result.display_allowed or not run.display_allowed or is_nil(record) or
            not record.display_allowed ->
          :display_restricted

        is_nil(revision) ->
          :observation_unbound

        true ->
          case DevilsDictionary.Curation.Eligibility.shelf_object_status(
                 result.object_id,
                 revision.id
               ) do
            :ok -> :ok
            {:error, reason} -> reason
          end
      end

    %{
      result: result,
      run: run,
      mapping: run.mapping,
      source: source,
      record: record,
      revision: revision,
      payload: revision && revision.payload,
      observed_at: run.completed_at,
      expires_at: expiry,
      policy: policy,
      status: status,
      kind: Shelf.kind(source.slug),
      policy_state:
        if(captured?,
          do: "captured",
          else: if(real_expiry?, do: "legacy_not_recorded", else: "legacy_fallback")
        )
    }
  end

  def bound_revision(%Result{source_record_id: nil}), do: nil

  def bound_revision(%Result{source_record_revision_id: id, source_record_id: record_id} = result) do
    query =
      from r in SourceRecordRevision,
        where: r.source_record_id == ^record_id,
        where: fragment("?->'match_details' = ?::jsonb", r.payload, ^result.match_details),
        where:
          fragment(
            "?->'preview_metadata' = ?::jsonb",
            r.payload,
            ^Map.delete(result.preview_metadata, "creators")
          ),
        where: fragment("?->>'external_namespace' = ?", r.payload, ^result.external_namespace),
        where: fragment("?->>'external_id' = ?", r.payload, ^result.external_id),
        select: %{r | payload: r.payload}

    rows = Repo.all(if id, do: from(r in query, where: r.id == ^id), else: query)

    case rows do
      [revision] -> revision
      _ -> nil
    end
  end

  def cite(spec, %{composition_id: composition_id, actor_id: actor_id}) do
    if result = Repo.get(Result, spec[:result] || spec["result"]) do
      run = Repo.get!(Run, result.run_id) |> Repo.preload(:mapping)
      digest = Digest.sha256(result.external_namespace <> ":" <> result.external_id)

      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
        "discovery:#{run.mapping.source_id}:#{digest}"
      ])

      Repo.query!("SELECT id FROM source_records WHERE id=$1 FOR UPDATE", [
        result.source_record_id
      ])
    end

    with %Result{} = result <- Repo.get(Result, spec[:result] || spec["result"]),
         %Run{} = run <- Repo.get(Run, result.run_id),
         o = observation(result, run),
         true <- o.status == :ok,
         true <- exact?(o, spec),
         true <-
           Repo.exists?(
             from m in "editorial_composition_memberships",
               where:
                 m.composition_id == ^composition_id and
                   m.object_id == ^o.mapping.target_object_id
           ) do
      context = %{
        o.source.slug => %{seconds: o.policy.retention_seconds, hash: Shelf.policy_hash(o.policy)}
      }

      Repo.query!("SELECT set_config('devils_dictionary.citation_policy_context',$1,true)", [
        Jason.encode!(context)
      ])

      case Repo.get_by(ShelfCitation, discovery_result_id: result.id) do
        %ShelfCitation{} = existing ->
          {:ok, existing}

        nil ->
          date = Shelf.date(o.source.slug, result.preview_metadata)

          match =
            List.first(
              DevilsDictionary.Discovery.MatchReason.from_result(result.match_details, nil)
            )

          attrs = %{
            source_id: o.source.id,
            external_ref_sha256:
              Digest.sha256(result.external_namespace <> ":" <> result.external_id),
            cited_source_record_id: result.source_record_id,
            cited_revision_id: o.revision.id,
            cited_checksum: o.revision.checksum,
            cited_object_id: result.object_id,
            source_record_id: result.source_record_id,
            source_record_revision_id: o.revision.id,
            discovery_result_id: result.id,
            discovery_run_id: run.id,
            mapping_id: run.mapping_id,
            target_object_id: o.mapping.target_object_id,
            adapter_version: run.adapter_version,
            observed_at: run.completed_at,
            expires_at: o.expires_at,
            expiry_origin:
              if(o.policy_state == "legacy_fallback", do: "legacy_fallback", else: "captured_run"),
            retention_seconds:
              if(o.policy_state == "legacy_fallback",
                do: o.policy.retention_seconds,
                else: run.retention_seconds
              ),
            policy_sha256: run.retention_policy_sha256,
            fallback_policy_sha256:
              if(o.policy_state == "legacy_fallback", do: Shelf.policy_hash(o.policy)),
            observation_policy_state: o.policy_state,
            field_policy: "shelf-fields-v1",
            shelf_kind: o.kind,
            content_date_meaning: date.meaning,
            content_date_precision: date.precision,
            match_kind: scalar(match && match.kind),
            match_evidence:
              scalar(match && DevilsDictionary.Discovery.MatchReason.evidence(match)),
            match_relation: scalar(match && match.relation),
            match_level: scalar(match && match.level),
            link_sha256:
              result.preview_metadata["source_url"] &&
                Digest.sha256(result.preview_metadata["source_url"]),
            created_by_actor_id: actor_id
          }

          {:ok, Repo.insert!(struct(ShelfCitation, attrs))}
      end
    else
      nil -> {:error, :observation_unbound}
      false -> {:error, :observation_mismatch_or_ineligible}
    end
  end

  @doc false
  def expired?(%ShelfCitation{} = c, now \\ DateTime.utc_now()) do
    source = Repo.get!(Source, c.source_id)

    DateTime.compare(
      now,
      min_time(c.expires_at, DateTime.add(c.observed_at, Policy.retention_seconds(source.slug)))
    ) != :lt
  end

  def check(%ShelfCitation{} = c, now \\ DateTime.utc_now()) do
    source = Repo.get(Source, c.source_id)

    deadline =
      min_time(c.expires_at, DateTime.add(c.observed_at, Policy.retention_seconds(source.slug)))

    cond do
      DateTime.compare(now, deadline) != :lt ->
        :retention_expired

      is_nil(c.source_record_revision_id) ->
        :revision_deleted

      true ->
        revision =
          Repo.one(
            from r in SourceRecordRevision,
              where: r.id == ^c.source_record_revision_id,
              select: %{r | payload: r.payload}
          )

        record = c.source_record_id && Repo.get(SourceRecord, c.source_record_id)

        cond do
          is_nil(revision) -> :revision_deleted
          Map.has_key?(revision.payload, "_discovery_redaction") -> :payload_redacted
          not source.active -> :source_inactive
          is_nil(record) or not record.display_allowed -> :display_restricted
          true -> :ok
        end
    end
  end

  @doc false
  def spec_status(spec, revision_id) do
    field = fn key -> spec[key] || spec[Atom.to_string(key)] end
    run_id = field.(:run)

    run =
      (is_integer(run_id) && Repo.get(Run, run_id))
      |> then(&(&1 && Repo.preload(&1, mapping: :source)))

    revision =
      revision_id &&
        Repo.one(
          from r in SourceRecordRevision,
            where: r.id == ^revision_id,
            select: %{r | payload: r.payload}
        )

    captured = spec_time(field.(:expires_at))

    citation =
      if is_integer(field.(:result)),
        do: Repo.get_by(ShelfCitation, discovery_result_id: field.(:result)),
        else: nil

    observed =
      if run,
        do: run.completed_at,
        else: spec_time(field.(:observed_at)) || (citation && citation.observed_at)

    slug =
      if run,
        do: run.mapping.source.slug,
        else: field.(:source_slug) || (citation && Repo.get!(Source, citation.source_id).slug)

    deadline =
      if captured && observed && slug in Shelf.providers(),
        do: min_time(captured, DateTime.add(observed, Policy.retention_seconds(slug))),
        else: captured

    cond do
      deadline && DateTime.compare(DateTime.utc_now(), deadline) != :lt -> :retention_expired
      is_nil(revision) -> :revision_deleted
      Map.has_key?(revision.payload, "_discovery_redaction") -> :payload_redacted
      true -> :ok
    end
  end

  defp spec_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp spec_time(_), do: nil

  def get(id), do: Repo.get(ShelfCitation, id)

  def payload(%ShelfCitation{} = c) do
    if check(c) == :ok,
      do:
        Repo.one(
          from r in SourceRecordRevision,
            where: r.id == ^c.source_record_revision_id,
            select: r.payload
        )
  end

  defp exact?(o, spec),
    do:
      Enum.all?(
        [
          {:run, o.run.id},
          {:revision, o.revision.id},
          {:checksum, o.revision.checksum},
          {:expires_at, DateTime.to_iso8601(o.expires_at)},
          {:observed_at, DateTime.to_iso8601(o.observed_at)},
          {:source_slug, o.source.slug},
          {:shelf_kind, o.kind}
        ],
        fn {key, value} -> (spec[key] || spec[Atom.to_string(key)]) == value end
      )

  defp min_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp scalar(nil), do: nil
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_atom(value), do: to_string(value)
  defp scalar(_), do: nil
end
