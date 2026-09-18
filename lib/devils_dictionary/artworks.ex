defmodule DevilsDictionary.Artworks do
  @moduledoc "Local reusable artwork catalog, source-specific details, meaning candidates, and withdrawal."

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionRevision}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, MatchReason, Result, Run, Shelf}
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
  @candidate_page_size 500
  @suggestion_limit 12
  @qid_catalog_limit 24
  @qid_source_limit 12
  @mapping_file "artworks/meaning-mappings-v1.json"

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

  @doc """
  Local, exact suggestions for a page's lexemes, from the whole catalog.

  Two independent kinds of evidence, one section. The Artsy pilot's evidence is a
  retained **gene assignment** on a source record. The Met's and Wikidata's is a
  **depicted QID**: the catalog records what each work depicts (a Met subject tag
  or a `P180` statement, both carrying QIDs), the encyclopedia records what a
  meaning refers to, and an equal QID is the match — the same identity-not-text
  rule (D11) the Phase 2a provider matches on, asked of the committed corpus
  instead of a live search.

  Neither path makes a provider call, and the result is one list so a page shows
  one artwork section.

  ## Options

    * `:exclude_met_object_ids` — Met object ids to leave out, so a work already
      on the page's discovery shelf is not also offered here. Defaults to the
      ids this page's own persisted Met results already carry.
    * `:per_work` — keep one candidate per work before the limit is applied, so
      a work matching several meanings does not take several of the slots.
      `shelf_items/2` asks for this; the default offers every (work, meaning).
  """
  def suggestions(lexeme_ids, opts \\ []) when is_list(lexeme_ids) do
    senses = page_senses(lexeme_ids)

    (artsy_suggestions(senses) ++ qid_suggestions(lexeme_ids, senses, opts))
    |> Enum.uniq_by(&{&1.artwork.object_id, &1.sense_id})
    |> per_work(opts[:per_work])
    |> interleave_by_source()
    |> Enum.take(@suggestion_limit)
  end

  # One candidate per work, kept *before* the limit is applied: a work that
  # matches two meanings would otherwise hold two of the twelve slots and push
  # a distinct work off the end, which is not what one-item-per-work promises.
  # The first candidate in the merged order survives, with its sense and reason.
  #
  # The dedup is the shelf's own (`Shelf.dedup/2`, #116 M3), keyed on the one
  # identity every catalog work has. The shelf dedups again at read time
  # across everything on it — a live Met result and the catalog's copy of the
  # same object — but that happens after the limit, which is why this call
  # stays.
  defp per_work(candidates, true),
    do: Shelf.dedup(candidates, &[{:object, &1.artwork.object_id}])

  defp per_work(candidates, _), do: candidates

  @doc """
  The page's catalog candidates as items for the shared shelf.

  K2 of #109: every result renders through `DevilsDictionaryWeb.Culture.section`
  keyed by the content-type table, live or from a corpus, so a corpus candidate
  is a shelf item with a match reason rather than a tall card of its own. The
  tall `#artwork-candidates` section this replaced was the second artwork chrome
  on `/define/soldier`, beside the Met's compact shelf.

  One item per **work**, not per (work, meaning): a shelf is addressed by
  identity, and the same picture twice under two glosses is the duplicate the
  compact chrome cannot explain. The reason names the meaning it matched, and
  the candidates arrive already interleaved across their catalog sources.

  The shape is a live `Discovery.Result`'s shape — `external_namespace`,
  `external_id`, `object_id`, `preview_metadata` — plus the pre-built
  `match_reasons`, which is how the renderer tells a corpus item from a
  persisted one without knowing that either exists.
  """
  def shelf_items(lexeme_ids, opts \\ []) when is_list(lexeme_ids) do
    candidates = suggestions(lexeme_ids, Keyword.put(opts, :per_work, true))
    tiers = source_tiers(candidates)
    Enum.map(candidates, &shelf_item(&1, tiers))
  end

  defp shelf_item(candidate, tiers) do
    artwork = candidate.artwork
    slug = catalog_slug(artwork)

    %{
      # Which source this item is, for the shelf's own interleave (#116 M2):
      # the catalog is one state carrying several corpora, and the rail takes
      # turns between them only if each item says which it came from.
      source_slug: slug,
      source_tier: tiers[slug],
      # `"c"` and not the bare object id: a local identity and a Met object id
      # are both integers, and two items on one shelf whose DOM ids collided
      # would be an invisible bug.
      external_namespace: "catalog_artwork",
      external_id: "c#{artwork.object_id}",
      object_id: artwork.object_id,
      preview_metadata: %{
        "title" => artwork.title,
        "year" => artwork.date,
        "image_url" => artwork.image_url,
        "thumbnail_url" => artwork.image_url,
        "source_url" => source_url(artwork),
        "credit_line" => artwork.image_attribution,
        "artist" => shelf_artist(artwork),
        "content_type" => "artwork",
        "provider" => shelf_provider(artwork)
      },
      match_reasons: [MatchReason.from_candidate(candidate)],
      review_state: candidate.review_state,
      sense_id: candidate.sense_id,
      source_record_revision_id: candidate.source_record_revision_id
    }
  end

  # Whoever made it, however the catalog knows them. A local `authored_by`
  # identity is the better answer and only some works have one; a manifest row's
  # display name is the rest. The shelf shows a name either way rather than
  # showing the Mona Lisa with no Leonardo on it.
  defp shelf_artist(%{creators: [_ | _] = creators}),
    do: Enum.map_join(creators, ", ", & &1.label)

  defp shelf_artist(%{artist: artist}) when is_binary(artist), do: artist
  defp shelf_artist(_artwork), do: nil

  # Who the shelf credits. A committed corpus names itself; the Artsy pilot's 43
  # works reached the registry by another route and carry no `catalog_source`,
  # so their retained payload is what names them.
  defp shelf_provider(%{catalog_provider: provider}) when is_binary(provider), do: provider
  defp shelf_provider(%{artsy: artsy}) when is_map(artsy), do: "Artsy"
  defp shelf_provider(_artwork), do: nil

  # The holding institution's own page for the work comes first: the shelf names
  # the catalog provider, so *Source ↗* should reach what it named. Wikidata and
  # Wikipedia are the fallback for a work reachable only there — the Mona Lisa.
  defp source_url(artwork) do
    label = shelf_provider(artwork)

    case Enum.find(artwork.source_links, &(&1.label == label)) do
      %{url: url} -> url
      nil -> artwork.source_links |> List.first(%{}) |> Map.get(:url)
    end
  end

  defp page_senses(lexeme_ids) do
    Repo.all(
      from sense in Sense,
        join: revision in SenseRevision,
        on: revision.sense_id == sense.object_id and revision.is_current,
        join: lexeme in DevilsDictionary.Registry.Lexeme,
        on: lexeme.object_id == sense.lexeme_id,
        where: sense.lexeme_id in ^lexeme_ids and sense.identity_state == :active,
        order_by: [asc: sense.object_id],
        select: %{
          id: sense.object_id,
          lexeme_id: sense.lexeme_id,
          lemma: lexeme.lemma,
          language: lexeme.language_tag,
          gloss: revision.gloss
        }
    )
  end

  defp artsy_suggestions(senses) do
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

    assignments = active_artsy_assignments(Enum.map(mappings, & &1.parameters["gene_id"]))
    catalog = artworks_by_ids(Enum.map(assignments, & &1.object_id))

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
          detail: "Artsy gene \u201C#{mapping.parameters["gene_name"]}\u201D",
          locator: "Artsy direct gene #{mapping.parameters["gene_id"]}",
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

  # The QID path. Sense-level `refers_to` is the exact evidence D11 describes;
  # a lexeme-level `lexeme_entity_candidate` is the same QID asserted about the
  # word rather than one of its meanings, so it is admitted and labelled as such
  # rather than silently promoted to a meaning it was never claimed about.
  defp qid_suggestions(lexeme_ids, senses, opts) do
    evidence = sense_qid_evidence(senses) ++ lexeme_qid_evidence(lexeme_ids, senses)
    qids = evidence |> Enum.map(& &1.qid) |> Enum.uniq()

    if qids == [] do
      []
    else
      excluded =
        Keyword.get_lazy(opts, :exclude_met_object_ids, fn ->
          shelved_met_object_ids(lexeme_ids)
        end)

      artworks = depicting_artworks(qids, excluded)
      by_sense = Map.new(senses, &{&1.id, &1})

      for artwork <- artworks,
          item <- artwork.depicts,
          match <- Enum.filter(evidence, &(&1.qid == item["qid"])),
          sense = by_sense[match.sense_id],
          not is_nil(sense) do
        %{
          artwork: artwork,
          sense_id: sense.id,
          meaning: sense.gloss,
          language: sense.language,
          mapping_id: nil,
          source_record_revision_id: nil,
          match_type: if(match.scope == :sense, do: "direct", else: "related"),
          match_reason: %{
            provider: artwork.catalog_provider,
            kind: "depicted_qid",
            detail: qid_detail(match, item),
            locator: "#{artwork.catalog_provider} depiction #{item["qid"]}",
            qid: item["qid"],
            term: item["term"],
            entity_label: match.label,
            scope: match.scope,
            note: qid_note(match, item, artwork)
          },
          review_state: :not_yet_reviewed
        }
      end
      |> Enum.uniq_by(&{&1.artwork.object_id, &1.sense_id})
    end
  end

  # Exact matches before word-level ones, and then one source at a time. Ranking
  # the merged list by sitelinks alone would be the same mistake the catalog
  # query makes without its window: only Wikidata carries that number, so the
  # Met's 1,644 objects sort last and the section's twelve slots go entirely to
  # one source. Interleaving costs nothing and is what makes this one section
  # rather than one source's section.
  #
  # The turn-taking is the shelf's own (`Shelf.interleave/3`, #116 M2), with
  # sources ordered by tier and then slug rather than by a list kept here;
  # the sort is each source's own order, which the interleave preserves.
  # Before the limit, so that both sources get slots; the shelf interleaves
  # again at read time across everything on it, live and catalog alike.
  defp interleave_by_source(candidates) do
    tiers = source_tiers(candidates)

    candidates
    |> Enum.sort_by(&{sort_rank(&1), -(&1.artwork.sitelinks || 0), &1.artwork.object_id})
    |> Shelf.interleave(&sort_rank/1, &source_key(&1.artwork, tiers))
  end

  defp source_key(artwork, tiers) do
    slug = catalog_slug(artwork)
    {Shelf.tier_rank(tiers[slug]), slug || ""}
  end

  # The tier of each catalog source on this page, from the source rows, once
  # per page. A tier is a fact about a source and lives on its row; the
  # candidates carry only the slug.
  defp source_tiers(candidates) do
    slugs =
      candidates
      |> Enum.map(&catalog_slug(&1.artwork))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if slugs == [] do
      %{}
    else
      Repo.all(
        from source in Source, where: source.slug in ^slugs, select: {source.slug, source.tier}
      )
      |> Map.new()
    end
  end

  # Which source a catalog work came from, as the slug of its source row. A
  # committed corpus stamps `catalog_source`; the Artsy pilot's 43 works reached
  # the registry by another route and carry the retained payload instead.
  defp catalog_slug(%{catalog_source: slug}) when is_binary(slug) and slug != "", do: slug
  defp catalog_slug(%{artsy: artsy}) when is_map(artsy), do: "artsy"
  defp catalog_slug(_artwork), do: nil

  defp sort_rank(%{match_type: "direct"}), do: 0
  defp sort_rank(_candidate), do: 1

  defp qid_detail(match, item) do
    subject = "depiction of \u201C#{match.label}\u201D (#{match.qid})"

    case {match.scope, item["term"]} do
      {:sense, nil} -> subject
      {:sense, term} -> subject <> " tagged \u201C#{term}\u201D"
      {:lexeme, _term} -> subject <> ", matched to the word and not to this meaning"
    end
  end

  defp qid_note(match, item, artwork) do
    "The catalog records this work as depicting #{item["qid"]}" <>
      if(item["term"], do: " (\u201C#{item["term"]}\u201D)", else: "") <>
      ", from #{depiction_source(artwork)}. The encyclopedia links this " <>
      "#{if match.scope == :sense, do: "meaning", else: "word"} to #{match.qid}."
  end

  defp depiction_source(%{catalog_source: "met"}), do: "the Met's own subject tags"
  defp depiction_source(%{catalog_source: "wikidata"}), do: "Wikidata P180 depicts"
  defp depiction_source(_artwork), do: "the catalog"

  defp sense_qid_evidence([]), do: []

  defp sense_qid_evidence(senses) do
    sense_ids = Enum.map(senses, & &1.id)

    Repo.all(
      from revision in AssertionRevision,
        join: predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "refers_to",
        join: entity in Entity,
        on: entity.object_id == revision.object_object_id,
        join: identifier in ExternalIdentifier,
        on:
          identifier.object_id == entity.object_id and identifier.namespace == "wikidata" and
            identifier.status == :verified,
        where:
          revision.subject_object_id in ^sense_ids and revision.is_current and
            revision.lifecycle_state == :active,
        order_by: [desc: revision.confidence, asc: entity.object_id],
        select: %{
          qid: identifier.external_id,
          label: entity.preferred_label,
          sense_id: revision.subject_object_id
        }
    )
    |> Enum.map(&Map.put(&1, :scope, :sense))
    |> Enum.uniq_by(&{&1.qid, &1.sense_id})
  end

  # A `lexeme_entity_candidate` names the word, so there is no sense on it. The
  # page's first meaning carries the card, and `scope: :lexeme` is what makes the
  # card say so instead of implying the claim was about that meaning.
  defp lexeme_qid_evidence(_lexeme_ids, []), do: []

  defp lexeme_qid_evidence(lexeme_ids, senses) do
    primary = senses |> Enum.reverse() |> Map.new(&{&1.lexeme_id, &1.id})

    Repo.all(
      from revision in AssertionRevision,
        join: predicate in Claims.Predicate,
        on: predicate.id == revision.predicate_id and predicate.key == "lexeme_entity_candidate",
        join: entity in Entity,
        on: entity.object_id == revision.object_object_id,
        join: identifier in ExternalIdentifier,
        on:
          identifier.object_id == entity.object_id and identifier.namespace == "wikidata" and
            identifier.status == :verified,
        where:
          revision.subject_object_id in ^lexeme_ids and revision.is_current and
            revision.lifecycle_state == :active,
        order_by: [desc: revision.confidence, asc: entity.object_id],
        select: %{
          qid: identifier.external_id,
          label: entity.preferred_label,
          lexeme_id: revision.subject_object_id
        }
    )
    |> Enum.flat_map(fn row ->
      case primary[row.lexeme_id] do
        nil -> []
        sense_id -> [%{qid: row.qid, label: row.label, sense_id: sense_id, scope: :lexeme}]
      end
    end)
    |> Enum.uniq_by(&{&1.qid, &1.sense_id})
  end

  # Whatever the page's own Met shelf is already showing. Offering the same
  # object twice under two headings is the duplicate this guards against; the
  # shelf and the catalog share the `met_object_id` identity, so the comparison
  # is exact rather than by title.
  defp shelved_met_object_ids(lexeme_ids) do
    Repo.all(
      from result in Result,
        join: run in Run,
        on: run.id == result.run_id,
        join: mapping in Mapping,
        on: mapping.id == run.mapping_id,
        where:
          mapping.target_object_id in ^lexeme_ids and result.external_namespace == "met_object" and
            result.display_allowed and run.display_allowed,
        distinct: true,
        select: result.external_id
    )
  end

  # Ranked per catalog source, not across them. Sitelinks are the only quality
  # signal either source carries and only one of them has it, so a single
  # ordering hands every slot to Wikidata and the Met's 1,644 objects never
  # reach a page at all — measured, before this window existed. Each source gets
  # its own top slice and they are merged afterwards.
  defp depicting_artworks(qids, excluded_met_ids) do
    ranked =
      from entity in Entity,
        join: object in Object,
        on: object.id == entity.object_id and object.lifecycle_state == :active,
        join: details in WorkDetails,
        on: details.entity_id == entity.object_id and details.work_kind == "artwork",
        left_join: met in ExternalIdentifier,
        on:
          met.object_id == entity.object_id and met.namespace == "met_object_id" and
            met.status == :verified,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?, '[]'::jsonb)) AS depicted WHERE depicted = ANY(?))",
            entity.metadata["depicts_qids"],
            ^qids
          ),
        where: is_nil(met.external_id) or met.external_id not in ^excluded_met_ids,
        select: %{
          object_id: entity.object_id,
          rank:
            over(row_number(),
              partition_by:
                fragment("COALESCE(? ->> 'catalog_source', 'other')", entity.metadata),
              order_by: [
                desc: fragment("COALESCE((? ->> 'sitelinks')::int, 0)", entity.metadata),
                asc: entity.object_id
              ]
            )
        }

    Repo.all(
      from entity in Entity,
        join: candidate in subquery(ranked),
        on: candidate.object_id == entity.object_id,
        where: candidate.rank <= @qid_source_limit,
        order_by: [
          desc: fragment("COALESCE((? ->> 'sitelinks')::int, 0)", entity.metadata),
          asc: entity.object_id
        ],
        limit: @qid_catalog_limit,
        select: entity
    )
    |> views()
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
    # Nothing to switch off first: the client and its coordinator were retired
    # in #109 Phase 3a, so no Artsy request can be in flight to invalidate.
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
      {image_url, image_attribution} = image_with_credit(view, source)

      %{
        object_id: entity.object_id,
        title: entity.preferred_label,
        description: entity.description || (source && source.artwork["description"]),
        image_url: image_url,
        image_attribution: image_attribution,
        qid: view.qid,
        wikipedia_title: view.wikipedia_title,
        creators: Map.get(creators, entity.object_id, []),
        artsy: source && source.artwork,
        genes: (source && source.genes) || [],
        source_record_id: source && source.source_record_id,
        source_record_revision_id: source && source.source_record_revision_id,
        # A catalog artwork's date, medium and holding institution come from the
        # committed manifest rather than from a retained provider payload, so
        # each falls back to the identity's own metadata. The Artsy pilot's
        # values still win where it has them.
        date: (source && source.artwork["date"]) || entity.metadata["object_date"],
        medium: (source && source.artwork["medium"]) || entity.metadata["medium"],
        collection:
          (source && source.artwork["collecting_institution"]) || entity.metadata["collection"],
        # A display-only artist name. It is not a `creators` entry because that
        # list is of local identities the card links to, and a name on a
        # manifest row is not one.
        artist: entity.metadata["artist_display_name"],
        catalog_source: entity.metadata["catalog_source"],
        catalog_provider: catalog_provider(entity.metadata["catalog_source"]),
        corpus: entity.metadata["corpus"],
        sitelinks: entity.metadata["sitelinks"],
        depicts: List.wrap(entity.metadata["depicts"]),
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
                %{label: "Artsy", url: source.artwork["permalink"]},
              catalog_link(entity.metadata)
            ],
            &is_nil/1
          )
      }
    end)
  end

  defp catalog_provider("met"), do: "The Met"
  defp catalog_provider("wikidata"), do: "Wikidata"

  # No default. An artwork that reached the registry by some other route — the
  # Artsy pilot, or a Phase 2a discovery resolution — is not from a committed
  # corpus, and naming a source it did not come from would be a guess printed
  # as a fact.
  defp catalog_provider(_source), do: nil

  defp catalog_link(%{"catalog_source" => "met", "source_url" => url}) when is_binary(url),
    do: %{label: "The Met", url: url}

  defp catalog_link(_metadata), do: nil

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

  defp active_artsy_assignments([]), do: []

  defp active_artsy_assignments(gene_ids) do
    gene_ids = gene_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    paged_artsy_assignments(gene_ids, 0, [])
  end

  defp paged_artsy_assignments([], _after_id, accumulated), do: accumulated

  defp paged_artsy_assignments(gene_ids, after_id, accumulated) do
    rows =
      Repo.all(
        from output in MaterializedOutput,
          join: record in SourceRecord,
          on: record.id == output.source_record_id and record.display_allowed,
          join: source in Source,
          on: source.id == record.source_id and source.slug == "artsy" and source.active,
          join: revision in SourceRecordRevision,
          on:
            revision.source_record_id == record.id and
              revision.revision_key == record.content_hash,
          join: details in WorkDetails,
          on: details.entity_id == output.output_object_id and details.work_kind == "artwork",
          join: object in Object,
          on: object.id == output.output_object_id and object.lifecycle_state == :active,
          where: is_nil(output.retired_at) and output.output_object_id > ^after_id,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'genes', '[]'::jsonb)) AS gene WHERE gene->>'id' = ANY(?))",
              revision.payload,
              type(^gene_ids, {:array, :string})
            ),
          distinct: output.output_object_id,
          order_by: [asc: output.output_object_id],
          limit: ^@candidate_page_size,
          select: %{
            object_id: output.output_object_id,
            genes: revision.payload["genes"],
            source_record_revision_id: revision.id
          }
      )

    accumulated = accumulated ++ rows

    if length(rows) == @candidate_page_size do
      paged_artsy_assignments(gene_ids, List.last(rows).object_id, accumulated)
    else
      accumulated
    end
  end

  defp artworks_by_ids([]), do: %{}

  defp artworks_by_ids(object_ids) do
    Repo.all(
      from entity in Entity,
        join: object in Object,
        on: object.id == entity.object_id and object.lifecycle_state == :active,
        join: details in WorkDetails,
        on: details.entity_id == entity.object_id and details.work_kind == "artwork",
        where: entity.object_id in ^Enum.uniq(object_ids),
        select: entity
    )
    |> views()
    |> Map.new(&{&1.object_id, &1})
  end

  defp meaning_mappings do
    :devils_dictionary
    |> Application.app_dir(Path.join("priv", @mapping_file))
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("mappings")
  end

  # An image and its credit must describe the same picture. Falling back to the
  # retained Artsy thumbnail while keeping an independent Wikimedia credit would
  # misattribute the displayed image, so the pair is resolved together.
  defp image_with_credit(view, source) do
    cond do
      is_binary(view.image_url) ->
        {view.image_url, view.image_attribution}

      is_binary(source && source.artwork["thumbnail_url"]) ->
        {source.artwork["thumbnail_url"], source.artwork["image_rights"]}

      true ->
        {nil, nil}
    end
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
