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

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, Object, ObjectName, Sense}
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
        where:
          x.namespace == ^namespace and x.external_id == ^external_id and x.status == :verified
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
        where: x.object_id == ^object_id and x.namespace == "wikidata" and x.status == :verified,
        select: x.external_id
    )
  end

  @doc """
  An entity as the pages show it.

  MVP-0's `concepts` row was both the identity and the display shape, so a
  template could read `concept.qid` and `concept.taxon` off the struct. Identity
  and description have separated — the QID is an `external_identifiers` row and
  the image, article title and taxon facts are `metadata` — so this is the one
  place that flattening happens, and every surface reads the same keys.
  """
  def view(nil), do: nil

  def view(%Entity{} = entity) do
    %{
      object_id: entity.object_id,
      qid: qid(entity.object_id),
      label: entity.preferred_label,
      description: entity.description,
      kind: entity.entity_kind,
      image_url: DevilsDictionary.SourceIdentity.Display.image_url(entity),
      image_attribution: entity.metadata["image_attribution"],
      wikipedia_title: entity.metadata["wikipedia_title"],
      taxon: entity.metadata["taxon"]
    }
  end

  @doc """
  Searches entity identities by their preferred label.

  This is deliberately independent of lexical search. A person and a word
  with the same label are two results and remain two identities; discovery
  never merges them on spelling or slug.
  """
  def search_entities(query, opts \\ []) do
    query = String.trim(query || "")

    if query == "" do
      []
    else
      limit = Keyword.get(opts, :limit, 10)
      down = String.downcase(query)

      preferred_candidates =
        Entity
        |> entity_name_match(:preferred, query)
        |> select([e], %{object_id: e.object_id})

      alias_candidates =
        ObjectName
        |> entity_name_match(:alias, query)
        |> select([name], %{object_id: name.object_id})

      candidates = union_all(preferred_candidates, ^alias_candidates)

      Repo.all(
        from e in Entity,
          join: candidate in subquery(candidates),
          on: candidate.object_id == e.object_id,
          join: object in Object,
          on: object.id == e.object_id and object.lifecycle_state == :active,
          group_by: e.object_id,
          order_by: [
            asc:
              fragment(
                "CASE WHEN lower(?) LIKE ? THEN 0 ELSE 1 END",
                e.preferred_label,
                ^(down <> "%")
              ),
            desc: fragment("similarity(?, ?)", e.preferred_label, ^query),
            asc: fragment("length(?)", e.preferred_label),
            asc: e.preferred_label,
            asc: e.object_id
          ],
          limit: ^limit,
          select: %{
            object_id: e.object_id,
            label: e.preferred_label,
            kind: e.entity_kind,
            description: e.description
          }
      )
    end
  end

  # Keep preferred labels and aliases in separate indexed arms. Combining them
  # with a correlated EXISTS under one OR forced a sequential scan of every
  # entity even when only a handful matched. The outer group preserves one
  # identity when both a preferred label and an alias match.
  defp entity_name_match(queryable, :preferred, query) do
    if String.length(query) < 3 do
      where(queryable, [e], ilike(e.preferred_label, ^(escape_like(query) <> "%")))
    else
      where(
        queryable,
        [e],
        ilike(e.preferred_label, ^(escape_like(query) <> "%")) or
          fragment("? % ?", e.preferred_label, ^query)
      )
    end
  end

  defp entity_name_match(queryable, :alias, query) do
    if String.length(query) < 3 do
      where(queryable, [name], ilike(name.name, ^(escape_like(query) <> "%")))
    else
      where(
        queryable,
        [name],
        ilike(name.name, ^(escape_like(query) <> "%")) or fragment("? % ?", name.name, ^query)
      )
    end
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc "The QIDs of many objects at once, keyed by object id. One query."
  def qids(object_ids) do
    Repo.all(
      from x in ExternalIdentifier,
        where:
          x.object_id in ^Enum.uniq(object_ids) and x.namespace == "wikidata" and
            x.status == :verified,
        select: {x.object_id, x.external_id}
    )
    |> Map.new()
  end

  @doc """
  The things a word's meanings name, and the things its spelling might name.

  Two predicates, kept apart. `:refers_to` links come from a source's own sense
  mapping; `:candidate` links come from a title or disambiguation heuristic and
  carry their method and confidence so the page can say which is which.
  """
  def links_for(lexeme_id, opts \\ []) do
    sense_ids =
      from(s in Sense,
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
    |> Claims.visible(:public)
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
  Every link off a word, flattened for display, in **one** query.

  `links_for/2` returns assertion revisions and needs three more queries to turn
  them into something a drawer can print — the sense ids, the QIDs, the derived
  review state. On a page that is already ten queries that is four more for a
  panel, and the ⓘ click budget is five. So this joins what it needs and derives
  the decision in the same statement.

  The decision is still derived rather than stored, which is the property that
  stops an importer writing it.
  """
  def link_views(lexeme_id) do
    AssertionRevision
    |> join(:inner, [r], p in assoc(r, :predicate))
    |> join(:left, [r], s in Sense, on: s.object_id == r.subject_object_id)
    |> join(:inner, [r], e in Entity, on: e.object_id == r.object_object_id)
    |> where([r, p], p.key in ^[@refers_to, @candidate])
    |> where([r], r.is_current and r.lifecycle_state == :active)
    |> where([r, _p, s], s.lexeme_id == ^lexeme_id or r.subject_object_id == ^lexeme_id)
    |> Claims.visible(:public)
    |> order_by([r], desc: r.confidence, asc: r.id)
    |> select([r, p, _s, e], %{
      revision_id: r.id,
      qid:
        fragment(
          "(SELECT external_id FROM external_identifiers WHERE object_id = ? AND namespace = 'wikidata' AND status = 'verified' ORDER BY external_id LIMIT 1)",
          e.object_id
        ),
      label: e.preferred_label,
      predicate: p.key,
      method: r.method,
      confidence: r.confidence
    })
    |> Repo.all()
    |> then(fn rows ->
      states = Claims.display_review_states(Enum.map(rows, & &1.revision_id))
      Enum.map(rows, &Map.put(&1, :status, states |> Map.fetch!(&1.revision_id) |> to_string()))
    end)
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
    SELECT c.id, c.bucket, e.preferred_label, w.lemma, w.slug, w.object_id AS lexeme_id,
           (w.enriched_at IS NOT NULL) AS enriched
    FROM children c
    JOIN entities e ON e.object_id = c.id
    JOIN LATERAL (
      SELECT lx.lemma, lx.slug, lx.object_id, lx.enriched_at
      FROM assertion_revisions link
      JOIN predicates lp ON lp.id = link.predicate_id
      JOIN senses s ON s.object_id = link.subject_object_id
      JOIN lexemes lx ON lx.object_id = s.lexeme_id
      WHERE link.object_object_id = c.id AND link.is_current
        AND link.lifecycle_state = 'active' AND lp.key = $2
      ORDER BY link.confidence DESC NULLS LAST, lx.object_id
      LIMIT 1
    ) w ON TRUE
  )
  SELECT bucket, id, preferred_label, lemma, slug, lexeme_id, enriched,
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
    # The cap is applied below rather than in SQL: the window function needs the
    # whole partition to report an exact total, which is the number worth having.
    %{rows: rows} = Repo.query!(@kinds_sql, [object_id, @refers_to])

    rows
    |> Enum.map(fn [bucket, id, label, lemma, slug, lexeme_id, enriched, total, rank] ->
      %{
        bucket: String.to_existing_atom(bucket),
        object_id: id,
        label: label,
        lemma: lemma,
        slug: slug,
        lexeme_id: lexeme_id,
        enriched?: enriched,
        total: total,
        rank: rank
      }
    end)
    |> Enum.group_by(& &1.bucket)
    |> Map.new(fn {bucket, items} ->
      {bucket, %{total: List.first(items).total, items: Enum.filter(items, &(&1.rank <= cap))}}
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
        from s in Sense,
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

    # Both lists are handed to the panel as `view/1` maps, the same shape the
    # concept card reads, so a template never has to know that a link is an
    # assertion revision and a thing is an entity plus an identifier row.
    %{
      may_refer_to: Enum.map(may_refer_to, &candidate_view/1),
      disagreement: if(length(distinct) > 1, do: Enum.map(asserted, &candidate_view/1), else: [])
    }
  end

  defp candidate_view(%AssertionRevision{} = revision) do
    revision.object_object.entity
    |> view()
    |> Map.merge(%{method: revision.method, confidence: revision.confidence})
  end

  # ── the taxonomy, walked down ─────────────────────────────────────────────
  #
  # `concept_relations.type = 'parent_taxon'` becomes an assertion revision on
  # the `parent_taxon` predicate, and `concept_links` becomes `refers_to` and
  # `lexeme_entity_candidate`. The algorithms are the MVP-0 ones: the walk
  # carries the direct child each descendant descends from so every child's
  # counts come back together, and the (child, descendant) pairs are DISTINCTed
  # before the links join, which is what made this fast on a DAG.

  # MVP-0's `concept_links.status` had four values and "asserted" meant `auto`
  # or `confirmed`; a `candidate` from a "may refer to" page was a possibility
  # rather than a claim, and sat at 0.40 while the ladder's own rungs sat at
  # 0.70 and above. In this model editorial state is a review — append-only, so
  # no importer rerun can return a rejected link to `auto` — and the proposal /
  # claim distinction is what it always was underneath: the confidence.
  #
  # One number, stated once, so A10, L3, the browse badge and the Wikidata seed
  # cannot drift apart on what "linked" means.
  @asserted_floor 0.7

  @doc "The confidence at or above which a link is a claim rather than a proposal."
  def asserted_floor, do: @asserted_floor

  # A word that an asserted link attaches to an entity. `refers_to` reaches the
  # lexeme through its sense; `lexeme_entity_candidate` names it directly. Both
  # count, because the browse badge means "this word is linked to that thing".
  @linked_lexemes_sql """
  SELECT DISTINCT lx.object_id AS lexeme_id, r.object_object_id AS entity_id
    FROM assertion_revisions r
    JOIN predicates p ON p.id = r.predicate_id
    JOIN LATERAL (
      SELECT CASE
               WHEN p.key = 'refers_to' THEN (SELECT s.lexeme_id FROM senses s
                                               WHERE s.object_id = r.subject_object_id)
               ELSE r.subject_object_id
             END AS object_id
    ) lx ON lx.object_id IS NOT NULL
   WHERE r.is_current AND r.lifecycle_state = 'active'
     AND p.key IN ('refers_to', 'lexeme_entity_candidate')
     AND (r.confidence IS NULL OR r.confidence >= __FLOOR__)
     AND COALESCE(
           (SELECT ar.decision FROM assertion_reviews ar
             WHERE ar.assertion_revision_id = r.id
             ORDER BY ar.inserted_at DESC, ar.id DESC LIMIT 1),
           'needs_review'
         ) NOT IN ('rejected', 'withdrawn')
  """

  @doc """
  Every lexeme an asserted link attaches to an entity, as raw SQL.

  Exposed because the two recursive walks above have to inline it. The composable
  form is `linked_lexemes_query/1`, and `encyclopedia_test.exs` asserts the two
  return the same pairs — one rule with two spellings is exactly the drift the
  moduledoc warns about, so it is held down by a test rather than by care.

  `min_confidence` defaults to `asserted_floor/0`. Pass `0.0` for the wider
  population L3 reports beside its own — the guard is `is_float/1` rather than
  a bound parameter because this is inlined into a CTE, and the only callers are
  in this application.
  """
  def linked_lexemes_sql(min_confidence \\ @asserted_floor) when is_float(min_confidence),
    do: String.replace(@linked_lexemes_sql, "__FLOOR__", Float.to_string(min_confidence))

  @doc """
  The same rule as `linked_lexemes_sql/0`, composable.

  Selects `%{lexeme_id, entity_id, confidence, predicate_key, revision_id}`.
  `refers_to` reaches the lexeme through its sense; `lexeme_entity_candidate`
  names the lexeme directly, so the left join finds nothing and the coalesce
  falls through to the subject itself.

  Public by default: a link a reviewer rejected is not one the browse page may
  count. Pass `visibility: :internal` for a review queue.

  `min_confidence` defaults to `asserted_floor/0`, the same as
  `linked_lexemes_sql/1`, so the two spellings of the rule agree unless a caller
  says otherwise. L1 counts the same population at several thresholds and passes
  `min_confidence: 0.0` to widen it — visibly, at the call site, rather than by
  the default quietly differing between the two forms.
  """
  def linked_lexemes_query(opts \\ []) do
    from(r in AssertionRevision,
      join: p in assoc(r, :predicate),
      left_join: s in Sense,
      on: s.object_id == r.subject_object_id,
      where: p.key in ^[@refers_to, @candidate],
      where: r.is_current and r.lifecycle_state == :active,
      select: %{
        lexeme_id: fragment("COALESCE(?, ?)", s.lexeme_id, r.subject_object_id),
        entity_id: r.object_object_id,
        confidence: r.confidence,
        method: r.method,
        predicate_key: p.key,
        revision_id: r.id,
        # L1 reports the rate twice: once for what the ladder's own confidences
        # reach, once after corroboration lifted the title matches a second
        # signal agreed with. Carrying the flag here is what lets the strict
        # reading be a `where` rather than a second definition of a link.
        corroborated: fragment("jsonb_exists(?, 'corroboration')", r.metadata)
      }
    )
    |> then(fn q ->
      min = Keyword.get(opts, :min_confidence, @asserted_floor)
      where(q, [r], is_nil(r.confidence) or r.confidence >= ^min)
    end)
    |> Claims.visible(opts[:visibility] || :public)
  end

  @doc """
  The direct children of a taxon, each with the size of its subtree.

  `chain/2` walks up; this walks down, over the same `parent_taxon` edges. One
  recursive query, not one per child.

  `scope_lexeme_members` counts the words in `scope_slug` that an asserted link
  attaches anywhere in the subtree — the population A10 and L3 report on, and
  the one the list filter then shows.
  """
  def taxon_children(qid, scope_slug, max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE root AS (
          SELECT x.object_id AS id FROM external_identifiers x
           WHERE x.namespace = 'wikidata' AND x.external_id = $1 AND x.status = 'verified'
        ),
        edges AS (
          SELECT r.subject_object_id AS child_id, r.object_object_id AS parent_id
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
           WHERE p.key = 'parent_taxon' AND r.is_current AND r.lifecycle_state = 'active'
        ),
        down(child_id, id, depth) AS (
          SELECT e.child_id, e.child_id, 1 FROM edges e JOIN root ON e.parent_id = root.id
          UNION
          SELECT down.child_id, e.child_id, down.depth + 1
            FROM edges e JOIN down ON e.parent_id = down.id
           WHERE down.depth < $3
        ),
        -- The same (child, descendant) pair arrives at several depths in a DAG,
        -- and joining the links onto the duplicates is what made this slow.
        pairs AS (SELECT DISTINCT child_id, id FROM down),
        linked AS (#{linked_lexemes_sql()}),
        scoped AS (
          SELECT DISTINCT linked.entity_id AS id, m.lexeme_id
            FROM linked
            JOIN scope_lexeme_members m
              ON m.lexeme_id = linked.lexeme_id
             AND m.scope_id = (SELECT id FROM scopes WHERE slug = $2)
        ),
        counts AS (
          SELECT p.child_id,
                 count(DISTINCT p.id) AS subtree,
                 count(DISTINCT s.lexeme_id) AS scope_lexemes
            FROM pairs p LEFT JOIN scoped s ON s.id = p.id
           GROUP BY p.child_id
        )
        SELECT e.object_id, x.external_id, e.preferred_label, e.description,
               e.metadata->'taxon' AS taxon,
               counts.subtree, counts.scope_lexemes,
               EXISTS (SELECT 1 FROM edges e2 WHERE e2.parent_id = e.object_id) AS has_children
          FROM counts
          JOIN entities e ON e.object_id = counts.child_id
          LEFT JOIN external_identifiers x
            ON x.object_id = e.object_id AND x.namespace = 'wikidata' AND x.status = 'verified'
         ORDER BY counts.scope_lexemes DESC, e.preferred_label
        """,
        [qid, scope_slug, max_depth]
      )

    for [id, qid, label, description, taxon, subtree, scope_lexemes, has_children] <- rows do
      %{
        id: id,
        object_id: id,
        qid: qid,
        label: label,
        description: description,
        taxon: taxon,
        image_url: nil,
        subtree: subtree,
        scope_lexemes: scope_lexemes,
        has_children?: has_children
      }
    end
  end

  @doc """
  Every entity id in a taxon's subtree, including the taxon itself.

  Distinct: in a DAG the same entity is reachable at several depths, and the
  recursive term carries a depth, so the raw union repeats it.
  """
  def taxon_descendants(qid, max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE down(id, depth) AS (
          SELECT x.object_id, 0 FROM external_identifiers x
           WHERE x.namespace = 'wikidata' AND x.external_id = $1 AND x.status = 'verified'
          UNION
          SELECT r.subject_object_id, down.depth + 1
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
            JOIN down ON r.object_object_id = down.id
           WHERE p.key = 'parent_taxon' AND r.is_current AND r.lifecycle_state = 'active'
             AND down.depth < $2
        )
        SELECT DISTINCT id FROM down
        """,
        [qid, max_depth]
      )

    Enum.map(rows, &hd/1)
  end

  @doc """
  The lexeme ids an asserted link attaches anywhere inside a taxon's subtree.

  One statement, so the browse filter never has to ship a subtree of entity ids
  through the application.
  """
  def taxon_lexeme_ids(qid, max_depth \\ 40) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE down(id, depth) AS (
          SELECT x.object_id, 0 FROM external_identifiers x
           WHERE x.namespace = 'wikidata' AND x.external_id = $1 AND x.status = 'verified'
          UNION
          SELECT r.subject_object_id, down.depth + 1
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
            JOIN down ON r.object_object_id = down.id
           WHERE p.key = 'parent_taxon' AND r.is_current AND r.lifecycle_state = 'active'
             AND down.depth < $2
        ),
        linked AS (#{linked_lexemes_sql()})
        SELECT DISTINCT linked.lexeme_id
          FROM linked
         WHERE linked.entity_id IN (SELECT id FROM down)
        """,
        [qid, max_depth]
      )

    Enum.map(rows, &hd/1)
  end

  @doc """
  The `parent_taxon` chain above an entity, nearest first.

  Starts at the entity's taxon item when it has one, because the everyday
  concept and the taxon are different entities: *Cat* (Q146) carries no P171,
  *Felis catus* (Q20980826) carries the whole chain to Animalia. The bridge is
  the `taxon_item` predicate, Wikidata's P13176.

  Depth-capped, so a cycle in the data cannot hang a page render.
  """
  def taxon_chain(%Entity{} = entity, max_depth \\ 40) do
    start = taxon_item(entity.object_id) || entity.object_id

    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE up(id, depth) AS (
          SELECT $1::bigint, 0
          UNION ALL
          SELECT r.object_object_id, up.depth + 1
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
            JOIN up ON r.subject_object_id = up.id
           WHERE p.key = 'parent_taxon' AND r.is_current AND r.lifecycle_state = 'active'
             AND up.depth < $2
        )
        SELECT DISTINCT ON (e.object_id) e.object_id, min(up.depth) OVER (PARTITION BY e.object_id)
          FROM up JOIN entities e ON e.object_id = up.id
         WHERE up.depth > 0
         ORDER BY e.object_id
        """,
        [start, max_depth]
      )

    ids = Enum.map(rows, &hd/1)
    depth = Map.new(rows, fn [id, d] -> {id, d} end)

    Entity
    |> where([e], e.object_id in ^ids)
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(depth, &1.object_id))
  end

  @doc "The taxon item bridged from an everyday concept (P13176), or nil."
  def taxon_item(object_id) do
    Repo.one(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: r.subject_object_id == ^object_id and p.key == "taxon_item",
        where: r.is_current and r.lifecycle_state == :active,
        limit: 1,
        select: r.object_object_id
    )
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
