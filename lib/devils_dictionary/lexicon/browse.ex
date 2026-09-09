defmodule DevilsDictionary.Lexicon.Browse do
  @moduledoc """
  The read side of the scope browse page (#69 §6 W3, scorecard row **U5**) and
  the trigram search behind it.

  Two rules shape everything here:

    * **coverage comes from `lexemes.source_ids`**, the array the materializer
      maintains, and never from a join onto `senses` or `entries`.
      `Health.coverage/2` tests exactly `? = ANY(source_ids)`, so reading the
      same array is what makes U5's "counts match `mix dd.health`" true by
      construction rather than by coincidence. The two disagree, and the array is
      right: Wikipedia's prose hangs off an `about` assertion and never off a
      lexeme, so a join says 0 where the truth is 18,028; Wikidata writes neither
      senses nor content at all. What a badge means is *this source attests this
      word*, which is what the scorecard means too.

    * **"disputed" has one definition.** `disputed_lexeme_ids/2` is the same
      predicate `Health.conflicts/3` reports on — two distinct entities at or
      above the threshold for one lexeme — so the filter and the number cannot
      drift apart.

  Ported to the encyclopedia model: `lexemes.id` becomes `lexemes.object_id`,
  `lang` and `pos` become `language_tag` and `part_of_speech`, `scope_lexemes`
  becomes `scope_lexeme_members`, and `concept_links` becomes the assertions
  `Encyclopedia.linked_lexemes_query/1` reads. Both rules above are unchanged.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, Lexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @per_page 50

  @doc """
  Trigram search over the index.

  Served by `lexemes_lemma_trgm_index` (gin, `gin_trgm_ops`) from the baseline
  migration — no new index and no migration. A prefix match ranks above a fuzzy
  one, and among equals the shorter lemma wins, so `oyst` reaches *oyster*
  before *oyster bed*.

  The fuzzy half is the `%` operator, not `similarity(…) > 0.3`. They mean the
  same thing — `%` compares against `pg_trgm.similarity_threshold`, which is 0.3
  — but only the operator uses the gin index. Measured on the 1.5M-row index,
  `oysster`: **43 ms** with `%`, **420 ms** with the function. X2 wants p95 under
  150 ms.

  `:scope` restricts the search to a scope, which is the browse page's "search
  within animals". #71's U2 home search (row X2) is the same function without it.
  """
  def search(query, opts \\ []) do
    query = String.trim(query || "")

    if query == "" do
      []
    else
      lang = Keyword.get(opts, :lang, "en")
      limit = Keyword.get(opts, :limit, 25)
      down = String.downcase(query)

      Lexeme
      |> where([l], l.language_tag == ^lang)
      |> where(
        [l],
        ilike(l.lemma, ^(escape_like(query) <> "%")) or
          fragment("? % ?", l.lemma, ^query)
      )
      |> maybe_in_scope(opts[:scope])
      |> order_by([l],
        asc: fragment("CASE WHEN lower(?) LIKE ? THEN 0 ELSE 1 END", l.lemma, ^(down <> "%")),
        desc: fragment("similarity(?, ?)", l.lemma, ^query),
        asc: fragment("length(?)", l.lemma),
        asc: l.lemma,
        asc: l.part_of_speech
      )
      |> limit(^limit)
      |> select([l], %{
        lexeme_id: l.object_id,
        lemma: l.lemma,
        pos: l.part_of_speech,
        slug: l.slug,
        enriched_at: l.enriched_at
      })
      |> Repo.all()
    end
  end

  @doc """
  A random draw over the index: **X1**'s sample of 200 and the home page's
  *Surprise me* (#71 U2), one sampler with two shapes.

  Unfiltered it draws random ids across `min(id)..max(id)` in rounds, never
  `ORDER BY random()`, which is a sequential scan of all 1.5 million rows. The
  id space has gaps, so a round of `sample * 3` draws lands about a third of
  them and rounds repeat until the sample is full — each round one indexed
  lookup. The draw is biased toward the ids that follow a gap; for a sample
  meant to be *representative of nothing in particular* that is harmless, and
  it is the reason this is not the sampler to use for a statistic.

  Filtered draws use a count and random offset. Scope filters are explicit
  operational options. The public *Surprise me* draw requires enrichment but
  no scope membership, so test populations do not constrain discovery.

  Returns `[%{id, slug, lemma}]`.
  """
  def random_lexemes(opts \\ []) do
    sample = Keyword.get(opts, :sample, 1)

    if opts[:scope] || opts[:enriched] do
      draw_by_offset(sample, opts)
    else
      draw_over_ids(sample)
    end
  end

  @doc """
  One enriched word across the index — the home page's *Surprise me*.
  Scope membership is irrelevant to public discovery.

  Returns a `%{id, slug, lemma}` or `nil` on an empty database.
  """
  def random_word do
    case random_lexemes(sample: 1, enriched: true) do
      [word | _] -> word
      [] -> nil
    end
  end

  defp draw_by_offset(sample, opts) do
    base = random_base(opts)

    case Repo.aggregate(base, :count) do
      0 ->
        []

      count ->
        1..sample
        |> Enum.map(fn _ -> :rand.uniform(count) - 1 end)
        |> Enum.uniq()
        |> Enum.flat_map(fn offset ->
          base
          |> order_by([l], asc: l.object_id)
          |> offset(^offset)
          |> limit(1)
          |> select([l], %{id: l.object_id, slug: l.slug, lemma: l.lemma})
          |> Repo.all()
        end)
    end
  end

  defp random_base(opts) do
    Lexeme
    |> from(as: :lexeme)
    |> where([l], l.language_tag == ^Keyword.get(opts, :lang, "en"))
    |> then(fn q ->
      if opts[:enriched], do: where(q, [l], not is_nil(l.enriched_at)), else: q
    end)
    |> random_scope(opts[:scope])
  end

  defp random_scope(query, nil), do: query

  defp random_scope(query, :any) do
    where(
      query,
      exists(
        from sl in ScopeMember, where: sl.lexeme_id == parent_as(:lexeme).object_id, select: 1
      )
    )
  end

  defp random_scope(query, slug) do
    case Lexicon.get_scope_by_slug(slug) do
      nil ->
        query

      scope ->
        where(
          query,
          exists(
            from sl in ScopeMember,
              where: sl.lexeme_id == parent_as(:lexeme).object_id and sl.scope_id == ^scope.id,
              select: 1
          )
        )
    end
  end

  defp draw_over_ids(sample) do
    case Repo.one(from l in Lexeme, select: {min(l.object_id), max(l.object_id)}) do
      {nil, nil} -> []
      {low, high} -> draw(low..high, sample, [], 8)
    end
  end

  defp draw(_range, sample, taken, 0), do: Enum.take(taken, sample)

  defp draw(range, sample, taken, rounds) do
    have = MapSet.new(taken, & &1.id)
    ids = for _ <- 1..(sample * 3), do: Enum.random(range)
    ids = ids |> Enum.uniq() |> Enum.reject(&(&1 in have))

    found =
      Repo.all(
        from l in Lexeme,
          where: l.object_id in ^ids,
          select: %{id: l.object_id, slug: l.slug, lemma: l.lemma}
      )

    case taken ++ found do
      all when length(all) >= sample -> Enum.take(all, sample)
      all -> draw(range, sample, all, rounds - 1)
    end
  end

  @doc """
  One page of a scope's lexemes, with the coverage each row's badges need.

  Options: `:q`, `:has` and `:missing` (source slugs), `:state`
  (`:bare | :enriched | :disputed`), `:taxon` (a QID, which filters to the words
  linked to that taxon's subtree), `:sort` (`:lemma | :coverage`), `:page`,
  `:per_page`.

  Returns `%{rows: [...], total: n, page: n, per_page: n, pages: n}`. The primary
  concept of each row is fetched in a second query over the page's ids rather
  than as a lateral join: fifty ids through `concept_links_lexeme_id_status_index`
  is cheaper to read and cheaper to run than a window function over 25,000 rows.
  """
  def browse(scope_slug, opts \\ []) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)
    per_page = Keyword.get(opts, :per_page, @per_page)
    page = max(Keyword.get(opts, :page, 1), 1)

    base = scoped(scope, opts)
    total = Repo.aggregate(exclude(base, :order_by), :count)

    rows =
      base
      |> sorted(Keyword.get(opts, :sort, :lemma))
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> select([l, sl], %{
        lexeme_id: l.object_id,
        lemma: l.lemma,
        pos: l.part_of_speech,
        slug: l.slug,
        source_ids: l.source_ids,
        enriched_at: l.enriched_at,
        reasons: sl.reasons
      })
      |> Repo.all()
      |> with_concepts()

    %{
      rows: rows,
      total: total,
      page: page,
      per_page: per_page,
      pages: max(ceil(total / per_page), 1)
    }
  end

  defp scoped(scope, opts) do
    from(l in Lexeme,
      join: sl in ScopeMember,
      on: sl.lexeme_id == l.object_id and sl.scope_id == ^scope.id
    )
    |> filter_query(opts[:q])
    |> filter_sources(:has, opts[:has])
    |> filter_sources(:missing, opts[:missing])
    |> filter_state(opts[:state], scope)
    |> filter_taxon(opts[:taxon])
  end

  defp filter_query(query, nil), do: query

  defp filter_query(query, q) do
    case String.trim(q) do
      "" ->
        query

      q ->
        where(
          query,
          [l],
          ilike(l.lemma, ^(escape_like(q) <> "%")) or fragment("? % ?", l.lemma, ^q)
        )
    end
  end

  defp filter_sources(query, _kind, nil), do: query
  defp filter_sources(query, _kind, []), do: query

  defp filter_sources(query, kind, slugs) do
    ids = source_ids(slugs)

    Enum.reduce(ids, query, fn id, acc ->
      case kind do
        :has -> where(acc, [l], fragment("? = ANY(?)", ^id, l.source_ids))
        :missing -> where(acc, [l], not fragment("? = ANY(?)", ^id, l.source_ids))
      end
    end)
  end

  defp filter_state(query, nil, _scope), do: query
  defp filter_state(query, :bare, _scope), do: where(query, [l], is_nil(l.enriched_at))
  defp filter_state(query, :enriched, _scope), do: where(query, [l], not is_nil(l.enriched_at))

  defp filter_state(query, :disputed, scope) do
    where(query, [l], l.object_id in subquery(disputed_ids_query(scope)))
  end

  defp filter_taxon(query, nil), do: query

  defp filter_taxon(query, qid) do
    where(query, [l], l.object_id in ^Encyclopedia.taxon_lexeme_ids(qid))
  end

  defp sorted(query, :coverage) do
    order_by(query, [l],
      desc: fragment("coalesce(array_length(?, 1), 0)", l.source_ids),
      asc: l.lemma,
      asc: l.part_of_speech
    )
  end

  defp sorted(query, _lemma), do: order_by(query, [l], asc: l.lemma, asc: l.part_of_speech)

  # The word's thing, for the label and the image. Asserted links only, best
  # confidence first — the same population A10 and L3 report on.
  #
  # `concept_links.status IN ('auto','confirmed')` has become two conditions that
  # were always what it meant: the assertion is current and active, and no
  # reviewer has rejected it. `Encyclopedia.linked_lexemes_query/1` applies both,
  # so a link a curator rejected stops counting here the moment they say so —
  # which is the defect the audit found, where a rerun returned it to `auto`.
  @linked_floor 0.7

  @doc """
  How many of a scope's words carry the thing the rows show — the same rule
  `with_concepts/1` applies (asserted, not rejected, confidence ≥ 0.7), so the
  figure and the rows cannot disagree.

  Wikidata attests things, not words: it never appears in `source_ids`, so
  "attested by" is always zero for it. This is its figure on the browse page.
  """
  def linked_count(scope_slug) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    from(sl in ScopeMember,
      where: sl.scope_id == ^scope.id and sl.lexeme_id in subquery(linked_lexeme_ids())
    )
    |> Repo.aggregate(:count)
  end

  defp linked_lexeme_ids do
    from(link in subquery(Encyclopedia.linked_lexemes_query()),
      where: link.confidence >= @linked_floor,
      select: link.lexeme_id,
      distinct: true
    )
  end

  defp with_concepts([]), do: []

  defp with_concepts(rows) do
    ids = Enum.map(rows, & &1.lexeme_id)

    concepts =
      from(link in subquery(Encyclopedia.linked_lexemes_query()),
        join: e in Entity,
        on: e.object_id == link.entity_id,
        left_join: x in ExternalIdentifier,
        on: x.object_id == e.object_id and x.namespace == "wikidata" and x.status == :verified,
        where: link.lexeme_id in ^ids and link.confidence >= @linked_floor,
        order_by: [asc: link.lexeme_id, desc: link.confidence],
        distinct: link.lexeme_id,
        select:
          {link.lexeme_id,
           %{
             object_id: e.object_id,
             qid: x.external_id,
             label: e.preferred_label,
             description: e.description,
             image_url: fragment("? ->> 'image_url'", e.metadata),
             taxon: fragment("? -> 'taxon'", e.metadata),
             confidence: link.confidence
           }}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, &Map.put(&1, :concept, Map.get(concepts, &1.lexeme_id)))
  end

  @doc """
  The lexemes in a scope whose links name two or more distinct things at or above
  `threshold` — L2's population, exposed so the browse filter and
  `Health.conflicts/3` share one definition.
  """
  def disputed_lexeme_ids(scope_slug, threshold \\ 0.7) do
    scope_slug
    |> Lexicon.get_scope_by_slug!()
    |> disputed_ids_query(threshold)
    |> Repo.all()
  end

  defp disputed_ids_query(scope, threshold \\ 0.7) do
    from link in subquery(Encyclopedia.linked_lexemes_query(min_confidence: 0.0)),
      join: sl in ScopeMember,
      on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
      where: link.confidence >= ^threshold,
      group_by: link.lexeme_id,
      having: count(link.entity_id, :distinct) > 1,
      select: link.lexeme_id
  end

  @doc "The five sources, keyed by slug, for badge rendering."
  def sources_by_slug do
    Map.new(Sources.list_sources(), &{&1.slug, &1})
  end

  defp source_ids(slugs) do
    by_slug = sources_by_slug()

    slugs
    |> List.wrap()
    |> Enum.map(&by_slug[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.id)
  end

  defp maybe_in_scope(query, nil), do: query

  defp maybe_in_scope(query, scope_slug) do
    case Lexicon.get_scope_by_slug(scope_slug) do
      nil ->
        query

      scope ->
        join(query, :inner, [l], sl in ScopeMember,
          on: sl.lexeme_id == l.object_id and sl.scope_id == ^scope.id
        )
    end
  end

  # A lemma may contain % or _ — `set-up`, `100%` — and an unescaped one turns a
  # prefix match into a wildcard.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
