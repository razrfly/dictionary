defmodule DevilsDictionary.Encyclopedia do
  @moduledoc """
  Things. Schemas and queries for `concepts` (keyed by Wikidata QID),
  `concept_relations` (taxonomy first) and `concept_links` (the word ↔ thing
  bridge with method, confidence and status). Encyclopedias attach here.
  Spec: issue #69 §4.

  Reads live here rather than in `Absorb.Linker`: the linker writes the bridge,
  the word page walks it, and the two should not be the same module.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
  alias DevilsDictionary.Lexicon.Entry
  alias DevilsDictionary.Repo

  @doc "One concept by QID."
  def get_concept_by_qid(qid), do: Repo.get_by(Concept, qid: qid)

  @doc "One concept by QID, raising."
  def get_concept_by_qid!(qid), do: Repo.get_by!(Concept, qid: qid)

  @doc """
  Every concept a word is linked to, best first, with the method and confidence
  that put it there.

  `status: :candidate` rows are included — they are the "may refer to" panel —
  so a caller that wants only settled links filters on `status` or on
  `confidence`.
  """
  def links_for(lexeme_id, opts \\ []) do
    query =
      from cl in ConceptLink,
        where: cl.lexeme_id == ^lexeme_id and cl.status != :rejected,
        order_by: [desc: cl.confidence, asc: cl.method],
        preload: [:concept]

    query =
      case opts[:min_confidence] do
        nil -> query
        min -> where(query, [cl], cl.confidence >= ^min)
      end

    query =
      case opts[:status] do
        nil -> query
        status -> where(query, [cl], cl.status == ^status)
      end

    Repo.all(query)
  end

  @doc """
  The best concept for a word: highest confidence, `:candidate` rows excluded.

  This is what the word page's image and taxon panel hang off, so a
  disambiguation candidate must never win it.
  """
  def primary_concept(lexeme_id, min_confidence \\ 0.7) do
    Repo.one(
      from cl in ConceptLink,
        join: c in assoc(cl, :concept),
        where: cl.lexeme_id == ^lexeme_id,
        where: cl.status in [:auto, :confirmed],
        where: cl.confidence >= ^min_confidence,
        order_by: [desc: cl.confidence, asc: cl.id],
        limit: 1,
        select: c
    )
  end

  @doc """
  The `parent_taxon` chain above a concept, nearest first.

  Starts at the concept's taxon item when it has one, because the everyday
  concept and the taxon are different entities: *Cat* (Q146) carries no `P171`,
  *Felis catus* (Q20980826) carries the whole chain to Animalia.

  Depth-capped, so a cycle in the data cannot hang a page render.
  """
  def taxon_chain(%Concept{} = concept, max_depth \\ 40) do
    start = concept.taxon_concept_id || concept.id

    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE up(id, depth) AS (
          SELECT $1::bigint, 0
          UNION ALL
          SELECT r.to_concept_id, up.depth + 1
            FROM concept_relations r
            JOIN up ON r.from_concept_id = up.id
           WHERE r.type = 'parent_taxon' AND up.depth < $2
        )
        SELECT DISTINCT ON (c.id) c.id, min(up.depth) OVER (PARTITION BY c.id)
          FROM up JOIN concepts c ON c.id = up.id
         WHERE up.depth > 0
         ORDER BY c.id
        """,
        [start, max_depth]
      )

    ids = Enum.map(rows, &hd/1)
    depth = Map.new(rows, fn [id, d] -> {id, d} end)

    Concept
    |> where([c], c.id in ^ids)
    |> Repo.all()
    |> Enum.sort_by(&depth[&1.id])
  end

  @doc "The entries an encyclopedia published about a thing."
  def entries_for(concept_id) do
    Repo.all(
      from e in Entry,
        where: e.concept_id == ^concept_id,
        order_by: [asc: e.position],
        preload: [:source]
    )
  end
end
