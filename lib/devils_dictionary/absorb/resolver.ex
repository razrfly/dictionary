defmodule DevilsDictionary.Absorb.Resolver do
  @moduledoc """
  Fills in the two columns that cannot be known while a record is being
  materialized: `lexical_relations.to_lexeme_id` and `lexemes.canonical_lexeme_id`.

  `materialize/1` is pure and per record, so when Wiktionary says *cat* has the
  hypernym *feline* all it can write is the string. `to_lemma` is kept forever
  either way (#69 §4) — this pass only adds the edge's other end when we have
  the word, and an unresolved edge stays a perfectly good edge.

  WordNet needs none of this: its graph is closed and its sense ids are
  deterministic, so `Sources.Wordnet` resolves inside the absorb and this pass
  never sees its rows (they already have `to_lexeme_id`). Scorecard row R1 is
  WordNet's; **R2** is this module's, and wants >= 80 % of Wiktionary's edges
  resolved.

  ## Picking one target out of many

  `feline` exists as a noun and an adjective, so `lower(to_lemma)` alone is
  ambiguous. The order of preference is: the pos the source stated, then an
  exact-case lemma match (so *Turkey* does not answer for *turkey*), then a
  plain part-of-speech priority, then the oldest row. Deterministic, and it
  never invents a link the source did not imply.
  """

  import Ecto.Query

  alias DevilsDictionary.Lexicon.{Lexeme, LexicalRelation}
  alias DevilsDictionary.Repo

  # Big enough that the planner picks index scans, small enough that no single
  # statement locks a million rows.
  @window 200_000

  @pos_priority ~w(noun verb adj adv name phrase)

  @doc """
  Resolves relation targets and canonical variants.

  Options: `:source_id` to restrict to one source. Returns the numbers
  `mix dd.resolve` prints and scorecard row R2 reads.
  """
  def run(opts \\ []) do
    source_id = opts[:source_id]

    resolved = resolve_targets(source_id)
    canonical = link_canonical()

    %{
      resolved: resolved,
      canonical: canonical,
      by_type: by_type(source_id),
      unresolved_lemmas: unresolved_lemmas(source_id)
    }
  end

  @doc """
  Points every unresolved `to_lemma` at a lexeme, where one exists.

  A `DISTINCT ON` join rather than a correlated subquery in `SET`: a subquery
  that finds nothing would write NULL over NULL and still count as an update,
  which would make the number this returns a lie.
  """
  def resolve_targets(source_id \\ nil) do
    {min_id, max_id} = id_range(source_id)

    if is_nil(min_id) do
      0
    else
      min_id
      |> id_windows(max_id)
      |> Enum.reduce(0, fn {from, to}, acc -> acc + resolve_window(source_id, from, to) end)
    end
  end

  defp resolve_window(source_id, from, to) do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE lexical_relations r
           SET to_lexeme_id = c.lexeme_id, updated_at = now()
          FROM (
            SELECT DISTINCT ON (r2.id) r2.id AS relation_id, l.id AS lexeme_id
              FROM lexical_relations r2
              JOIN lexemes l
                ON l.lang = 'en' AND lower(l.lemma) = lower(r2.to_lemma)
             WHERE r2.to_lexeme_id IS NULL
               AND r2.id >= $1 AND r2.id < $2
               AND ($3::bigint IS NULL OR r2.source_id = $3)
             ORDER BY r2.id,
                      (l.pos = r2.to_pos) DESC NULLS LAST,
                      (l.lemma = r2.to_lemma) DESC,
                      array_position($4::text[], l.pos) NULLS LAST,
                      l.id
          ) c
         WHERE r.id = c.relation_id
        """,
        [from, to, source_id, @pos_priority],
        timeout: :infinity
      )

    n
  end

  @doc """
  Points spelling variants and inflected entries at their canonical lexeme.

  `alt_of` wins over `form_of` when a word has both: *oistre* is a variant
  spelling of *oyster* (an identity), while *oysters* is an inflection of it (a
  form). Only fills an empty slot, never overwrites an editor's choice, and
  refuses to close a two-lexeme cycle.
  """
  def link_canonical do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE lexemes v
           SET canonical_lexeme_id = c.target_id, updated_at = now()
          FROM (
            SELECT DISTINCT ON (r.from_lexeme_id)
                   r.from_lexeme_id AS lexeme_id, r.to_lexeme_id AS target_id
              FROM lexical_relations r
             WHERE r.type IN ('alt_of', 'form_of')
               AND r.to_lexeme_id IS NOT NULL
               AND r.to_lexeme_id <> r.from_lexeme_id
             ORDER BY r.from_lexeme_id, (r.type = 'alt_of') DESC, r.id
          ) c
         WHERE v.id = c.lexeme_id
           AND v.canonical_lexeme_id IS NULL
           AND NOT EXISTS (
             SELECT 1 FROM lexemes t
              WHERE t.id = c.target_id AND t.canonical_lexeme_id = v.id
           )
        """,
        [],
        timeout: :infinity
      )

    n
  end

  @doc """
  Resolved and unresolved edge counts per relation type. Scorecard row R2 wants
  the unresolved side *reported* by type, not just totalled.
  """
  def by_type(source_id \\ nil) do
    from(r in LexicalRelation,
      group_by: r.type,
      select: {
        r.type,
        %{
          total: count(r.id),
          resolved: filter(count(r.id), not is_nil(r.to_lexeme_id))
        }
      }
    )
    |> for_source(source_id)
    |> Repo.all()
    |> Map.new(fn {type, counts} ->
      {to_string(type), Map.put(counts, :unresolved, counts.total - counts.resolved)}
    end)
  end

  @doc """
  The most-referenced targets we still cannot place — the list to read when R2
  falls short.
  """
  def unresolved_lemmas(source_id \\ nil, limit \\ 20) do
    from(r in LexicalRelation,
      where: is_nil(r.to_lexeme_id),
      group_by: r.to_lemma,
      order_by: [desc: count(r.id)],
      limit: ^limit,
      select: {r.to_lemma, count(r.id)}
    )
    |> for_source(source_id)
    |> Repo.all()
  end

  defp for_source(query, nil), do: query
  defp for_source(query, source_id), do: from(r in query, where: r.source_id == ^source_id)

  defp id_range(source_id) do
    from(r in LexicalRelation,
      where: is_nil(r.to_lexeme_id),
      select: {min(r.id), max(r.id)}
    )
    |> for_source(source_id)
    |> Repo.one()
  end

  defp id_windows(min_id, max_id) do
    Stream.unfold(min_id, fn
      from when from > max_id -> nil
      from -> {{from, from + @window}, from + @window}
    end)
  end

  @doc """
  Lexemes that carry no senses of their own but resolve to one that does — what
  `Lexicon.lookup/1` follows. Exposed for tests and the health page.
  """
  def canonical_of(%Lexeme{canonical_lexeme_id: nil}), do: nil
  def canonical_of(%Lexeme{canonical_lexeme_id: id}), do: Repo.get(Lexeme, id)
end
