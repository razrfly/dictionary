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
  alias DevilsDictionary.Encyclopedia.Concept
  alias DevilsDictionary.Lexicon.{ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Source, SourceRecord}

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

  # Taxonomic chains run long: species → genus → … → Animalia passes through
  # unranked clades, so 30 is a guard against a cycle, not a real ceiling.
  @max_depth 30
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
    first = Batch.run(__MODULE__, source, batch_size: @materialize_batch, only_stale: true)
    second = close_concept_relations(source, first)

    {:ok,
     %{
       seed_qids: length(seeds),
       tiers: stats.tiers,
       truncated: stats.truncated,
       requests: stats.requests,
       records: stats.records,
       fetched: stats.fetched,
       absent: stats.absent,
       bytes_raw: stats.bytes_raw,
       bytes_trimmed: stats.bytes_trimmed,
       trim_saving_pct: saving_pct(stats.bytes_raw, stats.bytes_trimmed),
       concepts: second.concepts,
       concept_relations: second.concept_relations,
       concept_relations_unresolved: second.concept_relations_skipped,
       materialize_passes: second.passes,
       taxa: count_taxa()
     }}
  end

  # Breadth-first over the parent properties. Each tier is whatever the last
  # tier named and we have not stored yet, so a shared ancestor (Animalia is
  # every leaf's great-grandparent) is fetched exactly once.
  defp walk(source, seeds, rate, opts) do
    max_depth = opts[:max_depth] || @max_depth

    stats = %{
      tiers: 0,
      requests: 0,
      records: 0,
      fetched: 0,
      absent: 0,
      bytes_raw: 0,
      bytes_trimmed: 0
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

      cond do
        wanted == [] ->
          {:halt, acc}

        depth == max_depth ->
          {_parents, acc} = fetch_tier(source, wanted, rate, acc, opts)
          {:halt, %{acc | tiers: depth, truncated: true}}

        true ->
          {parents, acc} = fetch_tier(source, wanted, rate, acc, opts)
          seen = MapSet.union(seen, MapSet.new(wanted))
          {:cont, {parents, seen, %{acc | tiers: depth}}}
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
  @max_materialize_passes 5

  defp close_concept_relations(source, first) do
    Enum.reduce_while(2..@max_materialize_passes, Map.put(first, :passes, 1), fn pass, previous ->
      counts = Batch.run(__MODULE__, source, batch_size: @materialize_batch, only_stale: false)
      counts = Map.put(counts, :passes, pass)

      if counts.concept_relations_skipped == 0 or
           counts.concept_relations_skipped >= previous.concept_relations_skipped do
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
                acc.bytes_trimmed + Enum.sum(Enum.map(Map.values(entities), &bytes(trim(&1))))
          }

          {parents ++ Enum.flat_map(Map.values(entities), &parent_qids/1), acc}

        {:error, reason} ->
          if opts[:strict] do
            raise "wikidata: #{inspect(reason)} on #{inspect(chunk)}"
          else
            {parents, %{acc | requests: acc.requests + 1}}
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

  defp parent_qids(entity) do
    Enum.flat_map(@parent_properties, &Client.entity_ids(entity, &1))
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

    concept = %{
      key: qid,
      qid: qid,
      label: clamp(label(raw, scientific_name)),
      description: get_in(raw, ["descriptions", "en", "value"]),
      kind: if(scientific_name, do: :taxon, else: :thing),
      wikipedia_title: clamp(get_in(raw, ["sitelinks", "enwiki", "title"])),
      image_url: fit(commons_url(Client.string(raw, "P18"))),
      image_attribution: clamp(commons_attribution(Client.string(raw, "P18"))),
      wordnet_ili: clamp(Client.string(raw, "P5063")),
      taxon: taxon(raw, scientific_name),
      taxon_concept: taxon_concept(raw, scientific_name),
      metadata: metadata(raw)
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

  defp taxon(_raw, nil), do: %{}

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

  WordNet stores one QID per sense as a string; Wiktionary stores an array;
  Wikipedia's pass leaves them on `concepts.qid` already. All three are unioned.
  """
  def seed_qids(scope, opts \\ []) do
    qids =
      wordnet_qids(scope) ++ wiktionary_qids(scope) ++ concept_qids() ++ root_qids(scope)

    qids =
      qids
      |> Enum.uniq()
      |> Enum.filter(&valid_qid?/1)

    case opts[:limit] do
      nil -> qids
      n -> Enum.take(qids, n)
    end
  end

  defp wordnet_qids(scope) do
    from(s in Sense,
      join: so in assoc(s, :source),
      where: so.slug == "wordnet",
      where: fragment("jsonb_typeof(?->'wikidata') = 'string'", s.metadata),
      select: fragment("?->>'wikidata'", s.metadata)
    )
    |> in_scope(scope)
    |> Repo.all()
  end

  defp wiktionary_qids(scope) do
    from(s in Sense,
      join: so in assoc(s, :source),
      where: so.slug == "wiktionary",
      where: fragment("jsonb_typeof(?->'wikidata') = 'array'", s.metadata),
      select: fragment("jsonb_array_elements_text(?->'wikidata')", s.metadata)
    )
    |> in_scope(scope)
    |> Repo.all()
  end

  defp concept_qids do
    Repo.all(from c in Concept, select: c.qid)
  end

  defp root_qids(nil), do: []
  defp root_qids(scope), do: [scope.rules["wikidata_root"]] |> Enum.reject(&is_nil/1)

  defp in_scope(query, nil), do: query

  defp in_scope(query, scope) do
    from [s, _so] in query,
      join: sl in ScopeLexeme,
      on: sl.lexeme_id == s.lexeme_id and sl.scope_id == ^scope.id
  end

  defp valid_qid?(qid), do: is_binary(qid) and Regex.match?(~r/^Q\d+$/, qid)

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
    Repo.aggregate(from(c in Concept, where: c.kind == :taxon), :count)
  end

  defp entity_url(qid), do: "https://www.wikidata.org/wiki/" <> qid

  defp commons_url(nil), do: nil

  defp commons_url(file) do
    "https://commons.wikimedia.org/wiki/Special:FilePath/" <>
      URI.encode(String.replace(file, " ", "_")) <> "?width=400"
  end

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
