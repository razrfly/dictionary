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
      right: Wikipedia's prose hangs off `entries.concept_id` and never off a
      lexeme, so a join says 0 where the truth is 18,028; Wikidata writes neither
      senses nor entries at all. What a badge means is *this source attests this
      word*, which is what the scorecard means too.

    * **"disputed" has one definition.** `disputed_lexeme_ids/2` is the same
      predicate `Health.conflicts/3` reports on — two distinct concepts at or
      above the threshold for one lexeme — so the filter and the number cannot
      drift apart.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Lexeme, ScopeLexeme}
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
      |> where([l], l.lang == ^lang)
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
        asc: l.pos
      )
      |> limit(^limit)
      |> select([l], %{
        lexeme_id: l.id,
        lemma: l.lemma,
        pos: l.pos,
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

  Filtered — `scope: :any | "animals"`, `enriched: true` — the population is
  small (26,203 enriched rows across the two scopes), so it is counted once and
  taken at a random offset: exact, and one query per word drawn. That is the
  shape *Surprise me* wants, because a random word out of 1.5 million is a bare
  row 90 % of the time and lands the reader on a page with nothing on it.

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
  One enriched word from either scope — the home page's *Surprise me*.

  Returns a `%{id, slug, lemma}` or `nil` on an empty database.
  """
  def random_word do
    case random_lexemes(sample: 1, scope: :any, enriched: true) do
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
          |> order_by([l], asc: l.id)
          |> offset(^offset)
          |> limit(1)
          |> select([l], %{id: l.id, slug: l.slug, lemma: l.lemma})
          |> Repo.all()
        end)
    end
  end

  defp random_base(opts) do
    Lexeme
    |> from(as: :lexeme)
    |> where([l], l.lang == ^Keyword.get(opts, :lang, "en"))
    |> then(fn q ->
      if opts[:enriched], do: where(q, [l], not is_nil(l.enriched_at)), else: q
    end)
    |> random_scope(opts[:scope])
  end

  defp random_scope(query, nil), do: query

  defp random_scope(query, :any) do
    where(
      query,
      exists(from sl in ScopeLexeme, where: sl.lexeme_id == parent_as(:lexeme).id, select: 1)
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
            from sl in ScopeLexeme,
              where: sl.lexeme_id == parent_as(:lexeme).id and sl.scope_id == ^scope.id,
              select: 1
          )
        )
    end
  end

  defp draw_over_ids(sample) do
    case Repo.one(from l in Lexeme, select: {min(l.id), max(l.id)}) do
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
          where: l.id in ^ids,
          select: %{id: l.id, slug: l.slug, lemma: l.lemma}
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
        lexeme_id: l.id,
        lemma: l.lemma,
        pos: l.pos,
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
      join: sl in ScopeLexeme,
      on: sl.lexeme_id == l.id and sl.scope_id == ^scope.id
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
    where(query, [l], l.id in subquery(disputed_ids_query(scope)))
  end

  defp filter_taxon(query, nil), do: query

  defp filter_taxon(query, qid) do
    where(query, [l], l.id in ^Encyclopedia.taxon_lexeme_ids(qid))
  end

  defp sorted(query, :coverage) do
    order_by(query, [l],
      desc: fragment("coalesce(array_length(?, 1), 0)", l.source_ids),
      asc: l.lemma,
      asc: l.pos
    )
  end

  defp sorted(query, _lemma), do: order_by(query, [l], asc: l.lemma, asc: l.pos)

  # The word's thing, for the label and the image. Asserted links only, best
  # confidence first — the same population A10 and L3 report on.
  @doc """
  How many of a scope's words carry the concept the rows show — the same
  `concept_links` rule `with_concepts/1` applies (status auto or confirmed,
  confidence ≥ 0.7), so the figure and the rows cannot disagree.

  Wikidata attests things, not words: it never appears in `source_ids`, so
  "attested by" is always zero for it. This is its figure on the browse page.
  """
  def linked_count(scope_slug) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    from(sl in ScopeLexeme,
      where: sl.scope_id == ^scope.id and sl.lexeme_id in subquery(linked_lexeme_ids())
    )
    |> Repo.aggregate(:count)
  end

  defp linked_lexeme_ids do
    from(cl in ConceptLink,
      where: cl.status in [:auto, :confirmed] and cl.confidence >= 0.7,
      select: cl.lexeme_id,
      distinct: true
    )
  end

  defp with_concepts([]), do: []

  defp with_concepts(rows) do
    ids = Enum.map(rows, & &1.lexeme_id)

    concepts =
      from(cl in ConceptLink,
        join: c in Concept,
        on: c.id == cl.concept_id,
        where: cl.lexeme_id in ^ids and cl.status in [:auto, :confirmed] and cl.confidence >= 0.7,
        order_by: [asc: cl.lexeme_id, desc: cl.confidence],
        distinct: cl.lexeme_id,
        select:
          {cl.lexeme_id,
           %{
             qid: c.qid,
             label: c.label,
             description: c.description,
             image_url: c.image_url,
             taxon: c.taxon,
             confidence: cl.confidence
           }}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, &Map.put(&1, :concept, Map.get(concepts, &1.lexeme_id)))
  end

  @doc """
  The lexemes in a scope with two or more concepts at or above `threshold` —
  L2's population, exposed so the browse filter and `Health.conflicts/3` share
  one definition.
  """
  def disputed_lexeme_ids(scope_slug, threshold \\ 0.7) do
    scope_slug
    |> Lexicon.get_scope_by_slug!()
    |> disputed_ids_query(threshold)
    |> Repo.all()
  end

  defp disputed_ids_query(scope, threshold \\ 0.7) do
    from cl in ConceptLink,
      join: sl in ScopeLexeme,
      on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
      where: cl.confidence >= ^threshold and cl.status != :rejected,
      group_by: cl.lexeme_id,
      having: count(cl.concept_id, :distinct) > 1,
      select: cl.lexeme_id
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
        join(query, :inner, [l], sl in ScopeLexeme,
          on: sl.lexeme_id == l.id and sl.scope_id == ^scope.id
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
