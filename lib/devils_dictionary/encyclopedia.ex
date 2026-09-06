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
  The direct children of a taxon, each with the size of its subtree — the tree
  panel on `/s/:slug`.

  `taxon_chain/2` walks up; this walks down, over the same `parent_taxon` edges
  and the same index (`concept_relations_to_concept_id_type_index`). One
  recursive query, not one per child: the walk carries the direct child each
  descendant descends from, so every child's counts come back together.
  Measured from Animalia (Q729), the whole subtree is 20 ms and there are
  fifteen children, so this needs no cache and no precomputed column.

  `scope_lexemes` counts the words in `scope_slug` that an **asserted** link
  (`auto` or `confirmed`) attaches anywhere in the subtree — the population A10
  and L3 report on, and the one the list filter then shows.
  """
  def taxon_children(qid, scope_slug \\ "animals", max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE root AS (
          SELECT id FROM concepts WHERE qid = $1
        ),
        down(child_id, id, depth) AS (
          SELECT r.from_concept_id, r.from_concept_id, 1
            FROM concept_relations r JOIN root ON r.to_concept_id = root.id
           WHERE r.type = 'parent_taxon'
          UNION
          SELECT down.child_id, r.from_concept_id, down.depth + 1
            FROM concept_relations r
            JOIN down ON r.to_concept_id = down.id
           WHERE r.type = 'parent_taxon' AND down.depth < $3
        ),
        -- The same (child, descendant) pair arrives at several depths in a DAG,
        -- and joining the links onto the duplicates is what made this slow.
        pairs AS (SELECT DISTINCT child_id, id FROM down),
        scoped AS (
          SELECT DISTINCT cl.concept_id AS id, sl.lexeme_id
            FROM concept_links cl
            JOIN scope_lexemes sl
              ON sl.lexeme_id = cl.lexeme_id
             AND sl.scope_id = (SELECT id FROM scopes WHERE slug = $2)
           WHERE cl.status IN ('auto', 'confirmed')
        ),
        counts AS (
          SELECT p.child_id,
                 count(DISTINCT p.id) AS subtree,
                 count(DISTINCT s.lexeme_id) AS scope_lexemes
            FROM pairs p LEFT JOIN scoped s ON s.id = p.id
           GROUP BY p.child_id
        )
        SELECT c.id, c.qid, c.label, c.description, c.taxon,
               counts.subtree, counts.scope_lexemes,
               EXISTS (
                 SELECT 1 FROM concept_relations r2
                  WHERE r2.to_concept_id = c.id AND r2.type = 'parent_taxon'
               ) AS has_children
          FROM counts JOIN concepts c ON c.id = counts.child_id
         ORDER BY counts.scope_lexemes DESC, c.label
        """,
        [qid, scope_slug, max_depth]
      )

    for [id, qid, label, description, taxon, subtree, scope_lexemes, has_children] <- rows do
      %{
        id: id,
        qid: qid,
        label: label,
        description: description,
        taxon: taxon,
        subtree: subtree,
        scope_lexemes: scope_lexemes,
        has_children?: has_children
      }
    end
  end

  @doc """
  Every concept id in a taxon's subtree, including the taxon itself.

  Distinct: in a DAG the same concept is reachable at several depths, and the
  recursive term carries a depth, so the raw union repeats it. Animalia's
  subtree comes back as 114,666 rows without the `DISTINCT` and 10,799 with it.
  """
  def taxon_descendants(qid, max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE down(id, depth) AS (
          SELECT id, 0 FROM concepts WHERE qid = $1
          UNION
          SELECT r.from_concept_id, down.depth + 1
            FROM concept_relations r
            JOIN down ON r.to_concept_id = down.id
           WHERE r.type = 'parent_taxon' AND down.depth < $2
        )
        SELECT DISTINCT id FROM down
        """,
        [qid, max_depth]
      )

    Enum.map(rows, &hd/1)
  end

  @doc """
  The lexeme ids an asserted link attaches anywhere inside a taxon's subtree.

  One statement, so the browse filter never has to ship a subtree of concept ids
  through the application. Animalia, the widest case, is 10,799 concepts in and
  8,470 lexemes out, in 114 ms; a family like Felidae is 2 ms.
  """
  def taxon_lexeme_ids(qid, max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE down(id, depth) AS (
          SELECT id, 0 FROM concepts WHERE qid = $1
          UNION
          SELECT r.from_concept_id, down.depth + 1
            FROM concept_relations r
            JOIN down ON r.to_concept_id = down.id
           WHERE r.type = 'parent_taxon' AND down.depth < $2
        )
        SELECT DISTINCT cl.lexeme_id
          FROM concept_links cl
         WHERE cl.status IN ('auto', 'confirmed')
           AND cl.concept_id IN (SELECT id FROM down)
        """,
        [qid, max_depth]
      )

    Enum.map(rows, &hd/1)
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

  @chain_sql """
  WITH RECURSIVE walk AS (
    SELECT $1::bigint AS id, 0 AS depth, ARRAY[$1::bigint] AS path
    UNION ALL
    SELECT p.to_concept_id, w.depth + 1, w.path || p.to_concept_id
    FROM walk w
    CROSS JOIN LATERAL (
      SELECT r.to_concept_id
      FROM concept_relations r
      JOIN concepts c ON c.id = r.to_concept_id
      WHERE r.from_concept_id = w.id
        AND (r.type IN ('parent_taxon', 'subclass_of')
             OR (w.depth = 0 AND r.type = 'instance_of'))
      ORDER BY CASE r.type WHEN 'parent_taxon' THEN 0 WHEN 'subclass_of' THEN 1 ELSE 2 END,
               c.label
      LIMIT 1
    ) p
    WHERE w.depth < $2 AND NOT (p.to_concept_id = ANY(w.path))
  )
  SELECT w.depth, c.qid, c.label, l.lemma, l.slug, (l.enriched_at IS NOT NULL) AS enriched
  FROM walk w
  JOIN concepts c ON c.id = w.id
  LEFT JOIN LATERAL (
    SELECT lx.lemma, lx.slug, lx.enriched_at
    FROM concept_links cl
    JOIN lexemes lx ON lx.id = cl.lexeme_id
    WHERE cl.concept_id = w.id AND cl.status IN ('auto', 'confirmed')
      AND cl.confidence >= 0.7
    ORDER BY cl.confidence DESC, lx.id
    LIMIT 1
  ) l ON TRUE
  WHERE w.depth > 0
  ORDER BY w.depth
  """

  @doc """
  The walk upward from a thing — *oyster › Bivalvia › Mollusca* — whatever kind
  of thing it is.

  `taxon_chain/2` answers this for living things and returns nothing for
  everything else, because `parent_taxon` is the only edge it knows. Emotions,
  artefacts and ideas climb by `subclass_of` instead, and a named individual
  (`instance_of`) takes one step to its class and climbs from there. So the
  preference is taxonomy, then class, then — at the first step only — kind:
  letting `instance_of` run at every depth walks *Larry* up to *entity*.

  One parent per step, as the word page's synset chain does: a `concepts` DAG
  gives *oyster* two parents at several ranks and eighteen rows for a walk of
  ten. Steps that have a word carry its slug, so a chain is hoppable; steps
  that do not are still shown, because a gap in the middle of a chain is the
  chain.
  """
  def chain(%Concept{} = concept, max_depth \\ 8) do
    start = concept.taxon_concept_id || concept.id

    %{rows: rows} = Repo.query!(@chain_sql, [start, max_depth])

    for [depth, qid, label, lemma, slug, enriched] <- rows do
      %{depth: depth, qid: qid, label: label, lemma: lemma, slug: slug, enriched?: enriched}
    end
  end

  @kinds_sql """
  WITH children AS (
    SELECT r.from_concept_id AS id,
           CASE WHEN r.type = 'instance_of' THEN 'example' ELSE 'kind' END AS bucket
      FROM concept_relations r
     WHERE r.to_concept_id = $1
       AND r.type IN ('parent_taxon', 'subclass_of', 'instance_of')
     GROUP BY 1, 2
  ),
  worded AS (
    SELECT ch.bucket, c.qid, c.label, w.lemma, w.slug, w.enriched
      FROM children ch
      JOIN concepts c ON c.id = ch.id
      JOIN LATERAL (
        SELECT lx.lemma, lx.slug, (lx.enriched_at IS NOT NULL) AS enriched
          FROM concept_links cl
          JOIN lexemes lx ON lx.id = cl.lexeme_id
         WHERE cl.concept_id = ch.id AND cl.status IN ('auto', 'confirmed')
           AND cl.confidence >= 0.7
         ORDER BY cl.confidence DESC, lx.id
         LIMIT 1
      ) w ON TRUE
  ),
  ranked AS (
    SELECT worded.*,
           count(*) OVER (PARTITION BY bucket) AS total,
           row_number() OVER (PARTITION BY bucket ORDER BY enriched DESC, lemma) AS rn
      FROM worded
  )
  SELECT bucket, qid, label, lemma, slug, enriched, total
    FROM ranked WHERE rn <= $2 ORDER BY bucket, rn
  """

  @doc """
  What this thing has under it: its **kinds** (`subclass_of` and `parent_taxon`
  pointing at it) and its **examples** (`instance_of`).

  Only children that have a word are returned. The point of the panel is the
  hop, and a chip that cannot be clicked is furniture: *cat* has four named
  individuals under it — *Larry*, *Tiddles* — and not one of them is a word.

  Capped, with the **exact** total beside it, so the “+N” is a number and not a
  guess. The count is the expensive half on a hub — Q16521 *taxon* carries
  14,964 children, 7,141 of them worded, and answers in about 85 ms.
  """
  def kinds_and_examples(concept_id, cap \\ 12) do
    %{rows: rows} = Repo.query!(@kinds_sql, [concept_id, cap])

    empty = %{shown: [], total: 0}

    buckets =
      rows
      |> Enum.group_by(&hd/1)
      |> Map.new(fn {bucket, rows} ->
        {bucket,
         %{
           total: rows |> hd() |> List.last(),
           shown:
             for [_bucket, qid, label, lemma, slug, enriched, _total] <- rows do
               %{qid: qid, label: label, lemma: lemma, slug: slug, enriched?: enriched}
             end
         }}
      end)

    %{
      kinds: Map.get(buckets, "kind", empty),
      examples: Map.get(buckets, "example", empty)
    }
  end

  @doc """
  The two states where the sources do not agree about what a word names.

  **Disagreement** is more than one concept asserted at or above the threshold —
  *cat* is the animal and the Unix utility, *seal* is the mammal and the wax —
  and #69 says we surface it rather than pick a winner. **May refer to** is the
  `:candidate` population, the 0.40 links a disambiguation page suggested and
  nothing has corroborated: a possibility, not a claim, and never the same list.
  """
  def candidates_for(lexeme_ids, opts \\ []) do
    min_confidence = opts[:min_confidence] || 0.7
    cap = opts[:cap] || 12

    links =
      Repo.all(
        from cl in ConceptLink,
          where: cl.lexeme_id in ^lexeme_ids and cl.status != :rejected,
          order_by: [desc: cl.confidence, asc: cl.method, asc: cl.id],
          preload: [:concept]
      )

    asserted =
      links
      |> Enum.filter(
        &(&1.status in [:auto, :confirmed] and (&1.confidence || 0.0) >= min_confidence)
      )
      |> Enum.uniq_by(& &1.concept_id)

    %{
      disagreement: if(length(asserted) > 1, do: Enum.map(asserted, &claim/1), else: []),
      may_refer_to:
        links
        |> Enum.filter(&(&1.status == :candidate))
        |> Enum.uniq_by(& &1.concept_id)
        |> Enum.take(cap)
        |> Enum.map(&claim/1)
    }
  end

  defp claim(%ConceptLink{concept: concept} = link) do
    %{
      qid: concept.qid,
      label: concept.label,
      description: concept.description,
      method: link.method,
      confidence: link.confidence,
      status: link.status
    }
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
