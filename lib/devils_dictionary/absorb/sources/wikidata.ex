defmodule DevilsDictionary.Absorb.Sources.Wikidata do
  @moduledoc """
  Things, keyed by QID: labels, descriptions, images, the taxonomy.

  Seed QIDs come from three places that already exist by the time this runs —
  `senses.metadata["wikidata"]` on WordNet senses (a string) and on Wiktionary
  senses (an array), and `pageprops.wikibase_item` discovered by the Wikipedia
  pass. From those leaves it walks **P171 / P279 / P31 / P13176 parents to
  closure**, a tier at a time, so the taxonomy has somewhere to point (L3).

  Two things are worth knowing before reading `materialize/1`:

    * **The everyday concept and the taxon item are different entities.** Q146
      *cat* is a `thing` with an enwiki article; Q20980826 *Felis catus* is the
      `taxon`, carries P225 and P1843, and has **no enwiki sitelink at all**.
      `P13176` is the bridge, and it is what fills `taxon_concept_id`.
    * **An entity is ~130 KB and 142 properties.** `trim/1` keeps fifteen of
      them plus the English labels and the enwiki sitelink. Per the S1b
      contract, `content_hash` is taken on the payload **as fetched**, before
      the trim, so tightening the whitelist never reads as a change at Wikidata.

  Parents are fetched after their children, so `absorb/2` materializes **twice**
  — the second pass with `only_stale: false` — and reports the residual count of
  taxonomy edges whose target was still unknown. It should be zero.
  """

  @behaviour DevilsDictionary.Absorb.Source

  import Ecto.Query

  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Absorb.Clients.Wikidata, as: Client
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Registry.{Entity, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  # A candidate the linker could still promote. `Linker.corroborate/1` lifts a
  # disambiguation candidate to 0.60 when a gloss agrees, so 0.60 is the line
  # between "might yet be this word's thing" and "a page mentioned it once".
  @promotable 0.6

  # The fifteen properties the pipeline reads. Everything else is dropped before
  # storage; a 130 KB entity becomes a couple of KB.
  @keep_properties ~w(P18 P31 P279 P171 P105 P225 P1843 P5063 P8814 P13176 P1420 P910 P373 P846 P685)

  # Parent properties walked to closure. **Only these two**: P171 is the
  # taxonomy proper and terminates at Animalia, and P13176 is the one hop from
  # an everyday concept to its taxon item. P279 and P31 are *recorded* as edges
  # but never chased — following them climbs out of biology into the abstract
  # ontology (40 seeds pulled 1,372 entities and 20 tiers before this was
  # narrowed), and L3 only ever asks about `parent_taxon`.
  @parent_properties ~w(P171 P13176)
  @general_relation_properties ~w(P31 P279)

  # Taxonomic chains run long: species → genus → … → Animalia passes through
  # unranked clades, so 30 is a guard against a cycle, not a real ceiling.
  @max_depth 30
  @max_explicit_qids 100
  @default_explicit_entity_budget 500
  @default_explicit_request_budget 10
  @max_explicit_entity_budget 5_000
  @max_explicit_request_budget 100
  @max_scope_entity_budget 2_000_000
  @max_scope_request_budget 50_000
  @materialize_batch 500
  @record_chunk 500

  @impl true
  def slug, do: "wikidata"

  @impl true
  def rate_limit_ms, do: 200

  @doc "The property whitelist `trim/1` keeps. Read by `Sources.Catalog`."
  def kept_properties, do: @keep_properties

  @impl true
  def trim(raw) do
    %{
      "id" => raw["id"],
      "labels" => take_lang(raw["labels"]),
      "descriptions" => take_lang(raw["descriptions"]),
      "aliases" => take_lang(raw["aliases"]),
      "sitelinks" => Map.take(raw["sitelinks"] || %{}, ["enwiki"]),
      "claims" => claims(raw["claims"])
    }
  end

  # Whitelist the properties, then strip each statement to its `mainsnak`. The
  # `references` and `qualifiers` arrays are the bulk of an entity and nothing
  # in the pipeline reads them; keeping them cost 4.5 KB a row for nothing.
  defp claims(nil), do: %{}

  defp claims(claims) do
    claims
    |> Map.take(@keep_properties)
    |> Map.new(fn {property, statements} ->
      {property, Enum.map(statements, &Map.take(&1, ["mainsnak", "rank", "type"]))}
    end)
  end

  defp take_lang(nil), do: %{}
  defp take_lang(map), do: Map.take(map, ["en", "mul"])

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope, opts \\ []) do
    source = Sources.get_source_by_slug!(slug())
    rate = rate_limit(source, opts)

    seeds = seed_qids(scope, opts)

    if seeds == [] do
      raise """
      No QIDs to fetch. Wikidata is seeded from sense metadata and from the
      Wikipedia pass, so run those first:
        mix dd.absorb wikipedia --scope #{(scope && scope.slug) || "animals"}
      """
    end

    stats = walk(source, seeds, rate, opts)

    # Pass one writes every concept; each further pass closes the taxonomy edges
    # whose parent was introduced by a later record than the child. Two passes
    # is usually enough, but not always — a parent fetched in the last tier can
    # be a batch behind its child again — so this runs until nothing is left
    # unresolved rather than a fixed number of times. Without it M1 finds the
    # remainder instead.
    batch_opts =
      [
        batch_size: @materialize_batch,
        only_stale: true,
        run_id: opts[:run_id]
      ]
      |> materialize_selection(stats.visited_qids, opts)

    first = Batch.run(__MODULE__, source, batch_opts)

    second = close_concept_relations(source, first, opts[:run_id], stats.visited_qids, opts)

    {:ok,
     %{
       seed_qids: length(seeds),
       selection: if(explicit_qids(opts) == [], do: "scope", else: "explicit_qids"),
       entity_budget: stats.entity_budget,
       request_budget: stats.request_budget,
       related_depth: stats.related_depth,
       tiers: stats.tiers,
       truncated: stats.truncated,
       unresolved_references: stats.unresolved_references,
       requests: stats.requests,
       records: stats.records,
       fetched: stats.fetched,
       absent: stats.absent,
       bytes_raw: stats.bytes_raw,
       bytes_trimmed: stats.bytes_trimmed,
       trim_saving_pct: saving_pct(stats.bytes_raw, stats.bytes_trimmed),
       concepts: second.concepts,
       concept_relations: second.concept_relations,
       # Two numbers, not one. `parent_taxon_unresolved` is the walk's own
       # residual and must be 0; `unchased_edges` is the P279/P31 targets we
       # record but deliberately never fetch, and is expected to be large.
       parent_taxon_unresolved: second.concept_relations_skipped_parent_taxon,
       unchased_edges: second.concept_relations_skipped_unchased,
       materialize_passes: second.passes,
       taxa: count_taxa()
     }}
  end

  # Breadth-first over the parent properties. Each tier is whatever the last
  # tier named and we have not stored yet, so a shared ancestor (Animalia is
  # every leaf's great-grandparent) is fetched exactly once.
  defp walk(source, seeds, rate, opts) do
    explicit? = explicit_qids(opts) != []

    max_depth =
      positive_budget!(
        opts[:related_depth] || opts[:max_depth] || if(explicit?, do: 2, else: @max_depth),
        :related_depth,
        @max_depth
      )

    entity_budget =
      positive_budget!(
        opts[:entity_budget] ||
          if(explicit?, do: @default_explicit_entity_budget, else: @max_scope_entity_budget),
        :entity_budget,
        if(explicit?, do: @max_explicit_entity_budget, else: @max_scope_entity_budget)
      )

    request_budget =
      positive_budget!(
        opts[:request_budget] ||
          if(explicit?, do: @default_explicit_request_budget, else: @max_scope_request_budget),
        :request_budget,
        if(explicit?, do: @max_explicit_request_budget, else: @max_scope_request_budget)
      )

    stats = %{
      tiers: 0,
      requests: 0,
      records: 0,
      fetched: 0,
      absent: 0,
      bytes_raw: 0,
      bytes_trimmed: 0,
      requested_entities: 0,
      unresolved_references: 0,
      entity_budget: entity_budget,
      request_budget: request_budget,
      related_depth: max_depth,
      visited_qids: []
    }

    # `truncated` matters: a walk cut off at `max_depth` leaves taxon chains that
    # do not reach Animalia, which would show up as a soft L3 rather than as the
    # bug it is. Reported either way rather than inferred from `tiers`.
    stats = Map.put(stats, :truncated, false)

    Enum.reduce_while(1..max_depth, {seeds, MapSet.new(), stats}, fn depth, {queue, seen, acc} ->
      wanted = queue |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))

      # A re-run should cost the tiers it does not already have. `--refresh`
      # asks for the fetch anyway, which is how a pinned snapshot moves.
      wanted =
        if opts[:refresh] && depth == 1, do: wanted, else: wanted -- stored_qids(source, wanted)

      entity_capacity = max(entity_budget - acc.requested_entities, 0)
      request_capacity = max(request_budget - acc.requests, 0) * Client.batch_size()
      capacity = min(entity_capacity, request_capacity)
      bounded = Enum.take(wanted, capacity)
      omitted = length(wanted) - length(bounded)

      cond do
        wanted == [] ->
          {:halt, acc}

        bounded == [] ->
          {:halt,
           %{
             acc
             | truncated: true,
               unresolved_references: acc.unresolved_references + length(wanted)
           }}

        depth == max_depth ->
          {parents, acc} = fetch_tier(source, bounded, rate, acc, opts)

          unresolved = acc.unresolved_references + omitted + length(Enum.uniq(parents))

          {:halt,
           %{
             acc
             | tiers: depth,
               truncated: unresolved > 0,
               unresolved_references: unresolved
           }}

        true ->
          {parents, acc} = fetch_tier(source, bounded, rate, acc, opts)
          seen = MapSet.union(seen, MapSet.new(bounded))

          if omitted > 0 do
            {:halt,
             %{
               acc
               | tiers: depth,
                 truncated: true,
                 unresolved_references:
                   acc.unresolved_references + omitted + length(Enum.uniq(parents))
             }}
          else
            {:cont, {parents, seen, %{acc | tiers: depth}}}
          end
      end
    end)
    |> case do
      %{} = acc -> acc
      {_queue, _seen, acc} -> acc
    end
  end

  # Repeat the full re-materialize while it is still closing edges. Capped, and
  # the residual is reported either way: a walk that genuinely names a parent
  # nobody has fetched should be visible, not looped on.
  #
  # The loop watches the **`parent_taxon`** residual alone. The unchased
  # P279/P31 skips never fall, so counting them here meant the loop only ever
  # stopped on the "no better than last time" arm and could not tell a closed
  # walk from a stuck one.
  @max_materialize_passes 5

  defp close_concept_relations(source, first, run_id, visited_qids, opts) do
    Enum.reduce_while(2..@max_materialize_passes, Map.put(first, :passes, 1), fn pass, previous ->
      batch_opts =
        [
          batch_size: @materialize_batch,
          only_stale: false,
          run_id: run_id
        ]
        |> materialize_selection(visited_qids, opts)

      counts = Batch.run(__MODULE__, source, batch_opts)

      counts = Map.put(counts, :passes, pass)

      if counts.concept_relations_skipped_parent_taxon == 0 or
           counts.concept_relations_skipped_parent_taxon >=
             previous.concept_relations_skipped_parent_taxon do
        {:halt, counts}
      else
        {:cont, counts}
      end
    end)
  end

  defp fetch_tier(source, qids, rate, acc, opts) do
    qids
    |> Enum.chunk_every(Client.batch_size())
    |> Enum.reduce({[], acc}, fn chunk, {parents, acc} ->
      case Client.fetch(chunk, rate_limit_ms: rate) do
        {:ok, entities} ->
          rows = Enum.map(chunk, &row(&1, Map.get(entities, &1)))
          written = Sources.insert_records(source, rows, @record_chunk)

          acc = %{
            acc
            | requests: acc.requests + 1,
              records: acc.records + written,
              fetched: acc.fetched + map_size(entities),
              absent: acc.absent + (length(chunk) - map_size(entities)),
              bytes_raw: acc.bytes_raw + Enum.sum(Enum.map(Map.values(entities), &bytes/1)),
              bytes_trimmed:
                acc.bytes_trimmed + Enum.sum(Enum.map(Map.values(entities), &bytes(trim(&1)))),
              visited_qids: Enum.uniq(acc.visited_qids ++ chunk)
          }

          related = Enum.flat_map(Map.values(entities), &related_qids(&1, opts))

          {parents ++ related,
           %{acc | requested_entities: acc.requested_entities + length(chunk)}}

        {:error, reason} ->
          if opts[:strict] do
            raise "wikidata: #{inspect(reason)} on #{inspect(chunk)}"
          else
            {parents,
             %{
               acc
               | requests: acc.requests + 1,
                 requested_entities: acc.requested_entities + length(chunk)
             }}
          end
      end
    end)
  end

  defp row(qid, nil) do
    %{
      external_id: qid,
      url: entity_url(qid),
      raw: %{},
      content_hash: SourceRecord.content_hash(%{}),
      absent_until: DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
    }
  end

  defp row(qid, entity) do
    %{
      external_id: qid,
      url: entity_url(qid),
      raw: trim(entity),
      content_hash: SourceRecord.content_hash(entity)
    }
  end

  defp related_qids(entity, opts) do
    properties =
      if explicit_qids(opts) == [],
        do: @parent_properties,
        else: @parent_properties ++ @general_relation_properties

    Enum.flat_map(properties, &Client.entity_ids(entity, &1))
  end

  defp materialize_selection(batch_opts, visited_qids, opts) do
    if explicit_qids(opts) == [] do
      batch_opts
    else
      Keyword.put(batch_opts, :where, dynamic([r], r.external_id in ^visited_qids))
    end
  end

  # ── enrich ───────────────────────────────────────────────────────────────

  @impl true
  def enrich(qid, opts) when is_binary(qid) do
    source = Sources.get_source_by_slug!(slug())
    rate = rate_limit(source, opts)

    case Client.fetch_one(qid, rate_limit_ms: rate) do
      {:ok, entity} ->
        {:ok, record} = Sources.upsert_record(source, row(qid, entity))
        {:ok, record}

      {:error, :not_found} ->
        {:ok, record} = Sources.upsert_record(source, row(qid, nil))
        {:absent, record.absent_until}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── materialize ──────────────────────────────────────────────────────────

  @impl true
  def materialize(%SourceRecord{raw: raw}) when map_size(raw) == 0, do: {:ok, %{}}

  def materialize(%SourceRecord{} = record) do
    raw = record.raw
    qid = raw["id"]
    scientific_name = Client.string(raw, "P225")

    # The columns `concepts` carried are descriptive facts about a thing, not its
    # identity, and they move into `entities.metadata` under the same names.
    # `kind` becomes an entity kind: `:concept` is the no-opinion value another
    # source may sharpen, which is why it is not `:other`.
    concept = %{
      key: qid,
      qid: qid,
      label: clamp(label(raw, scientific_name)),
      description: get_in(raw, ["descriptions", "en", "value"]),
      kind: entity_kind(raw, scientific_name),
      taxon_concept: taxon_concept(raw, scientific_name),
      metadata:
        raw
        |> metadata()
        |> put_if("wikipedia_title", clamp(get_in(raw, ["sitelinks", "enwiki", "title"])))
        |> put_if("image_url", fit(commons_url(Client.string(raw, "P18"))))
        |> put_if("image_attribution", clamp(commons_attribution(Client.string(raw, "P18"))))
        |> put_if("wordnet_ili", clamp(Client.string(raw, "P5063")))
        |> put_if("taxon", taxon(raw, scientific_name))
    }

    {:ok, %{concepts: [concept], concept_relations: relations(record, qid, raw)}}
  end

  # English first, then the multilingual label a taxon carries instead, then the
  # scientific name itself. A concept with no name at all is not worth a card.
  defp label(raw, scientific_name) do
    get_in(raw, ["labels", "en", "value"]) ||
      get_in(raw, ["labels", "mul", "value"]) ||
      scientific_name
  end

  defp taxon(_raw, nil), do: nil

  defp taxon(raw, scientific_name) do
    %{
      "scientific_name" => scientific_name,
      "rank" => Client.entity_ids(raw, "P105") |> List.first(),
      "common_names" => Client.strings(raw, "P1843", "en")
    }
  end

  # An entity that carries P225 already *is* the taxon; only an everyday concept
  # needs the P13176 bridge (Q146 cat → Q20980826 Felis catus).
  defp taxon_concept(_raw, scientific_name) when is_binary(scientific_name), do: nil
  defp taxon_concept(raw, _nil), do: Client.entity_ids(raw, "P13176") |> List.first()

  defp metadata(raw) do
    %{}
    |> put_if("wikidata_instance_of", nonempty(Client.entity_ids(raw, "P31")))
    |> put_if("wikidata_subclass_of", nonempty(Client.entity_ids(raw, "P279")))
    |> put_if("wordnet_31", Client.string(raw, "P8814"))
    |> put_if("commons_category", Client.string(raw, "P373"))
    |> put_if("gbif", Client.string(raw, "P846"))
    |> put_if("ncbi", Client.string(raw, "P685"))
    |> put_if("aliases", alias_values(raw))
  end

  defp alias_values(raw) do
    case get_in(raw, ["aliases", "en"]) do
      list when is_list(list) and list != [] -> Enum.map(list, & &1["value"])
      _ -> nil
    end
  end

  @kind_classes %{
    person: ~w(Q5),
    organization: ~w(Q43229 Q4830453 Q163740 Q783794),
    work: ~w(Q386724 Q7725634 Q47461344 Q17537576 Q571),
    place: ~w(Q17334923 Q2221906 Q515 Q200250 Q486972 Q56061),
    event: ~w(Q1656682 Q1190554 Q495307 Q752783)
  }

  defp entity_kind(_raw, scientific_name) when is_binary(scientific_name), do: :taxon

  defp entity_kind(raw, _scientific_name) do
    classes = MapSet.new(Client.entity_ids(raw, "P31"))

    Enum.find_value(@kind_classes, :concept, fn {kind, recognized} ->
      if Enum.any?(recognized, &MapSet.member?(classes, &1)), do: kind
    end)
  end

  @relation_types %{"P171" => :parent_taxon, "P279" => :subclass_of, "P31" => :instance_of}

  defp relations(record, qid, raw) do
    for {property, type} <- @relation_types,
        target <- Client.entity_ids(raw, property),
        target != qid do
      %{
        source_id: record.source_id,
        from_concept: qid,
        to_concept: target,
        type: type,
        property: property
      }
    end
  end

  # ── seeds ────────────────────────────────────────────────────────────────

  @doc """
  Every QID the rest of the database already points at, in reason order.

  WordNet stores one QID per sense, usually as a string but sometimes as an
  array (`panther` carries `["Q35255", "Q109647288"]`); Wiktionary always stores
  an array; Wikipedia's pass leaves them on `concepts.qid` already. All are
  unioned.

  All four are scoped. The concept seed was not until S5c, and the second scope
  is what made that visible: `concept_qids/0` read the whole table, so an
  809-lexeme `emotions` scope seeded 72,108 QIDs and fetched 28,084 records in
  sixteen minutes — every concept the *animals* scope had ever introduced,
  walked again. With one scope the bug cannot be seen, because the whole table
  is that scope.
  """
  def seed_qids(scope, opts \\ []) do
    selected = explicit_qids(opts)

    qids =
      cond do
        selected != [] ->
          selected

        is_nil(scope) ->
          raise ArgumentError,
                "Wikidata absorb requires --scope or an explicit bounded QID selection"

        true ->
          wordnet_qids(scope) ++ wiktionary_qids(scope) ++ concept_qids(scope) ++ root_qids(scope)
      end

    qids =
      qids
      |> Enum.uniq()
      |> Enum.filter(&valid_qid?/1)

    case opts[:limit] do
      nil -> qids
      n -> Enum.take(qids, n)
    end
  end

  # A synset's `wikidata` is a bare string for the common case and an array when
  # the synset maps onto more than one item. Reading only the string shape
  # silently dropped 1,887 senses (265 of them in the Animals scope), so neither
  # the concept nor the `wordnet_wikidata` link was ever seeded for them.
  defp wordnet_qids(scope) do
    wordnet_string_qids(scope) ++ wordnet_array_qids(scope)
  end

  # A sense's metadata lives on its current revision now, so each of these joins
  # one row further. The `jsonb_typeof` split is unchanged and still load-bearing.
  defp sense_metadata(source_slug) do
    from s in Sense,
      join: so in assoc(s, :source),
      join: rev in SenseRevision,
      on: rev.sense_id == s.object_id and rev.is_current,
      where: so.slug == ^source_slug
  end

  defp wordnet_string_qids(scope) do
    sense_metadata("wordnet")
    |> where([_s, _so, rev], fragment("jsonb_typeof(?->'wikidata') = 'string'", rev.metadata))
    |> select([_s, _so, rev], fragment("?->>'wikidata'", rev.metadata))
    |> in_scope(scope)
    |> Repo.all()
  end

  defp wordnet_array_qids(scope) do
    sense_metadata("wordnet")
    |> where([_s, _so, rev], fragment("jsonb_typeof(?->'wikidata') = 'array'", rev.metadata))
    |> select([_s, _so, rev], fragment("jsonb_array_elements_text(?->'wikidata')", rev.metadata))
    |> in_scope(scope)
    |> Repo.all()
  end

  defp wiktionary_qids(scope) do
    sense_metadata("wiktionary")
    |> where([_s, _so, rev], fragment("jsonb_typeof(?->'wikidata') = 'array'", rev.metadata))
    |> select([_s, _so, rev], fragment("jsonb_array_elements_text(?->'wikidata')", rev.metadata))
    |> in_scope(scope)
    |> Repo.all()
  end

  # The concepts this scope's own words point at: asserted links, plus the
  # candidates a corroboration pass could still promote. Not the 0.40
  # disambiguation floor — chasing every thing a "may refer to" page mentioned
  # is what grew the table to 90,481 rows, 54,273 of which link to no scope
  # word at all.
  #
  defp concept_qids(scope) do
    Repo.all(
      from link in subquery(Encyclopedia.linked_lexemes_query()),
        join: x in DevilsDictionary.Registry.ExternalIdentifier,
        on:
          x.object_id == link.entity_id and x.namespace == "wikidata" and
            x.status == :verified,
        join: sl in ScopeMember,
        on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
        where: is_nil(link.confidence) or link.confidence >= @promotable,
        distinct: true,
        select: x.external_id
    )
  end

  defp root_qids(scope), do: [scope.rules["wikidata_root"]] |> Enum.reject(&is_nil/1)

  defp in_scope(query, scope) do
    from [s, _so, _rev] in query,
      join: sl in ScopeMember,
      on: sl.lexeme_id == s.lexeme_id and sl.scope_id == ^scope.id
  end

  defp valid_qid?(qid), do: is_binary(qid) and Regex.match?(~r/^Q\d+$/, qid)

  defp explicit_qids(opts) do
    values =
      case opts[:qids] do
        nil -> []
        qids when is_binary(qids) -> String.split(qids, ",", trim: true)
        qids when is_list(qids) -> qids
        qid -> [qid]
      end

    qids = values |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.uniq()

    invalid = Enum.reject(qids, &valid_qid?/1)

    cond do
      invalid != [] ->
        raise ArgumentError, "invalid Wikidata QIDs: #{Enum.join(invalid, ", ")}"

      length(qids) > @max_explicit_qids ->
        raise ArgumentError,
              "explicit Wikidata selection exceeds #{@max_explicit_qids} QIDs"

      true ->
        qids
    end
  end

  defp positive_budget!(value, _name, maximum)
       when is_integer(value) and value > 0 and value <= maximum,
       do: value

  defp positive_budget!(value, name, maximum) do
    raise ArgumentError,
          "#{name} must be a positive integer no greater than #{maximum}, got: #{inspect(value)}"
  end

  defp nonempty([]), do: nil
  defp nonempty(values), do: values

  # ── helpers ──────────────────────────────────────────────────────────────

  # Chunked: a tier can carry more QIDs than Postgres will take bind parameters
  # for (the cap is 65,535), and a seed list of the whole scope is already
  # five figures.
  defp stored_qids(%Source{id: id}, qids) do
    qids
    |> Enum.chunk_every(10_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from r in SourceRecord,
          where: r.source_id == ^id and r.external_id in ^chunk,
          select: r.external_id
      )
    end)
  end

  defp count_taxa do
    Repo.aggregate(from(e in Entity, where: e.entity_kind == :taxon), :count)
  end

  defp entity_url(qid), do: "https://www.wikidata.org/wiki/" <> qid

  # A browser will not render `commons.wikimedia.org/wiki/Special:FilePath/…` as
  # an image. It resolves — three hops to a real JPEG — but the redirect hops
  # declare `text/html`, and Chrome enforces the `nosniff` header on an image
  # subresource, so the load fails. Every one of those URLs was a broken picture
  # on the browse page, and A10 counted them all as images.
  #
  # So derive the thumbnail path Commons actually serves. It is not a guess: the
  # two directory segments are the first one and two hex characters of the MD5 of
  # the file name with underscores for spaces, which is Commons' documented
  # layout, and this needs no network call.
  #
  # Two details that are easy to get wrong:
  #
  #   * the width has to be one Wikimedia will serve. It no longer generates
  #     arbitrary sizes: 500px answers, 400px and 320px and 800px are all
  #     `400 Bad Request`.
  #   * an SVG is thumbnailed to PNG, so the thumb file gains a `.png`.
  # A thumbnail URL repeats the file name, so a long one overflows the 255-byte
  # column and `fit/1` would drop it. The original-file path names the file once
  # and is ~120 bytes shorter, so it is the fallback: a full-size image is worse
  # than a thumbnail and much better than no picture. 378 of the 40,947 images
  # take this path.
  @thumb_width 500

  defp commons_url(nil), do: nil

  defp commons_url(file) do
    name = String.replace(file, " ", "_")
    encoded = URI.encode(name)
    dir = commons_dir(name)

    thumb =
      if String.ends_with?(String.downcase(name), ".svg"),
        do: "#{@thumb_width}px-#{encoded}.png",
        else: "#{@thumb_width}px-#{encoded}"

    thumb_url = String.replace(dir, "/commons/", "/commons/thumb/") <> "#{encoded}/#{thumb}"

    if byte_size(thumb_url) <= 255, do: thumb_url, else: dir <> encoded
  end

  defp commons_dir(name) do
    hash = :crypto.hash(:md5, name) |> Base.encode16(case: :lower)

    "https://upload.wikimedia.org/wikipedia/commons/#{String.first(hash)}/#{String.slice(hash, 0, 2)}/"
  end

  @doc "The Commons thumbnail URL for a file name. Public so the test can pin it."
  def thumbnail_url(file), do: commons_url(file)

  defp commons_attribution(nil), do: nil
  defp commons_attribution(file), do: file <> " · Wikimedia Commons"

  # `concepts` keeps its URL and label columns at varchar(255) (#69 §4). Text
  # is truncated; a URL that would not fit is dropped, because half a URL 404s.
  defp clamp(nil), do: nil
  defp clamp(value), do: String.slice(value, 0, 255)

  defp fit(nil), do: nil
  defp fit(value) when byte_size(value) <= 255, do: value
  defp fit(_value), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp bytes(term), do: term |> Jason.encode!() |> byte_size()

  defp saving_pct(0, _), do: 0.0
  defp saving_pct(raw, trimmed), do: Float.round((1 - trimmed / raw) * 100, 1)

  defp rate_limit(source, opts) do
    opts[:rate_limit_ms] || source.config["rate_limit_ms"] || rate_limit_ms()
  end
end
