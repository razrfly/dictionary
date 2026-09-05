defmodule DevilsDictionary.Absorb.Sources.Wikipedia do
  @moduledoc """
  The encyclopedia layer: one title probe per scope lemma, in reason order.

  **`external_id` is the probed lemma, not the pageid** — a deliberate deviation
  from #69 §4's mapping table, for two reasons. A lemma with no article has no
  pageid to key an absent marker on, and the probe is one fact *per lemma*:
  `oyster drill` and `Urosalpinx cinerea` both legitimately land on one page and
  both deserve their own record. The pageid is still in `raw` and on
  `concepts.wikipedia_pageid`.

  `absorb/2` embeds `raw["_probe"]`, carrying the lemma and the actual lexeme
  keys the probe was made for, read from the database. That is the same trick
  `Wordnet.absorb/2` uses for `_edges`, and for the same reason: `materialize/1`
  must stay pure, and `raw` alone must rebuild every derived row (M2).

  It writes **no `concept_links`**. Linking is `Absorb.Linker`'s job alone, so
  `mix dd.link` stays re-runnable without a re-absorb.

  ## Two passes, because #69 §2 asks for two things

  The **lemma pass** (default) probes every scope lemma as a title. The
  **concept pass** (`--concepts`) fetches a summary for every `concepts` row
  that carries an enwiki sitelink and has no entry yet — the taxa and the
  disambiguation candidates the Wikidata walk introduced, which no lemma probe
  would ever ask about. Scorecard row A7 is the second pass: without it, 41,850
  concepts have an article we know about and never read.

  A concept probe is keyed `"concept:<QID>"` rather than by title, so it can
  never collide with the lemma record for the same word.
  """

  @behaviour DevilsDictionary.Absorb.Source

  import Ecto.Query

  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Absorb.Clients.Wikipedia, as: Client
  alias DevilsDictionary.Encyclopedia.Concept
  alias DevilsDictionary.Lexicon.{Lexeme, Scope, ScopeLexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @keep ~w(title pageid ns description extract thumbnail pageprops fullurl _probe _candidates)
  @absent_days 30
  # The API returns a disambiguation page's links **alphabetically**, so a low
  # cap does not sample the page, it truncates it: at 30, "Seal" gave thirty
  # people named Seal and not one pinniped. 100 covers essentially every real
  # page and is a guard against a pathological one, not a sampling rate.
  @max_candidates 100
  @materialize_batch 500
  @record_chunk 500

  @impl true
  def slug, do: "wikipedia"

  @impl true
  def rate_limit_ms, do: 200

  @impl true
  def trim(raw), do: Map.take(raw, @keep)

  @doc "The keys `trim/1` keeps. Read by `Sources.Catalog` so the list lives once."
  def kept_keys, do: @keep

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope, opts \\ [])

  def absorb(nil, _opts) do
    raise """
    Wikipedia is absorbed against a scope:
      mix dd.absorb wikipedia --scope animals
    """
  end

  def absorb(%Scope{} = scope, opts) do
    if opts[:concepts], do: concept_pass(opts), else: lemma_pass(scope, opts)
  end

  defp lemma_pass(scope, opts) do
    source = Sources.get_source_by_slug!(slug())
    rate = rate_limit(source, opts)

    {targets, in_scope} = targets(scope, source, opts)

    if in_scope == 0 do
      raise """
      Scope #{scope.slug} has no lemmas#{if opts[:reason], do: " with reason #{opts[:reason]}"}.
      Build it first: mix dd.scope.build #{scope.slug}
      """
    end

    stats =
      targets
      |> Enum.chunk_every(Client.batch_size())
      |> Enum.reduce(new_stats(length(targets)), fn chunk, acc ->
        probe_chunk(source, chunk, rate, acc, opts)
      end)

    stats = candidates_pass(source, stats, rate, opts)

    materialized =
      Batch.run(__MODULE__, source, batch_size: @materialize_batch, only_stale: true)

    {:ok,
     %{
       lemmas: stats.lemmas,
       requests: stats.requests,
       records: stats.records,
       hits: stats.hits,
       misses: stats.misses,
       disambiguations: stats.disambiguations,
       candidates: stats.candidates,
       without_qid: stats.without_qid,
       concepts: materialized.concepts,
       entries: materialized.entries,
       lexemes: materialized.lexemes
     }}
  end

  # Every concept with an enwiki sitelink and no entry yet (A7). These are the
  # taxa and the disambiguation candidates the Wikidata walk introduced; a lemma
  # probe never asks about them because no scope lemma is spelled *Felidae*.
  defp concept_pass(opts) do
    source = Sources.get_source_by_slug!(slug())
    rate = rate_limit(source, opts)

    targets = concept_targets(source, opts)

    stats =
      targets
      |> Enum.chunk_every(Client.batch_size())
      |> Enum.reduce(new_stats(length(targets)), fn chunk, acc ->
        concept_chunk(source, chunk, rate, acc, opts)
      end)

    materialized =
      Batch.run(__MODULE__, source, batch_size: @materialize_batch, only_stale: true)

    {:ok,
     %{
       concepts_probed: stats.lemmas,
       requests: stats.requests,
       records: stats.records,
       hits: stats.hits,
       misses: stats.misses,
       concepts: materialized.concepts,
       entries: materialized.entries
     }}
  end

  defp concept_targets(source, opts) do
    query =
      from c in Concept,
        where: not is_nil(c.wikipedia_title),
        order_by: c.id,
        select: %{qid: c.qid, title: c.wikipedia_title}

    query =
      if opts[:refresh] do
        query
      else
        # Skip anything we have already asked about. An entry is the happy
        # answer and an unexpired absent marker the explicit negative, but
        # neither covers the concept we *did* fetch that yielded no entry — a
        # disambiguation page, or an article with an empty extract. There are
        # ~3,800 of those, and without the third clause every `--concepts` run
        # re-fetched all of them. The clause tests `absent_until IS NULL` rather
        # than the row's mere existence, so an expired marker is still retried
        # exactly as #69 §5's terminal states ask. `--refresh` is the way back.
        from c in query,
          where: not fragment("EXISTS (SELECT 1 FROM entries e WHERE e.concept_id = ?)", c.id),
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM source_records r WHERE r.source_id = ? AND r.external_id = ? AND r.absent_until > now())",
              ^source.id,
              fragment("'concept:' || ?", c.qid)
            ),
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM source_records r WHERE r.source_id = ? AND r.external_id = ? AND r.absent_until IS NULL)",
              ^source.id,
              fragment("'concept:' || ?", c.qid)
            )
      end

    query =
      case opts[:limit] do
        nil -> query
        n -> limit(query, ^n)
      end

    Repo.all(query)
  end

  defp concept_chunk(source, chunk, rate, acc, opts) do
    titles = Enum.map(chunk, & &1.title)

    case Client.summaries(titles, rate_limit_ms: rate) do
      {:ok, pages} ->
        {rows, acc} =
          Enum.reduce(chunk, {[], %{acc | requests: acc.requests + 1}}, fn target, {rows, acc} ->
            case Map.fetch!(pages, target.title) do
              :missing ->
                {[concept_absent_row(target) | rows], %{acc | misses: acc.misses + 1}}

              page ->
                {[concept_row(target, page) | rows], %{acc | hits: acc.hits + 1}}
            end
          end)

        written = Sources.insert_records(source, rows, @record_chunk)
        %{acc | records: acc.records + written}

      {:error, reason} ->
        if opts[:strict] do
          raise "wikipedia: #{inspect(reason)} on #{inspect(titles)}"
        else
          %{acc | requests: acc.requests + 1, errors: acc.errors + 1}
        end
    end
  end

  defp concept_row(target, page) do
    raw =
      page
      |> Map.put("_probe", %{"qid" => target.qid, "title" => target.title})
      |> trim()

    %{
      external_id: "concept:" <> target.qid,
      url: page["fullurl"] || article_url(page["title"]),
      raw: raw,
      content_hash: SourceRecord.content_hash(page)
    }
  end

  defp concept_absent_row(target) do
    %{
      external_id: "concept:" <> target.qid,
      url: article_url(target.title),
      raw: %{},
      content_hash: SourceRecord.content_hash(%{}),
      absent_until: DateTime.add(DateTime.utc_now(), @absent_days * 24 * 3600, :second)
    }
  end

  # One request per 20 titles. A miss becomes an absent marker rather than
  # nothing, so the next run knows not to ask again (#69 §5's terminal states).
  defp probe_chunk(source, chunk, rate, acc, opts) do
    lemmas = Enum.map(chunk, & &1.lemma)

    case Client.summaries(lemmas, rate_limit_ms: rate) do
      {:ok, pages} ->
        {rows, acc} =
          Enum.reduce(chunk, {[], %{acc | requests: acc.requests + 1}}, fn target, {rows, acc} ->
            case Map.fetch!(pages, target.lemma) do
              :missing ->
                {[absent_row(target) | rows], %{acc | misses: acc.misses + 1}}

              page ->
                acc =
                  acc
                  |> Map.update!(:hits, &(&1 + 1))
                  |> then(fn a ->
                    if disambiguation?(page),
                      do: %{a | disambiguations: a.disambiguations + 1},
                      else: a
                  end)
                  |> then(fn a ->
                    if qid(page), do: a, else: %{a | without_qid: a.without_qid + 1}
                  end)

                {[page_row(target, page) | rows], acc}
            end
          end)

        written = Sources.insert_records(source, rows, @record_chunk)
        %{acc | records: acc.records + written}

      {:error, reason} ->
        if opts[:strict] do
          raise "wikipedia: #{inspect(reason)} on #{inspect(lemmas)}"
        else
          %{acc | requests: acc.requests + 1, errors: acc.errors + 1}
        end
    end
  end

  # Disambiguation pages get their candidate articles read and stored on the
  # record, so the "may refer to" panel and the `:disambiguation` rung both come
  # out of `raw` without another fetch (L4).
  #
  # Re-read on every full absorb rather than skipped when `_candidates` is
  # already present: the probe pass replaces `raw` with the fresh response, and
  # a page whose "may refer to" list changed should say so. It costs two calls
  # per disambiguation page, of which an Animals scope has a few hundred.
  defp candidates_pass(source, stats, rate, opts) do
    max = opts[:max_candidates] || @max_candidates

    query =
      from r in SourceRecord,
        where: r.source_id == ^source.id,
        where: fragment("jsonb_exists(?->'pageprops', 'disambiguation')", r.raw),
        select: %{r | raw: r.raw}

    # Candidates are read once per page. Re-reading a page we have already read
    # costs one `links` request plus a `pageprops` chunk each and answers the
    # same list — 1,775 pages of it — and rewriting the record for it is what
    # restamped `changed_at` on 1,352 rows in S2.
    query =
      if opts[:refresh] do
        query
      else
        from r in query, where: not fragment("jsonb_exists(?, '_candidates')", r.raw)
      end

    disambiguations = Repo.all(query)

    Enum.reduce(disambiguations, stats, fn record, acc ->
      title = record.raw["title"]

      with {:ok, all_titles} <- Client.links(title, rate_limit_ms: rate),
           titles = Enum.take(all_titles, max),
           {:ok, props} <- pageprops_all(titles, rate) do
        candidates =
          for t <- titles,
              page = Map.get(props, t),
              is_map(page),
              q = qid(page),
              not is_nil(q) do
            %{"title" => page["title"], "qid" => q, "description" => page["description"]}
          end

        raw = Map.put(record.raw, "_candidates", candidates)

        Sources.insert_records(
          source,
          [
            %{
              external_id: record.external_id,
              url: record.url,
              raw: trim(raw),
              # The record's own hash, carried through untouched. `_candidates`
              # is our annotation like `_probe`, not content Wikipedia changed,
              # and rehashing here would stamp `changed_at` on every
              # disambiguation page — the S1b mistake in a new place.
              content_hash: record.content_hash
            }
          ],
          1
        )

        %{
          acc
          | requests: acc.requests + 1 + ceil(length(titles) / 50),
            candidates: acc.candidates + length(candidates)
        }
      else
        _ -> %{acc | requests: acc.requests + 2, errors: acc.errors + 1}
      end
    end)
  end

  # `pageprops` carries no extract, so its title limit is the API's 50 rather
  # than the 20 `summaries/2` is held to.
  defp pageprops_all(titles, rate) do
    titles
    |> Enum.chunk_every(50)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Client.pageprops(chunk, rate_limit_ms: rate) do
        {:ok, props} -> {:cont, {:ok, Map.merge(acc, props)}}
        error -> {:halt, error}
      end
    end)
  end

  defp page_row(target, page) do
    raw =
      page
      |> Map.put("_probe", %{"lemma" => target.lemma, "lexemes" => target.lexemes})
      |> trim()

    %{
      external_id: target.lemma,
      url: page["fullurl"] || article_url(page["title"]),
      raw: raw,
      # The hash is the payload as fetched: `_probe` is our annotation, not the
      # source's content, so including it would make a scope rebuild look like a
      # change at Wikipedia (the S1b contract).
      content_hash: SourceRecord.content_hash(page)
    }
  end

  defp absent_row(target) do
    %{
      external_id: target.lemma,
      url: article_url(target.lemma),
      raw: %{},
      content_hash: SourceRecord.content_hash(%{}),
      absent_until: DateTime.add(DateTime.utc_now(), @absent_days * 24 * 3600, :second)
    }
  end

  # ── enrich ───────────────────────────────────────────────────────────────

  @impl true
  def enrich(lemma, opts) when is_binary(lemma) do
    source = Sources.get_source_by_slug!(slug())
    rate = rate_limit(source, opts)

    with {:ok, pages} <- Client.summaries([lemma], rate_limit_ms: rate) do
      target = %{lemma: lemma, lexemes: lexeme_keys([lemma])[lemma] || []}

      case Map.fetch!(pages, lemma) do
        :missing ->
          {:ok, record} = Sources.upsert_record(source, absent_row(target))
          {:absent, record.absent_until}

        page ->
          {:ok, record} = Sources.upsert_record(source, page_row(target, page))
          {:ok, record}
      end
    end
  end

  # ── materialize ──────────────────────────────────────────────────────────

  @impl true
  def materialize(%SourceRecord{raw: raw}) when map_size(raw) == 0, do: {:ok, %{}}

  def materialize(%SourceRecord{} = record) do
    raw = record.raw
    probe = raw["_probe"] || %{}
    title = raw["title"]
    # The page's own `wikibase_item` is the truth; the probe's QID is the
    # fallback for the rare article that carries none, so a concept pass always
    # lands its entry somewhere (A7).
    qid = qid(raw) || probe["qid"]
    disambiguation? = disambiguation?(raw)

    lexemes =
      for [lang, lemma, pos] <- probe["lexemes"] || [] do
        %{
          key: {lang, lemma, pos},
          metadata:
            %{"wikipedia_title" => title}
            |> maybe_put("wikipedia_disambiguation", disambiguation? || nil)
        }
      end

    {concepts, entries} =
      if qid do
        {[concept(raw, qid, disambiguation?)],
         [entry(record, raw, qid, disambiguation?)] |> Enum.reject(&is_nil/1)}
      else
        {[], []}
      end

    {:ok,
     %{
       lexemes: lexemes,
       concepts: concepts ++ candidate_concepts(raw),
       entries: entries
     }}
  end

  defp concept(raw, qid, disambiguation?) do
    %{
      key: qid,
      qid: qid,
      label: clamp(raw["title"]),
      description: raw["description"],
      kind: :thing,
      wikipedia_title: clamp(raw["title"]),
      wikipedia_pageid: raw["pageid"],
      image_url: thumbnail(raw),
      image_attribution: fit(attribution(get_in(raw, ["thumbnail", "source"]))),
      metadata: maybe_put(%{}, "disambiguation", disambiguation? || nil)
    }
  end

  # A candidate is a real concept with a title and a description; it only lacks
  # whatever Wikidata will add later. The materializer's COALESCE merge means
  # writing it here can never blank a fuller row.
  defp candidate_concepts(raw) do
    for candidate <- raw["_candidates"] || [] do
      %{
        key: candidate["qid"],
        qid: candidate["qid"],
        label: clamp(candidate["title"]),
        description: candidate["description"],
        kind: :thing,
        wikipedia_title: clamp(candidate["title"]),
        metadata: %{"from_disambiguation" => raw["title"]}
      }
    end
  end

  # A disambiguation page's "X may refer to" is not an encyclopedia article, so
  # it gets a concept (the panel needs its candidates) but no entry: putting it
  # on the word page as a source card would be a definition we never made.
  defp entry(_record, _raw, _qid, true), do: nil

  defp entry(record, raw, qid, false) do
    %{
      source_id: record.source_id,
      source_record_id: record.id,
      concept: qid,
      headword: raw["title"],
      body: raw["extract"],
      body_format: :text,
      url: raw["fullurl"] || article_url(raw["title"]),
      thumbnail_url: thumbnail(raw),
      position: 0,
      metadata: %{"pageid" => raw["pageid"], "description" => raw["description"]}
    }
  end

  # ── targets ──────────────────────────────────────────────────────────────

  # Reason order (#70's S0 audit): the WordNet-closure words first so the
  # flagship numbers arrive early, then the category-only tail.
  defp targets(%Scope{} = scope, source, opts) do
    lemmas =
      case opts[:reason] do
        nil ->
          first = scope_lemmas(scope, "wordnet_closure")
          first ++ (scope_lemmas(scope, nil) -- first)

        reason ->
          scope_lemmas(scope, reason)
      end

    in_scope = length(lemmas)

    # A probe is one fact per lemma and it does not go stale on its own, so a
    # lemma we have already asked about is not asked about again. Without this
    # the pass re-fetched the whole scope every run — 23,784 lemmas and 90
    # minutes to learn nothing — which is also what made the disambiguation
    # re-read restamp `changed_at`. `--refresh` is the way back in.
    lemmas =
      if opts[:refresh] do
        lemmas
      else
        already = probed(source, lemmas)
        Enum.reject(lemmas, &MapSet.member?(already, &1))
      end

    lemmas =
      case opts[:limit] do
        nil -> lemmas
        n -> Enum.take(lemmas, n)
      end

    keys = lexeme_keys(lemmas)

    {Enum.map(lemmas, &%{lemma: &1, lexemes: Map.get(keys, &1, [])}), in_scope}
  end

  # Lemmas with a record already: a hit, or an absent marker that has not
  # expired. An expired marker is retried, exactly as #69 §5's terminal states
  # ask.
  defp probed(source, lemmas) do
    now = DateTime.utc_now()

    lemmas
    |> Enum.chunk_every(10_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from r in SourceRecord,
          where: r.source_id == ^source.id,
          where: r.external_id in ^chunk,
          where: is_nil(r.absent_until) or r.absent_until > ^now,
          select: r.external_id
      )
    end)
    |> MapSet.new()
  end

  defp scope_lemmas(%Scope{id: scope_id}, reason) do
    query =
      from sl in ScopeLexeme,
        join: l in Lexeme,
        on: l.id == sl.lexeme_id,
        where: sl.scope_id == ^scope_id,
        select: l.lemma,
        distinct: true,
        order_by: l.lemma

    query =
      case reason do
        nil -> query
        reason -> from [sl, _l] in query, where: fragment("? = ANY(?)", ^reason, sl.reasons)
      end

    Repo.all(query)
  end

  # The lexeme keys a probe stands for. Read here so `materialize/1` never has
  # to guess a part of speech and never creates a lexeme the index does not have.
  defp lexeme_keys(lemmas) do
    # Chunked for the same reason `Wikidata.stored_qids/2` is: an Animals scope
    # is ~20,000 lemmas and Postgres takes 65,535 bind parameters.
    lemmas
    |> Enum.chunk_every(10_000)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from l in Lexeme,
          where: l.lemma in ^chunk,
          select: {l.lemma, l.lang, l.pos}
      )
    end)
    |> Enum.group_by(fn {lemma, _, _} -> lemma end, fn {lemma, lang, pos} ->
      [lang, lemma, pos]
    end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp qid(page), do: get_in(page, ["pageprops", "wikibase_item"])

  defp disambiguation?(page) do
    page |> get_in(["pageprops"]) |> Kernel.||(%{}) |> Map.has_key?("disambiguation")
  end

  # The API decorates every thumbnail with `utm_source`/`utm_campaign`/
  # `utm_content`. They are analytics tags, not part of the image, and they add
  # ~85 characters to a column that is 255 wide — so they go before storage.
  defp thumbnail(raw) do
    raw |> get_in(["thumbnail", "source"]) |> strip_query() |> fit()
  end

  defp strip_query(nil), do: nil
  defp strip_query(url), do: url |> String.split("?") |> hd()

  # A URL that will not fit the column is unusable, so it is dropped rather than
  # truncated into something that 404s. Counted by A10 as a concept without an
  # image, which is the honest reading.
  defp fit(nil), do: nil
  defp fit(value) when byte_size(value) <= 255, do: value
  defp fit(_value), do: nil

  defp article_url(title) do
    "https://en.wikipedia.org/wiki/" <> String.replace(title, " ", "_")
  end

  defp attribution(nil), do: nil

  defp attribution(url) do
    case Regex.run(~r"/commons/(?:thumb/)?[0-9a-f]/[0-9a-f]{2}/([^/?]+)", url) do
      [_, file] -> URI.decode(file) <> " · Wikimedia Commons"
      _ -> "Wikimedia Commons"
    end
  end

  defp clamp(nil), do: nil
  defp clamp(value), do: String.slice(value, 0, 255)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp rate_limit(source, opts) do
    opts[:rate_limit_ms] || source.config["rate_limit_ms"] || rate_limit_ms()
  end

  defp new_stats(lemmas) do
    %{
      lemmas: lemmas,
      requests: 0,
      records: 0,
      hits: 0,
      misses: 0,
      disambiguations: 0,
      candidates: 0,
      without_qid: 0,
      errors: 0
    }
  end
end
