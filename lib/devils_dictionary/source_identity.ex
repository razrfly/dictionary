defmodule DevilsDictionary.SourceIdentity do
  @moduledoc """
  Resolves approved source records into the existing object registry.

  Exact verified identifiers are the only automatic merge evidence. All usable
  identifiers are locked and resolved before a new object is minted, so
  retries and concurrent imports converge. If identifiers point at different
  objects, disagree with an object's exclusive identifier, or imply an
  incompatible subtype, the resolver opens an existing reconciliation case and
  does not pick a winner.

  Entities came first (film works, #93). Since #164 the same resolver persists
  **content** — a quotation or a passage is a `content_items` row with a first
  revision, matched on its identifiers exactly as an entity is — and acts on an
  entry's **relationships**: each creator the provider identified is matched or
  minted and credited with one assertion, in the subject's own transaction. See
  `DevilsDictionary.SourceIdentity.Creators`.

  ## The transaction boundary (#164 C1)

  `resolve/2` never touches the network. Whatever a relationship needs from
  Wikidata is fetched first, by `Creators.prepare/2`, and handed in as
  `prepared:`. Inside, `lock_entries/2` takes one sorted set of advisory locks
  over the subject's identifiers, its source record **and every creator key**,
  so two runs crediting the same absent person serialise on that person and
  the second one finds the first one's row.
  """

  import Ecto.Query

  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    ExternalIdentifier,
    Object,
    PersonDetails,
    WorkDetails
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Creators
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.SourceIdentity.Resolution
  alias DevilsDictionary.Sources.{MaterializedOutput, ReconciliationCase}

  @conflict_kind "external_identifier_conflict"

  @doc """
  Resolves an adapter entry without consulting labels for identity.

  Options: `prepared:` — `Creators.prepare/2`'s map, without which a creator
  the registry does not already hold is deferred rather than fetched — and
  `adapter_version:`, recorded on every assertion the relationships write.
  """
  def resolve(entry, opts \\ [])

  def resolve(%Entry{eligibility: eligibility} = entry, _opts) when eligibility != :eligible do
    %Resolution{
      state: :insufficient_evidence,
      reason: entry.eligibility_reason || to_string(eligibility),
      identifiers: entry.identifiers
    }
  end

  def resolve(%Entry{retention: retention} = entry, _opts) when retention != :durable do
    %Resolution{
      state: :insufficient_evidence,
      reason: "transient_record",
      identifiers: entry.identifiers
    }
  end

  def resolve(%Entry{} = entry, opts) do
    prepared = Keyword.get(opts, :prepared, %{})

    {:ok, resolution} =
      Repo.transaction(fn ->
        lock_entries([entry], prepared)

        entry
        |> resolve_subject()
        |> credit(entry, prepared, opts)
      end)

    resolution
  end

  # A subject that resolved gets its relationships; a conflict or an
  # ineligible entry credits nobody, because there is no identity to credit.
  defp credit(%Resolution{state: state, object_id: object_id} = resolution, entry, prepared, opts)
       when state in [:matched, :newly_created] and is_integer(object_id) do
    %{resolution | relationships: Creators.apply(entry, object_id, prepared, opts)}
  end

  defp credit(resolution, _entry, _prepared, _opts), do: resolution

  defp resolve_subject(%Entry{object_kind: :content} = entry) do
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

        case content_conflicts(entry, object_id) do
          [] ->
            add_alternate_text(object_id, entry)
            ensure_identifiers(object_id, entry)
            attach_source_record(object_id, entry, "content")
            matched(entry, object_id)

          conflicts ->
            conflict(entry, matches, "identifier_or_subtype_contradiction", conflicts)
        end

      true ->
        {:ok, item} = create_content(entry)
        ensure_identifiers(item.object_id, entry)
        attach_source_record(item.object_id, entry, "content")
        created(entry, item.object_id)
    end
  end

  defp resolve_subject(%Entry{} = entry) do
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
  end

  @doc """
  Acquires one deterministic transaction-lock set for adapter entries.

  The set is every entry's identifiers and source record, **and** every
  relationship target — plus, given the prepared map, the QID each Open
  Library author key crosswalked to (#164 C1). Sorted and deduplicated across
  the whole batch, so two runs that share any key take it in the same order and
  cannot deadlock on each other.
  """
  def lock_entries(entries, prepared \\ %{}) when is_list(entries) do
    entries
    |> Enum.flat_map(&lock_keys(&1, prepared))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn key ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    end)

    :ok
  end

  @doc "The advisory-lock keys one entry needs, creators included."
  def lock_keys(%Entry{} = entry, prepared \\ %{}) do
    Enum.map(entry.identifiers, &"#{&1.namespace}:#{&1.external_id}") ++
      if(entry.source_record_id, do: ["source-record:#{entry.source_record_id}"], else: []) ++
      Enum.map(Creators.targets([entry]), fn {namespace, external_id} ->
        "#{namespace}:#{external_id}"
      end) ++ Creators.crosswalk_lock_keys(entry, prepared)
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

  # The content twin of `compatibility_conflicts/2`: the identifiers matched
  # an object, and it has to be content of the same kind. A quotation id that
  # lands on a definition is a contradiction to review, not a text to append.
  defp content_conflicts(entry, object_id) do
    object = Repo.one(from object in Object, where: object.id == ^object_id, lock: "FOR UPDATE")
    item = Repo.get(ContentItem, object_id)

    cond do
      is_nil(object) or object.kind != :content or is_nil(item) ->
        ["object_kind"]

      item.content_kind != entry.content_kind ->
        ["content_kind:#{item.content_kind}:#{entry.content_kind}"]

      true ->
        []
    end
  end

  defp create_content(%Entry{content: content} = entry) do
    Registry.create_content(%{
      content_kind: entry.content_kind,
      original_language: entry.original_language,
      source_id: entry.source_id,
      body: content.body,
      body_format: content.body_format,
      canonical_url: content.canonical_url,
      headword: content.headword || entry.label,
      year: content.year || entry.year,
      rights_metadata: content.rights_metadata,
      metadata: %{"source_slug" => entry.source_slug},
      source_record_revision_id: entry.source_record_revision_id
    })
  end

  # #164 C2. The same identifiers with the same text are the same item and
  # nothing is written. A different text from a source is recorded beside the
  # current one and does **not** replace it: the first source's wording stays
  # current until a person or build 5's verifier decides otherwise. "Same" is
  # compared against every revision, so a second source's variant is recorded
  # once and not again on each of its refreshes.
  #
  # "Same" means the same fingerprint (#158 build 3, ADR 0003): a full stop,
  # a curly quote or a capital is transcription, not a second text, and a
  # different wording is still recorded. The revisions are few per item, so
  # they are read and normalised here rather than fingerprinted in SQL.
  defp add_alternate_text(object_id, %Entry{content: content} = entry) do
    fingerprint = Fingerprint.fingerprint(content.body)

    known? =
      from(revision in ContentRevision,
        where: revision.content_id == ^object_id,
        select: revision.body
      )
      |> Repo.all()
      |> Enum.any?(fn body ->
        body == content.body or
          (is_binary(fingerprint) and Fingerprint.fingerprint(body) == fingerprint)
      end)

    unless known? do
      Repo.query!("SELECT 1 FROM content_items WHERE object_id = $1 FOR UPDATE", [object_id])

      next =
        (Repo.one(
           from revision in ContentRevision,
             where: revision.content_id == ^object_id,
             select: max(revision.revision_number)
         ) || 0) + 1

      %ContentRevision{}
      |> ContentRevision.changeset(%{
        content_id: object_id,
        revision_number: next,
        is_current: false,
        body: content.body,
        body_format: content.body_format,
        canonical_url: content.canonical_url,
        headword: content.headword || entry.label,
        year: content.year || entry.year,
        rights_metadata: content.rights_metadata,
        metadata: %{"source_slug" => entry.source_slug, "alternate_text" => true},
        source_record_revision_id: entry.source_record_revision_id
      })
      |> Repo.insert!()
    end

    :ok
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

  defp attach_source_record(object_id, entry, role \\ "entity")

  defp attach_source_record(_object_id, %Entry{source_record_id: nil}, _role), do: :ok

  defp attach_source_record(object_id, entry, role) do
    stable = entry.stable_identifier
    now = DateTime.utc_now()

    attrs = %{
      source_record_id: entry.source_record_id,
      output_role: role,
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
