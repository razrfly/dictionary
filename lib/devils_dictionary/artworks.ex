defmodule DevilsDictionary.Artworks do
  @moduledoc "Local reusable artwork catalog, source-specific details, meaning candidates, and withdrawal."

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionRevision}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Encyclopedia

  alias DevilsDictionary.Registry.{
    Entity,
    ExternalIdentifier,
    Object,
    Sense,
    SenseRevision,
    WorkDetails
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, MaterializedOutput, Source, SourceRecord}

  @catalog_limit 50
  @candidate_scan_limit 500
  @mapping_path Application.app_dir(:devils_dictionary, "priv/artworks/meaning-mappings-v1.json")

  @doc "Searches reusable local artwork identities by title or creator name. No provider call."
  def search(query \\ "", opts \\ []) do
    query = String.trim(query || "")
    limit = opts[:limit] || @catalog_limit
    pattern = "%#{escape_like(query)}%"

    base =
      from entity in Entity,
        join: object in Object,
        on: object.id == entity.object_id and object.lifecycle_state == :active,
        join: details in WorkDetails,
        on: details.entity_id == entity.object_id and details.work_kind == "artwork",
        left_join: revision in AssertionRevision,
        on: revision.subject_object_id == entity.object_id and revision.is_current,
        left_join: predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "authored_by",
        left_join: creator in Entity,
        on: creator.object_id == revision.object_object_id,
        where:
          ^(query == "") or ilike(entity.preferred_label, ^pattern) or
            ilike(creator.preferred_label, ^pattern),
        distinct: entity.object_id,
        order_by: [asc: entity.preferred_label, asc: entity.object_id],
        limit: ^limit,
        select: entity

    entities = Repo.all(base)
    views(entities)
  end

  def get(object_id) when is_integer(object_id) do
    case Repo.one(
           from entity in Entity,
             join: object in Object,
             on: object.id == entity.object_id and object.lifecycle_state == :active,
             join: details in WorkDetails,
             on: details.entity_id == entity.object_id and details.work_kind == "artwork",
             where: entity.object_id == ^object_id,
             select: entity
         ) do
      nil -> nil
      entity -> List.first(views([entity]))
    end
  end

  @doc "Returns local, exact-sense suggestions from direct retained Artsy gene assignments."
  def suggestions(lexeme_ids) when is_list(lexeme_ids) do
    mappings = meaning_mappings()

    senses =
      Repo.all(
        from sense in Sense,
          join: revision in SenseRevision,
          on: revision.sense_id == sense.object_id and revision.is_current,
          join: lexeme in DevilsDictionary.Registry.Lexeme,
          on: lexeme.object_id == sense.lexeme_id,
          where: sense.lexeme_id in ^lexeme_ids and sense.identity_state == :active,
          select: %{
            id: sense.object_id,
            lemma: lexeme.lemma,
            language: lexeme.language_tag,
            gloss: revision.gloss
          }
      )

    assignments = active_artsy_assignments()
    catalog = Map.new(search("", limit: @candidate_scan_limit), &{&1.object_id, &1})

    for sense <- senses,
        mapping <- mappings,
        mapping_matches?(mapping, sense),
        assignment <- assignments,
        gene_matches?(mapping, assignment.genes),
        artwork = catalog[assignment.object_id],
        not is_nil(artwork) do
      %{
        artwork: artwork,
        sense_id: sense.id,
        meaning: sense.gloss,
        language: sense.language,
        match_type: mapping["match_type"],
        match_reason: %{
          provider: "Artsy",
          kind: "direct_gene_assignment",
          gene_id: mapping["gene_id"],
          gene_name: mapping["gene_name"],
          mapping_version: mapping["version"],
          note: mapping["note"]
        },
        review_state: :not_yet_reviewed
      }
    end
    |> Enum.uniq_by(&{&1.artwork.object_id, &1.sense_id, &1.match_reason.gene_id})
  end

  @doc """
  Disables Artsy and removes its disallowed payloads and projections.

  Independently supported objects, Wikidata P11005 slugs, Met/Wikidata fields,
  and editorial claims remain. Artsy-only opaque IDs are rejected, Artsy source
  claims are withdrawn, cache rows become undisplayable, and raw revisions are
  physically removed.
  """
  def withdraw_artsy(reason) when is_binary(reason) and byte_size(reason) > 0 do
    Repo.transaction(fn ->
      source = Repo.one!(from source in Source, where: source.slug == "artsy", lock: "FOR UPDATE")
      actor = withdrawal_actor!()
      now = DateTime.utc_now()

      record_ids =
        Repo.all(
          from record in SourceRecord, where: record.source_id == ^source.id, select: record.id
        )

      revision_ids =
        Repo.all(
          from revision in SourceRecordRevision,
            where: revision.source_record_id in ^record_ids,
            select: revision.id
        )

      identifiers =
        Repo.all(
          from identifier in ExternalIdentifier,
            where:
              identifier.source_record_revision_id in ^revision_ids and
                identifier.namespace in ["artsy_artwork_id", "artsy_artist_id"],
            lock: "FOR UPDATE"
        )

      Enum.each(identifiers, fn identifier ->
        identifier
        |> ExternalIdentifier.changeset(%{
          status: :rejected,
          source_record_revision_id: nil,
          metadata:
            Map.merge(identifier.metadata || %{}, %{
              "withdrawn_source" => "artsy",
              "withdrawal_reason" => reason,
              "withdrawn_at" => DateTime.to_iso8601(now)
            })
        })
        |> Repo.update!()
      end)

      claim_ids =
        Repo.all(
          from assertion in Assertion,
            join: revision in AssertionRevision,
            on: revision.assertion_id == assertion.id and revision.is_current,
            where: assertion.source_id == ^source.id and revision.lifecycle_state == :active,
            select: assertion.id
        )

      Enum.each(claim_ids, &Claims.withdraw(&1, reason: reason))

      # Editorial claims are independently retainable, but an Artsy citation
      # is not. Remove those evidence edges before deleting the raw revisions;
      # source-owned assertions were already withdrawn above.
      {evidence_removed, _} =
        Repo.delete_all(
          from evidence in AssertionEvidence,
            where: evidence.source_record_revision_id in ^revision_ids
        )

      {outputs, _} =
        Repo.update_all(
          from(output in MaterializedOutput, where: output.source_record_id in ^record_ids),
          set: [retired_at: now, updated_at: now]
        )

      {records, _} =
        Repo.update_all(
          from(record in SourceRecord, where: record.id in ^record_ids),
          set: [
            display_allowed: false,
            display_policy_reason: reason,
            display_policy_changed_at: now,
            display_policy_actor_id: actor.id,
            url: nil,
            content_hash: nil,
            updated_at: now
          ]
        )

      Repo.update_all(from(mapping in Mapping, where: mapping.source_id == ^source.id),
        set: [enabled: false, updated_at: now]
      )

      Repo.update_all(
        from(run in Run,
          join: mapping in Mapping,
          on: mapping.id == run.mapping_id,
          where: mapping.source_id == ^source.id
        ),
        set: [display_allowed: false, updated_at: now]
      )

      Repo.update_all(
        from(result in Result,
          join: run in Run,
          on: run.id == result.run_id,
          join: mapping in Mapping,
          on: mapping.id == run.mapping_id,
          where: mapping.source_id == ^source.id
        ),
        set: [display_allowed: false, updated_at: now]
      )

      {payloads, _} =
        Repo.delete_all(
          from revision in SourceRecordRevision, where: revision.id in ^revision_ids
        )

      source
      |> Source.changeset(%{
        active: false,
        discovery_retry_after: nil,
        discovery_retry_reason: reason,
        config:
          Map.merge(source.config || %{}, %{
            "withdrawn_at" => DateTime.to_iso8601(now),
            "withdrawal_reason" => reason
          })
      })
      |> Repo.update!()

      %{
        source: "artsy",
        records_disabled: records,
        payloads_deleted: payloads,
        outputs_retired: outputs,
        identifiers_rejected: length(identifiers),
        claims_withdrawn: length(claim_ids),
        evidence_removed: evidence_removed
      }
    end)
  end

  defp views(entities) do
    ids = Enum.map(entities, & &1.object_id)
    creators = creators(ids)
    details = artsy_details(ids)

    Enum.map(entities, fn entity ->
      view = Encyclopedia.view(entity)
      source = details[entity.object_id]

      %{
        object_id: entity.object_id,
        title: entity.preferred_label,
        description: entity.description,
        image_url: view.image_url,
        qid: view.qid,
        wikipedia_title: view.wikipedia_title,
        creators: Map.get(creators, entity.object_id, []),
        artsy: source && source.artwork,
        genes: (source && source.genes) || [],
        source_record_id: source && source.source_record_id
      }
    end)
  end

  defp creators([]), do: %{}

  defp creators(work_ids) do
    Repo.all(
      from revision in AssertionRevision,
        join: predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "authored_by",
        join: creator in Entity,
        on: creator.object_id == revision.object_object_id,
        join: object in Object,
        on: object.id == creator.object_id and object.lifecycle_state == :active,
        where:
          revision.subject_object_id in ^work_ids and revision.is_current and
            revision.lifecycle_state == :active,
        order_by: [asc: creator.preferred_label, asc: creator.object_id],
        select:
          {revision.subject_object_id,
           %{object_id: creator.object_id, label: creator.preferred_label}}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp artsy_details([]), do: %{}

  defp artsy_details(object_ids) do
    Repo.all(
      from output in MaterializedOutput,
        join: record in SourceRecord,
        on: record.id == output.source_record_id,
        join: source in Source,
        on: source.id == record.source_id and source.slug == "artsy" and source.active,
        join: revision in SourceRecordRevision,
        on:
          revision.source_record_id == record.id and revision.revision_key == record.content_hash,
        where:
          output.output_object_id in ^object_ids and is_nil(output.retired_at) and
            record.display_allowed,
        order_by: [desc: revision.observed_at, desc: revision.id],
        select: %{
          object_id: output.output_object_id,
          source_record_id: record.id,
          artwork: revision.payload["artwork"],
          genes: revision.payload["genes"]
        }
    )
    |> Enum.uniq_by(& &1.object_id)
    |> Map.new(&{&1.object_id, &1})
  end

  defp active_artsy_assignments do
    artsy_details(
      Repo.all(
        from details in WorkDetails,
          join: object in Object,
          on: object.id == details.entity_id and object.lifecycle_state == :active,
          where: details.work_kind == "artwork",
          order_by: details.entity_id,
          limit: @candidate_scan_limit,
          select: details.entity_id
      )
    )
    |> Enum.map(fn {object_id, detail} -> %{object_id: object_id, genes: detail.genes || []} end)
  end

  defp meaning_mappings do
    @mapping_path |> File.read!() |> Jason.decode!() |> Map.fetch!("mappings")
  end

  defp mapping_matches?(mapping, sense) do
    mapping["lemma"] == sense.lemma and mapping["language"] == sense.language and
      gloss_matches?(mapping["gloss_contains"] || [], sense.gloss)
  end

  defp gloss_matches?([], _gloss), do: true

  defp gloss_matches?(terms, gloss) do
    down = String.downcase(gloss || "")
    Enum.any?(terms, &String.contains?(down, String.downcase(&1)))
  end

  defp gene_matches?(mapping, genes) do
    Enum.any?(genes, fn gene ->
      (is_binary(mapping["gene_id"]) and gene["id"] == mapping["gene_id"]) or
        (is_binary(mapping["gene_name"]) and gene["name"] == mapping["gene_name"])
    end)
  end

  defp withdrawal_actor! do
    attrs = %{
      actor_kind: :import,
      label: "Artsy provider withdrawal operation",
      metadata: %{"operation" => "provider_withdrawal"}
    }

    Repo.get_by(Actor, actor_kind: :import, label: attrs.label) ||
      Repo.insert!(%Actor{} |> Actor.changeset(attrs))
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
