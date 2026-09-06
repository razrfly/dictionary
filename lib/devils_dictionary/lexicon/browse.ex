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
