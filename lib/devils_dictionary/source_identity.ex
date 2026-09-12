defmodule DevilsDictionary.SourceIdentity do
  @moduledoc """
  Resolves approved source records into the existing object registry.

  Exact verified identifiers are the only automatic merge evidence. All usable
  identifiers are locked and resolved before a new object is minted, so
  retries and concurrent imports converge. If identifiers point at different
  objects, disagree with an object's exclusive identifier, or imply an
  incompatible subtype, the resolver opens an existing reconciliation case and
  does not pick a winner.

  The first implementation creates entity records (especially film works).
  The adapter contract also describes content, creators/authors and retention
  so future artwork and quotation providers do not need a second identity
  system.
  """

  import Ecto.Query

  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    Entity,
    ExternalIdentifier,
    Object,
    PersonDetails,
    WorkDetails
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.SourceIdentity.Resolution
  alias DevilsDictionary.Sources.{MaterializedOutput, ReconciliationCase}

  @conflict_kind "external_identifier_conflict"

  @doc "Resolves an adapter entry without consulting labels for identity."
  def resolve(%Entry{eligibility: eligibility} = entry) when eligibility != :eligible do
    %Resolution{
      state: :insufficient_evidence,
      reason: entry.eligibility_reason || to_string(eligibility),
      identifiers: entry.identifiers
    }
  end

  def resolve(%Entry{retention: retention} = entry) when retention != :durable do
    %Resolution{
      state: :insufficient_evidence,
      reason: "transient_record",
      identifiers: entry.identifiers
    }
  end

  def resolve(%Entry{object_kind: object_kind} = entry) when object_kind != :entity do
    %Resolution{
      state: :insufficient_evidence,
      reason: "object_kind_not_implemented",
      identifiers: entry.identifiers
    }
  end

  def resolve(%Entry{} = entry) do
    {:ok, resolution} =
      Repo.transaction(fn ->
        lock_entries([entry])
        matches = identifier_matches(entry.identifiers)
        object_ids = matches |> Map.values() |> Enum.map(&Registry.canonical_id/1) |> Enum.uniq()
        proposal_conflicts = exclusive_proposal_conflicts(entry.identifiers)

        cond do
          proposal_conflicts != [] ->
            conflict(
              entry,
              matches,
              "source_asserts_multiple_exclusive_identifiers",
              proposal_conflicts
            )

          length(object_ids) > 1 ->
            conflict(entry, matches, "identifiers_resolve_to_different_objects")

          length(object_ids) == 1 ->
            object_id = hd(object_ids)

            case compatibility_conflicts(entry, object_id) do
              [] ->
                {:ok, entity} = enrich_entity(object_id, entry)
                ensure_identifiers(entity.object_id, entry)
                attach_source_record(entity.object_id, entry)
                matched(entry, entity.object_id)

              conflicts ->
                conflict(entry, matches, "identifier_or_subtype_contradiction", conflicts)
            end

          true ->
            {:ok, entity} = create_entity(entry)
            ensure_identifiers(entity.object_id, entry)
            attach_source_record(entity.object_id, entry)
            created(entry, entity.object_id)
        end
      end)

    resolution
  end

  @doc "Acquires one deterministic transaction-lock set for adapter entries."
  def lock_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&lock_keys/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn key ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    end)

    :ok
  end

  defp lock_keys(%Entry{} = entry) do
    Enum.map(entry.identifiers, &"#{&1.namespace}:#{&1.external_id}") ++
      if(entry.source_record_id, do: ["source-record:#{entry.source_record_id}"], else: [])
  end

  defp identifier_matches([]), do: %{}

  defp identifier_matches(identifiers) do
    namespaces = identifiers |> Enum.map(& &1.namespace) |> Enum.uniq()
    external_ids = identifiers |> Enum.map(& &1.external_id) |> Enum.uniq()
    wanted = MapSet.new(identifiers, &{&1.namespace, &1.external_id})

    ExternalIdentifier
    |> where(
      [identifier],
      identifier.status == :verified and identifier.namespace in ^namespaces and
        identifier.external_id in ^external_ids
    )
    |> select([identifier], {
      identifier.namespace,
      identifier.external_id,
      identifier.object_id
    })
    |> Repo.all()
    |> Enum.filter(fn {namespace, external_id, _object_id} ->
      MapSet.member?(wanted, {namespace, external_id})
    end)
    |> Map.new(fn {namespace, external_id, object_id} ->
      {{namespace, external_id}, object_id}
    end)
  end

  defp exclusive_proposal_conflicts(identifiers) do
    identifiers
    |> Enum.filter(& &1.exclusive)
    |> Enum.group_by(& &1.namespace, & &1.external_id)
    |> Enum.flat_map(fn {namespace, external_ids} ->
      case Enum.uniq(external_ids) do
        [_one] -> []
        many -> ["#{namespace}:#{Enum.join(Enum.sort(many), ",")}"]
      end
    end)
  end

  defp compatibility_conflicts(entry, object_id) do
    object = Repo.one(from object in Object, where: object.id == ^object_id, lock: "FOR UPDATE")

    entity =
      Repo.one(from entity in Entity, where: entity.object_id == ^object_id, lock: "FOR UPDATE")

    kind_conflicts =
      cond do
        is_nil(object) or object.kind != :entity or is_nil(entity) -> ["object_kind"]
        entity.entity_kind == entry.entity_kind -> []
        entity.entity_kind == :concept -> []
        true -> ["entity_kind:#{entity.entity_kind}:#{entry.entity_kind}"]
      end

    subtype_conflicts =
      case {entry.entity_kind, Repo.get(WorkDetails, object_id)} do
        {:work, %WorkDetails{work_kind: held}}
        when is_binary(held) and is_binary(entry.work_kind) and held != entry.work_kind ->
          ["work_kind:#{held}:#{entry.work_kind}"]

        _ ->
          []
      end

    exclusive = Enum.filter(entry.identifiers, & &1.exclusive)
    namespaces = exclusive |> Enum.map(& &1.namespace) |> Enum.uniq()

    held =
      ExternalIdentifier
      |> where(
        [identifier],
        identifier.object_id == ^object_id and identifier.status == :verified and
          identifier.namespace in ^namespaces
      )
      |> select([identifier], {identifier.namespace, identifier.external_id})
      |> Repo.all()

    expected = MapSet.new(exclusive, &{&1.namespace, &1.external_id})

    identifier_conflicts =
      for {namespace, external_id} <- held,
          not MapSet.member?(expected, {namespace, external_id}) do
        "#{namespace}:#{external_id}"
      end

    kind_conflicts ++ subtype_conflicts ++ identifier_conflicts
  end

  defp create_entity(%Entry{entity_kind: :work} = entry) do
    Registry.create_work(%{
      preferred_label: entry.label,
      description: entry.description,
      metadata: evidence_metadata(entry.metadata, entry),
      work_kind: entry.work_kind,
      original_language: entry.original_language,
      first_published_year: entry.year
    })
  end

  defp create_entity(%Entry{entity_kind: :person} = entry) do
    Registry.create_person(%{
      preferred_label: entry.label,
      description: entry.description,
      metadata: entry.metadata
    })
  end

  defp create_entity(%Entry{} = entry) do
    Registry.create_entity(%{
      entity_kind: entry.entity_kind,
      preferred_label: entry.label,
      description: entry.description,
      metadata: entry.metadata
    })
  end

  defp enrich_entity(object_id, entry) do
    entity = Repo.get!(Entity, object_id)

    target_kind =
      if(entity.entity_kind == :concept, do: entry.entity_kind, else: entity.entity_kind)

    # A concept label is a provisional encyclopedia title (often carrying a
    # disambiguation suffix). When exact identifiers sharpen that object into a
    # typed work, the typed adapter's label becomes the display title. The
    # object id remains unchanged, so the former slug still redirects safely.
    preferred_label =
      if entity.entity_kind == :concept and target_kind != :concept,
        do: first_present(entry.label, entity.preferred_label),
        else: first_present(entity.preferred_label, entry.label)

    entity =
      entity
      |> Entity.changeset(%{
        entity_kind: target_kind,
        preferred_label: preferred_label,
        description: first_present(entity.description, entry.description),
        metadata: evidence_metadata(fill_missing(entity.metadata, entry.metadata), entry)
      })
      |> Repo.update!()

    case target_kind do
      :work -> ensure_work_details(object_id, entry)
      :person -> ensure_person_details(object_id)
      _ -> :ok
    end

    {:ok, entity}
  end

  defp ensure_work_details(object_id, entry) do
    attrs = %{
      entity_id: object_id,
      work_kind: entry.work_kind,
      original_language: entry.original_language,
      first_published_year: entry.year
    }

    case Repo.get(WorkDetails, object_id) do
      nil ->
        %WorkDetails{} |> WorkDetails.changeset(attrs) |> Repo.insert!()

      details ->
        details
        |> WorkDetails.changeset(%{
          work_kind: first_present(details.work_kind, entry.work_kind),
          original_language: first_present(details.original_language, entry.original_language),
          first_published_year: details.first_published_year || entry.year
        })
        |> Repo.update!()
    end
  end

  defp ensure_person_details(object_id) do
    if is_nil(Repo.get(PersonDetails, object_id)) do
      %PersonDetails{}
      |> PersonDetails.changeset(%{entity_id: object_id})
      |> Repo.insert!()
    end
  end

  defp ensure_identifiers(object_id, entry) do
    Enum.each(entry.identifiers, fn identifier ->
      case Repo.get_by(ExternalIdentifier,
             namespace: identifier.namespace,
             external_id: identifier.external_id,
             status: :verified
           ) do
        nil ->
          {:ok, _identifier} =
            Registry.add_external_id(object_id, identifier.namespace, identifier.external_id, %{
              metadata:
                Map.merge(identifier.metadata, %{
                  "asserted_by" => entry.source_slug,
                  "identity_evidence" => "exact_source_identifier"
                }),
              source_record_revision_id: entry.source_record_revision_id
            })

        %ExternalIdentifier{object_id: ^object_id} = held ->
          held
          |> ExternalIdentifier.changeset(%{
            metadata: Map.merge(held.metadata, identifier.metadata),
            source_record_revision_id:
              held.source_record_revision_id || entry.source_record_revision_id
          })
          |> Repo.update!()
      end
    end)
  end

  defp attach_source_record(_object_id, %Entry{source_record_id: nil}), do: :ok

  defp attach_source_record(object_id, entry) do
    stable = entry.stable_identifier
    now = DateTime.utc_now()

    attrs = %{
      source_record_id: entry.source_record_id,
      output_role: "entity",
      output_key: "source_identity:#{stable.namespace}:#{stable.external_id}",
      output_object_id: object_id,
      last_seen_run_id: entry.import_run_id,
      retired_at: nil,
      inserted_at: now,
      updated_at: now
    }

    %MaterializedOutput{}
    |> MaterializedOutput.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:output_object_id, :last_seen_run_id, :retired_at, :updated_at]},
      conflict_target: [:source_record_id, :output_role, :output_key]
    )
  end

  defp conflict(entry, matches, reason, details \\ []) do
    payload = %{
      "reason" => reason,
      "details" => details,
      "identifiers" =>
        Enum.map(
          entry.identifiers,
          &%{"namespace" => &1.namespace, "external_id" => &1.external_id}
        ),
      "matched_objects" =>
        Enum.map(matches, fn {{namespace, external_id}, object_id} ->
          %{"namespace" => namespace, "external_id" => external_id, "object_id" => object_id}
        end)
    }

    object_id = matches |> Map.values() |> Enum.uniq() |> List.first()
    now = DateTime.utc_now()

    attrs = %{
      source_id: entry.source_id,
      source_record_id: entry.source_record_id,
      kind: @conflict_kind,
      object_id: object_id,
      payload: payload,
      status: :open
    }

    case open_conflict(entry.source_record_id) do
      nil ->
        %ReconciliationCase{}
        |> ReconciliationCase.changeset(attrs)
        |> Repo.insert!()

      existing ->
        existing
        |> ReconciliationCase.changeset(%{object_id: object_id, payload: payload})
        |> Ecto.Changeset.change(updated_at: now)
        |> Repo.update!()
    end
    |> then(fn kase ->
      %Resolution{
        state: :conflicting_identifiers,
        conflict_id: kase.id,
        reason: reason,
        identifiers: entry.identifiers
      }
    end)
  end

  defp open_conflict(nil), do: nil

  defp open_conflict(source_record_id) do
    Repo.one(
      from kase in ReconciliationCase,
        where:
          kase.source_record_id == ^source_record_id and kase.kind == ^@conflict_kind and
            kase.status == :open,
        lock: "FOR UPDATE"
    )
  end

  defp matched(entry, object_id) do
    %Resolution{state: :matched, object_id: object_id, identifiers: entry.identifiers}
  end

  defp created(entry, object_id) do
    %Resolution{state: :newly_created, object_id: object_id, identifiers: entry.identifiers}
  end

  defp evidence_metadata(metadata, entry) do
    if entry.source_record_id do
      evidence = metadata["source_identity_evidence"] || %{}

      evidence =
        Enum.reduce(["image_url"], evidence, fn field, acc ->
          if present?(entry.metadata[field]) and metadata[field] == entry.metadata[field],
            do: Map.put(acc, field, entry.source_record_id),
            else: acc
        end)

      Map.put(metadata, "source_identity_evidence", evidence)
    else
      metadata
    end
  end

  defp fill_missing(held, offered) do
    Map.merge(offered || %{}, held || %{}, fn _key, offered_value, held_value ->
      if present?(held_value), do: held_value, else: offered_value
    end)
  end

  defp first_present(held, offered), do: if(present?(held), do: held, else: offered)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(value), do: value != %{} and value != []
end
