defmodule DevilsDictionary.Encyclopedia do
  @moduledoc """
  The things side: entities, what they are kinds of, and what names them.

  Ported from the MVP-0 version, which read `concepts`, `concept_links` and
  `concept_relations`. Those three tables are gone; the same questions are now
  asked of `entities` and `assertion_revisions`, and the answers are the same
  shape so the word page's thing panel did not have to be redesigned.

  Three rules from U1b that survive the port unchanged, because they were right
  for reasons that have nothing to do with the schema:

    * **a thing's chain is not the taxon chain.** Prefer `parent_taxon`, fall
      back to `subclass_of`, and allow `instance_of` **only at the first step** —
      following it at every step walks *Larry* up to *abstract entity*. One
      parent per step, because the graph is a DAG and a plain walk fans out to
      eighteen rows for a walk of ten.
    * **kinds and examples are only the children that have a word**, because a
      chip that cannot be clicked is furniture.
    * **`refers_to` and `lexeme_entity_candidate` are different claims.** A
      sense-backed mapping says this meaning names that thing. A title match
      says this spelling might. The second never propagates examples, and the
      audit's "0.85 is not a probability" applies to it and not the first.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier}
  alias DevilsDictionary.Repo

  # Sense-backed. The word page's "what this meaning names".
  @refers_to "refers_to"
  # Word-level heuristic. Never sense equivalence.
  @candidate "lexeme_entity_candidate"
  # The hierarchy predicates, in the preference order the chain walks them.
  @up ~w(parent_taxon subclass_of)
  @instance "instance_of"

  @doc "An entity by a verified external identifier, or nil."
  def by_external_id(namespace, external_id) do
    Repo.one(
      from e in Entity,
        join: x in ExternalIdentifier,
        on: x.object_id == e.object_id,
        where: x.namespace == ^namespace and x.external_id == ^external_id and x.status == :verified
    )
  end

  @doc "An entity by QID, the common case of `by_external_id/2`."
  def by_qid(qid), do: by_external_id("wikidata", qid)

  @doc "An entity by QID. Raises."
  def by_qid!(qid) do
    by_qid(qid) || raise Ecto.NoResultsError, queryable: Entity
  end

  @doc "The QID of an entity, or nil."
  def qid(object_id) do
    Repo.one(
      from x in ExternalIdentifier,
        where:
          x.object_id == ^object_id and x.namespace == "wikidata" and x.status == :verified,
        select: x.external_id
    )
  end

  @doc """
  The things a word's meanings name, and the things its spelling might name.

  Two predicates, kept apart. `:refers_to` links come from a source's own sense
  mapping; `:candidate` links come from a title or disambiguation heuristic and
  carry their method and confidence so the page can say which is which.
  """
  def links_for(lexeme_id, opts \\ []) do
    sense_ids =
      from(s in DevilsDictionary.Registry.Sense,
        where: s.lexeme_id == ^lexeme_id and s.identity_state == :active,
        select: s.object_id
      )
      |> Repo.all()

    subjects = [lexeme_id | sense_ids]

    AssertionRevision
    |> join(:inner, [r], p in assoc(r, :predicate))
    |> where([r, p], r.subject_object_id in ^subjects and r.is_current)
    |> where([r, p], p.key in ^[@refers_to, @candidate])
    |> where([r], r.lifecycle_state == :active)
    |> then(fn q ->
      case opts[:min_confidence] do
        nil -> q
        min -> where(q, [r], is_nil(r.confidence) or r.confidence >= ^min)
      end
    end)
    |> order_by([r], desc: r.confidence, asc: r.id)
    |> limit(^(opts[:limit] || 50))
    |> preload([:predicate, object_object: :entity])
    |> Repo.all()
  end

  @doc """
  The one thing a word most likely names, or nil.

  Sense-backed `refers_to` outranks a word-level candidate however confident the
  candidate is: a title match is a guess about a spelling, and a sense mapping
  is a claim about a meaning. Within each, the highest confidence wins.
  """
  def primary_entity(lexeme_id, min_confidence \\ 0.7) do
    lexeme_id
    |> links_for(min_confidence: min_confidence)
    |> Enum.sort_by(fn r -> {rank(r.predicate.key), -(r.confidence || 0.0), r.id} end)
    |> List.first()
    |> case do
      nil -> nil
      revision -> Repo.get(Entity, revision.object_object_id)
    end
  end

  defp rank(@refers_to), do: 0
  defp rank(_), do: 1

  @chain_sql """
  WITH RECURSIVE up AS (
    SELECT $1::bigint AS id, 0 AS depth, ARRAY[$1::bigint] AS path
    UNION ALL
    SELECT step.parent_id, u.depth + 1, u.path || step.parent_id
    FROM up u
    CROSS JOIN LATERAL (
      SELECT r.object_object_id AS parent_id
      FROM assertion_revisions r
      JOIN predicates p ON p.id = r.predicate_id
      JOIN entities e ON e.object_id = r.object_object_id
      WHERE r.subject_object_id = u.id
        AND r.is_current AND r.lifecycle_state = 'active'
        AND (p.key = ANY($3::text[]) OR (u.depth = 0 AND p.key = $4))
      ORDER BY CASE p.key WHEN 'parent_taxon' THEN 0 WHEN 'subclass_of' THEN 1 ELSE 2 END,
               e.preferred_label
      LIMIT 1
    ) step
    WHERE u.depth < $2 AND NOT (step.parent_id = ANY(u.path))
  )
  SELECT u.depth, e.object_id, e.preferred_label, w.lemma, w.slug, w.object_id,
         (w.enriched_at IS NOT NULL) AS enriched
  FROM up u
  JOIN entities e ON e.object_id = u.id
  LEFT JOIN LATERAL (
    SELECT lx.lemma, lx.slug, lx.object_id, lx.enriched_at
    FROM assertion_revisions link
    JOIN predicates lp ON lp.id = link.predicate_id
    JOIN senses s ON s.object_id = link.subject_object_id
    JOIN lexemes lx ON lx.object_id = s.lexeme_id
    WHERE link.object_object_id = u.id AND link.is_current
      AND link.lifecycle_state = 'active' AND lp.key = $5
    ORDER BY link.confidence DESC NULLS LAST, lx.object_id
    LIMIT 1
  ) w ON TRUE
  WHERE u.depth > 0
  ORDER BY u.depth
  """

  @doc """
  The walk upward from a thing — *oyster › Bivalvia › Mollusca*.

  One parent per step, taxonomy preferred, `instance_of` only at the first step.
  Steps that have a word carry its id and slug so the chain is hoppable; steps
  that do not are still shown, because a gap in the middle of a chain is the
  chain.
  """
  def chain(%Entity{} = entity, max_depth \\ 8) do
    %{rows: rows} =
      Repo.query!(@chain_sql, [entity.object_id, max_depth, @up, @instance, @refers_to])

    for [depth, object_id, label, lemma, slug, lexeme_id, enriched] <- rows do
      %{
        depth: depth,
        object_id: object_id,
        label: label,
        lemma: lemma,
        slug: slug,
        lexeme_id: lexeme_id,
        enriched?: enriched
      }
    end
  end

  @kinds_sql """
  WITH children AS (
    SELECT r.subject_object_id AS id,
           CASE WHEN p.key = 'instance_of' THEN 'example' ELSE 'kind' END AS bucket
    FROM assertion_revisions r
    JOIN predicates p ON p.id = r.predicate_id
    WHERE r.object_object_id = $1
      AND r.is_current AND r.lifecycle_state = 'active'
      AND p.key IN ('parent_taxon', 'subclass_of', 'instance_of')
  ),
  worded AS (
    SELECT c.id, c.bucket, e.preferred_label, w.lemma, w.slug, w.object_id AS lexeme_id
    FROM children c
    JOIN entities e ON e.object_id = c.id
    JOIN LATERAL (
      SELECT lx.lemma, lx.slug, lx.object_id
      FROM assertion_revisions link
      JOIN predicates lp ON lp.id = link.predicate_id
      JOIN senses s ON s.object_id = link.subject_object_id
      JOIN lexemes lx ON lx.object_id = s.lexeme_id
      WHERE link.object_object_id = c.id AND link.is_current
        AND link.lifecycle_state = 'active' AND lp.key = $3
      ORDER BY link.confidence DESC NULLS LAST, lx.object_id
      LIMIT 1
    ) w ON TRUE
  )
  SELECT bucket, id, preferred_label, lemma, slug, lexeme_id,
         COUNT(*) OVER (PARTITION BY bucket) AS total,
         ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY lemma) AS rank
  FROM worded
  ORDER BY bucket, lemma
  """

  @doc """
  What kinds of this thing there are, and which named individuals it has.

  **Only the children that have a word.** The panel exists so a reader can hop,
  so a chip that cannot be clicked is furniture — *cat* has four named
  individuals under it and not one of them is a word, while ten of its nineteen
  subclasses are.

  Capped, with the exact total beside the cap: the count is the expensive half
  on a hub, and knowing there are 7,141 is worth more than seeing twelve of them
  and wondering.
  """
  def kinds_and_examples(object_id, cap \\ 12) do
    %{rows: rows} = Repo.query!(@kinds_sql, [object_id, cap, @refers_to])

    rows
    |> Enum.map(fn [bucket, id, label, lemma, slug, lexeme_id, total, rank] ->
      %{
        bucket: String.to_existing_atom(bucket),
        object_id: id,
        label: label,
        lemma: lemma,
        slug: slug,
        lexeme_id: lexeme_id,
        total: total,
        rank: rank
      }
    end)
    |> Enum.group_by(& &1.bucket)
    |> Map.new(fn {bucket, items} ->
      {bucket,
       %{total: List.first(items).total, items: Enum.filter(items, &(&1.rank <= cap))}}
    end)
  end

  @doc """
  The other things a word's spellings and meanings might name.

  Two questions, deliberately separate. `:may_refer_to` is the word-level
  candidates — the disambiguation page's list. `:disagreement` is when a word's
  *meanings* name more than one thing, which is ordinary polysemy far more often
  than it is a conflict, so the caller is handed both and the UI says "the
  sources name more than one thing" rather than claiming they disagree.
  """
  def candidates_for(lexeme_ids, opts \\ []) do
    ids = List.wrap(lexeme_ids)

    sense_ids =
      Repo.all(
        from s in DevilsDictionary.Registry.Sense,
          where: s.lexeme_id in ^ids and s.identity_state == :active,
          select: s.object_id
      )

    may_refer_to =
      AssertionRevision
      |> join(:inner, [r], p in assoc(r, :predicate))
      |> where([r, p], r.subject_object_id in ^ids and p.key == @candidate)
      |> where([r], r.is_current and r.lifecycle_state == :active)
      |> order_by([r], desc: r.confidence, asc: r.id)
      |> limit(^(opts[:limit] || 12))
      |> preload(object_object: :entity)
      |> Repo.all()

    asserted =
      AssertionRevision
      |> join(:inner, [r], p in assoc(r, :predicate))
      |> where([r, p], r.subject_object_id in ^sense_ids and p.key == @refers_to)
      |> where([r], r.is_current and r.lifecycle_state == :active)
      |> preload(object_object: :entity)
      |> Repo.all()

    distinct = asserted |> Enum.map(& &1.object_object_id) |> Enum.uniq()

    %{
      may_refer_to: may_refer_to,
      disagreement: if(length(distinct) > 1, do: asserted, else: [])
    }
  end

  @doc "The articles and other content published about a thing."
  def content_about(object_id, opts \\ []) do
    AssertionRevision
    |> join(:inner, [r], p in assoc(r, :predicate))
    |> where([r, p], r.object_object_id == ^object_id and p.key == "about")
    |> where([r], r.is_current and r.lifecycle_state == :active)
    |> limit(^(opts[:limit] || 20))
    |> preload(subject_object: :content_item)
    |> Repo.all()
  end
end
