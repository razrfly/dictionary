defmodule DevilsDictionary.Artworks do
  @moduledoc "Local reusable artwork catalog, source-specific details, meaning candidates, and withdrawal."

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionRevision}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Discovery
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

  @catalog_limit 24
  @catalog_max 100
  @candidate_scan_limit 500
  @mapping_path Application.app_dir(:devils_dictionary, "priv/artworks/meaning-mappings-v1.json")

  @doc "Searches reusable local artwork identities by title or creator name. No provider call."
  def search(query \\ "", opts \\ []) do
    catalog(query, opts).items
  end

  @doc "Returns a bounded local catalog page with stable pagination metadata."
  def catalog(query \\ "", opts \\ []) do
    query = String.trim(query || "")
    limit = (opts[:limit] || @catalog_limit) |> max(1) |> min(@catalog_max)
    page = (opts[:page] || 1) |> max(1)
    offset = (page - 1) * limit
    pattern = "%#{escape_like(query)}%"
    gene_matches = artsy_gene_matches(pattern)

    visible_creators =
      AssertionRevision
      |> where([revision], revision.is_current and revision.lifecycle_state == :active)
      |> Claims.visible(:public)

    base =
      from entity in Entity,
        join: object in Object,
        on: object.id == entity.object_id and object.lifecycle_state == :active,
        join: details in WorkDetails,
        on: details.entity_id == entity.object_id and details.work_kind == "artwork",
        left_join: revision in subquery(visible_creators),
        on: revision.subject_object_id == entity.object_id and revision.is_current,
        left_join: predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "authored_by",
        left_join: creator in Entity,
        on:
          creator.object_id == revision.object_object_id and
            not is_nil(predicate.id),
        left_join: gene_match in subquery(gene_matches),
        on: gene_match.object_id == entity.object_id,
        where:
          ^(query == "") or ilike(entity.preferred_label, ^pattern) or
            ilike(creator.preferred_label, ^pattern) or not is_nil(gene_match.object_id),
        distinct: entity.object_id,
        select: entity.object_id

    count = Repo.aggregate(base, :count)

    entities =
      Repo.all(
        from entity in Entity,
          join: candidate in subquery(base),
          on: candidate.object_id == entity.object_id,
          order_by: [asc: entity.preferred_label, asc: entity.object_id],
          limit: ^limit,
          offset: ^offset,
          select: entity
      )

    %{
      items: views(entities),
      count: count,
      page: page,
      page_size: limit,
      previous_page: if(page > 1, do: page - 1),
      next_page: if(offset + length(entities) < count, do: page + 1)
    }
  end

  @doc "Returns one reusable artwork view by local object identity, or nil."
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

    sense_ids = Enum.map(senses, & &1.id)

    mappings =
      Repo.all(
        from mapping in Mapping,
          join: source in Source,
          on: source.id == mapping.source_id and source.slug == "artsy" and source.active,
          where:
            mapping.enabled and mapping.operation == "artwork_gene_candidate" and
              mapping.target_object_id in ^sense_ids,
          select: mapping
      )

    assignments = active_artsy_assignments()
    catalog = Map.new(search("", limit: @candidate_scan_limit), &{&1.object_id, &1})

    for sense <- senses,
        mapping <- mappings,
        mapping.target_object_id == sense.id,
        assignment <- assignments,
        gene_matches?(mapping.parameters["gene_id"], assignment.genes),
        artwork = catalog[assignment.object_id],
        not is_nil(artwork) do
      %{
        artwork: artwork,
        sense_id: sense.id,
        meaning: sense.gloss,
        language: sense.language,
        mapping_id: mapping.id,
        source_record_revision_id: assignment.source_record_revision_id,
        match_type: mapping.parameters["match_type"],
        match_reason: %{
          provider: "Artsy",
          kind: "direct_gene_assignment",
          gene_id: mapping.parameters["gene_id"],
          gene_name: mapping.parameters["gene_name"],
          mapping_version: mapping.version,
          note: mapping.parameters["note"]
        },
        review_state: :not_yet_reviewed
      }
    end
    |> Enum.uniq_by(&{&1.artwork.object_id, &1.sense_id, &1.match_reason.gene_id})
  end

  @doc "Installs versioned Artsy-gene recipes for exact, stable source senses."
  def install_meaning_mappings! do
    %{sources: sources} = DevilsDictionary.Sources.Catalog.seed!()
    source = Map.fetch!(sources, "artsy")
    actor = mapping_actor!()

    meaning_mappings()
    |> Enum.reduce(%{installed: 0, unchanged: 0, unavailable: 0}, fn definition, stats ->
      if definition["enabled"] == true and is_binary(definition["gene_id"]) do
        case exact_sense(definition["sense_source_slug"], definition["sense_external_key"]) do
          nil ->
            %{stats | unavailable: stats.unavailable + 1}

          sense_id ->
            key = "artsy-gene:#{definition["gene_id"]}:sense:#{sense_id}"

            parameters = %{
              "gene_id" => definition["gene_id"],
              "gene_name" => definition["gene_name"],
              "match_type" => definition["match_type"],
              "note" => definition["note"],
              "mapping_review_status" => definition["mapping_review_status"],
              "mapping_review_actor" => definition["mapping_review_actor"],
              "mapping_reviewed_at" => definition["mapping_reviewed_at"],
              "mapping_review_basis" => definition["mapping_review_basis"],
              "sense_source_slug" => definition["sense_source_slug"],
              "sense_external_key" => definition["sense_external_key"],
              "candidate_only" => true
            }

            case Repo.one(
                   from mapping in Mapping,
                     where: mapping.mapping_key == ^key and mapping.enabled,
                     order_by: [desc: mapping.version],
                     limit: 1
                 ) do
              %Mapping{
                target_object_id: ^sense_id,
                operation: "artwork_gene_candidate",
                parameters: ^parameters
              } ->
                %{stats | unchanged: stats.unchanged + 1}

              _ ->
                {:ok, _mapping} =
                  Discovery.create_mapping_version(key, %{
                    target_object_id: sense_id,
                    source_id: source.id,
                    operation: "artwork_gene_candidate",
                    parameters: parameters,
                    configured_by_actor_id: actor.id,
                    enabled: true
                  })

                %{stats | installed: stats.installed + 1}
            end
        end
      else
        %{stats | unavailable: stats.unavailable + 1}
      end
    end)
  end

  @doc """
  Disables Artsy and removes its disallowed payloads and projections.

  Independently supported objects, Wikidata P11005 slugs, Met/Wikidata fields,
  and editorial claims remain. Artsy-only opaque IDs are rejected, Artsy source
  claims are withdrawn, cache rows become undisplayable, and raw revisions are
  physically removed.
  """
  def withdraw_artsy(reason) when is_binary(reason) and byte_size(reason) > 0 do
    _ = DevilsDictionary.Artsy.RequestCoordinator.disable()

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
                (identifier.namespace in ["artsy_artwork_id", "artsy_artist_id"] or
                   (identifier.namespace in ["artsy_artwork_slug", "artsy_artist_slug"] and
                      fragment("?->>'asserted_by' = 'artsy'", identifier.metadata))),
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
        description: entity.description || (source && source.artwork["description"]),
        image_url: view.image_url || (source && source.artwork["thumbnail_url"]),
        image_attribution: view.image_attribution || (source && source.artwork["image_rights"]),
        qid: view.qid,
        wikipedia_title: view.wikipedia_title,
        creators: Map.get(creators, entity.object_id, []),
        artsy: source && source.artwork,
        genes: (source && source.genes) || [],
        source_record_id: source && source.source_record_id,
        source_record_revision_id: source && source.source_record_revision_id,
        date: source && source.artwork["date"],
        medium: source && source.artwork["medium"],
        collection: source && source.artwork["collecting_institution"],
        freshness: source && source.freshness,
        source_links:
          Enum.reject(
            [
              view.qid && %{label: "Wikidata", url: "https://www.wikidata.org/wiki/#{view.qid}"},
              view.wikipedia_title &&
                %{
                  label: "Wikipedia",
                  url: "https://en.wikipedia.org/wiki/#{URI.encode(view.wikipedia_title)}"
                },
              source && source.artwork["permalink"] &&
                %{label: "Artsy", url: source.artwork["permalink"]}
            ],
            &is_nil/1
          )
      }
    end)
  end

  defp artsy_gene_matches(pattern) do
    from output in MaterializedOutput,
      join: record in SourceRecord,
      on: record.id == output.source_record_id and record.display_allowed,
      join: source in Source,
      on: source.id == record.source_id and source.slug == "artsy" and source.active,
      join: revision in SourceRecordRevision,
      on: revision.source_record_id == record.id and revision.revision_key == record.content_hash,
      where: is_nil(output.retired_at),
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'genes', '[]'::jsonb)) AS gene WHERE gene->>'name' ILIKE ?)",
          revision.payload,
          ^pattern
        ),
      distinct: output.output_object_id,
      select: %{object_id: output.output_object_id}
  end

  defp creators([]), do: %{}

  defp creators(work_ids) do
    query =
      AssertionRevision
      |> where(
        [revision],
        revision.subject_object_id in ^work_ids and revision.is_current and
          revision.lifecycle_state == :active
      )
      |> Claims.visible(:public)
      |> join(:inner, [revision], predicate in Claims.Predicate,
        as: :artwork_predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "authored_by"
      )
      |> join(:inner, [revision], creator in Entity,
        as: :artwork_creator,
        on: creator.object_id == revision.object_object_id
      )
      |> join(:inner, [artwork_creator: creator], object in Object,
        on: object.id == creator.object_id and object.lifecycle_state == :active
      )
      |> order_by([artwork_creator: creator],
        asc: creator.preferred_label,
        asc: creator.object_id
      )
      |> select(
        [revision, artwork_creator: creator],
        {revision.subject_object_id,
         %{object_id: creator.object_id, label: creator.preferred_label}}
      )

    Repo.all(query)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {work_id, creators} -> {work_id, Enum.uniq_by(creators, & &1.object_id)} end)
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
          source_record_revision_id: revision.id,
          artwork: revision.payload["artwork"],
          genes: revision.payload["genes"],
          freshness: revision.payload["freshness"]
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
    |> Enum.map(fn {object_id, detail} ->
      %{
        object_id: object_id,
        genes: detail.genes || [],
        source_record_revision_id: detail.source_record_revision_id
      }
    end)
  end

  defp meaning_mappings do
    @mapping_path |> File.read!() |> Jason.decode!() |> Map.fetch!("mappings")
  end

  defp gene_matches?(gene_id, genes) when is_binary(gene_id),
    do: Enum.any?(genes, &(&1["id"] == gene_id))

  defp gene_matches?(_gene_id, _genes), do: false

  defp exact_sense(source_slug, external_key) do
    Repo.one(
      from sense in Sense,
        join: source in Source,
        on: source.id == sense.source_id,
        where: source.slug == ^source_slug and sense.external_key == ^external_key,
        select: sense.object_id
    )
  end

  defp mapping_actor! do
    attrs = %{
      actor_kind: :import,
      label: "Artsy meaning mapping registry",
      metadata: %{"operation" => "artwork_gene_candidate"}
    }

    Repo.get_by(Actor, actor_kind: :import, label: attrs.label) ||
      Repo.insert!(%Actor{} |> Actor.changeset(attrs))
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
