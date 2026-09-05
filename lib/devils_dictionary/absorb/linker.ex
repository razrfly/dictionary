defmodule DevilsDictionary.Absorb.Linker do
  @moduledoc """
  The word ↔ thing ladder (#69 §5): every `concept_links` row records **how** we
  know and **how sure** we are, and a conflict is surfaced rather than resolved.

  Six rungs, each one statement, each re-runnable:

  | # | method | signal | confidence |
  |---|---|---|---|
  | 1 | `wiktionary_qid` | a Wiktionary sense carries `wikidata: ["Q146"]` | 0.95 |
  | 2 | `wordnet_wikidata` | the OEWN synset itself carries a QID | 0.90 |
  | 3 | `wordnet_ili` | the synset's ILI matches the concept's `P5063` | 0.85 |
  | 4 | `title_match` | the lemma's Wikipedia title is the concept's article | 0.70 |
  | 5 | `disambiguation` | a candidate from a "may refer to" page | 0.40 → 0.60 |
  | 6 | `manual` | an editor override; the mechanism only, no rows | 1.00 |

  ## Why there is a seventh step

  Measured before any of this was written: of 21,277 Animals lexemes, **4,216**
  have a WordNet sense carrying a QID and **546** a Wiktionary one — about 21 %.
  L1 asks for 70 % of the scope at confidence ≥ 0.8, and `title_match` is pinned
  at 0.70, *below* that bar. So the ladder as written cannot reach L1 no matter
  how well Wikipedia does, and the load has to fall on title matches.

  §5 already allows for this — confidence is "adjusted by checks" — so
  `corroborate/1` raises a title match when a **second, independent** signal
  agrees, and records which one in `metadata["corroboration"]`:

    * the concept is a taxon whose scientific name (`P225`) or English common
      name (`P1843`) is the lemma → **0.90**
    * a QID rung already links that same lexeme to that same concept → **0.90**
      and `status: :confirmed`, because two methods agreeing is the strongest
      evidence available without a human
    * the article's description or extract shares content words with a
      WordNet or Wiktionary gloss for the lexeme → **0.85**

  `mix dd.link` prints L1 **both ways**, strict ladder and corroborated, so the
  honest number and the useful one are both on the record.
  """

  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Repo

  # The one place the ladder's numbers live.
  @confidence %{
    wiktionary_qid: 0.95,
    wordnet_wikidata: 0.90,
    wordnet_ili: 0.85,
    title_match: 0.70,
    disambiguation: 0.40
  }

  # Raised confidences, applied by `corroborate/1`.
  @corroborated_taxon 0.90
  @corroborated_agreement 0.90
  @corroborated_gloss 0.85
  @disambiguation_gloss 0.60

  # Two shared words of four letters or more. Short words carry no signal
  # ("the", "and", "of"), and one shared word is a coincidence at this scale.
  @min_word_length 4
  @min_shared_words 2

  # #69 §5 says `pos = noun` for a title match. Wiktionary files proper nouns
  # under their own `name` part of speech, which the spec did not anticipate:
  # *Wild Turkey*, *Electrona* and *Sweet William* are things, and 505 scope
  # lexemes are `name`. Adjectives and verbs stay out — a thing is not an
  # adjective.
  @nominal ~w(noun name)

  @doc "The confidence each method is written at, before corroboration."
  def confidence, do: @confidence

  @doc "The parts of speech a thing can attach to."
  def nominal_pos, do: @nominal

  defp nominal, do: "(" <> Enum.map_join(@nominal, ", ", &"'#{&1}'") <> ")"

  @doc """
  Runs every rung, then the corroboration pass. Returns counts per step.

  Idempotent: each rung upserts on `(lexeme_id, coalesce(sense_id,0), concept_id,
  method)`, so a second run rewrites the same rows rather than duplicating them.
  """
  def run(scope \\ nil, opts \\ []) do
    rungs = %{
      wiktionary_qid: wiktionary_qid(scope),
      wordnet_wikidata: wordnet_wikidata(scope),
      wordnet_ili: wordnet_ili(scope),
      title_match: title_match(scope),
      disambiguation: disambiguation(scope)
    }

    corroboration = if opts[:skip_corroboration], do: %{}, else: corroborate(scope)

    %{rungs: rungs, corroboration: corroboration}
  end

  # ── rung 1 · wiktionary_qid ──────────────────────────────────────────────

  @doc false
  def wiktionary_qid(scope) do
    insert_links(
      """
      SELECT s.lexeme_id, s.id, c.id, s.source_id, 'wiktionary_qid',
             #{@confidence.wiktionary_qid}, 'auto', '{}'::jsonb, now(), now()
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wiktionary'
        CROSS JOIN LATERAL jsonb_array_elements_text(#{jsonb_array("s.metadata->'wikidata'")}) AS q(qid)
        JOIN concepts c ON c.qid = q.qid
       #{scope_join(scope, "s.lexeme_id")}
       WHERE jsonb_typeof(s.metadata->'wikidata') = 'array'
      """,
      scope
    )
  end

  # ── rung 2 · wordnet_wikidata ────────────────────────────────────────────

  @doc false
  def wordnet_wikidata(scope) do
    insert_links(
      """
      SELECT s.lexeme_id, s.id, c.id, s.source_id, 'wordnet_wikidata',
             #{@confidence.wordnet_wikidata}, 'auto', '{}'::jsonb, now(), now()
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wordnet'
        JOIN concepts c ON c.qid = s.metadata->>'wikidata'
       #{scope_join(scope, "s.lexeme_id")}
       WHERE jsonb_typeof(s.metadata->'wikidata') = 'string'
      """,
      scope
    )
  end

  # ── rung 3 · wordnet_ili ─────────────────────────────────────────────────

  @doc false
  def wordnet_ili(scope) do
    insert_links(
      """
      SELECT s.lexeme_id, s.id, c.id, s.source_id, 'wordnet_ili',
             #{@confidence.wordnet_ili}, 'auto', '{}'::jsonb, now(), now()
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wordnet'
        JOIN concepts c ON c.wordnet_ili = s.metadata->>'ili'
       #{scope_join(scope, "s.lexeme_id")}
       WHERE s.metadata->>'ili' IS NOT NULL
      """,
      scope
    )
  end

  # ── rung 4 · title_match ─────────────────────────────────────────────────

  # `source_id` is null: nobody asserted this, we inferred it from a title.
  # Nominal parts of speech only, and never a disambiguation page — "Seal may
  # refer to…" is not a thing the word denotes.
  @doc false
  def title_match(scope) do
    insert_links(
      """
      SELECT l.id, NULL::bigint, c.id, NULL::bigint, 'title_match',
             #{@confidence.title_match}, 'auto', '{}'::jsonb, now(), now()
        FROM lexemes l
        JOIN concepts c ON c.wikipedia_title = l.metadata->>'wikipedia_title'
       #{scope_join(scope, "l.id")}
       WHERE l.pos IN #{nominal()}
         AND NOT jsonb_exists(c.metadata, 'disambiguation')
         AND NOT jsonb_exists(l.metadata, 'wikipedia_disambiguation')
      """,
      scope
    )
  end

  # ── rung 5 · disambiguation ──────────────────────────────────────────────

  # Candidates come out of the record the Wikipedia pass already stored, so the
  # "may refer to" panel and this rung cost no extra fetch. Status `candidate`,
  # never `auto`: these are possibilities, not conclusions.
  @doc false
  def disambiguation(scope) do
    insert_links(
      """
      SELECT l.id, NULL::bigint, c.id, NULL::bigint, 'disambiguation',
             #{@confidence.disambiguation}, 'candidate',
             jsonb_build_object('disambiguation_page', r.raw->>'title'), now(), now()
        FROM source_records r
        JOIN sources so ON so.id = r.source_id AND so.slug = 'wikipedia'
        CROSS JOIN LATERAL jsonb_array_elements(#{jsonb_array("r.raw->'_candidates'")}) AS cand
        JOIN concepts c ON c.qid = cand->>'qid'
        CROSS JOIN LATERAL jsonb_array_elements(#{jsonb_array("r.raw->'_probe'->'lexemes'")}) AS key
        JOIN lexemes l ON l.lang = key->>0 AND l.lemma = key->>1 AND l.pos = key->>2
       #{scope_join(scope, "l.id")}
       WHERE jsonb_typeof(r.raw->'_candidates') = 'array'
         AND l.pos IN #{nominal()}
      """,
      scope
    )
  end

  # ── corroboration ────────────────────────────────────────────────────────

  @doc """
  Raises `title_match` confidence where a second signal agrees, and promotes a
  disambiguation candidate whose description matches a gloss.

  Runs last and in this order: agreement is the strongest evidence, so it is
  applied after the weaker two and overwrites them.
  """
  def corroborate(scope \\ nil) do
    %{
      taxon: corroborate_taxon(scope),
      gloss: corroborate_gloss(scope),
      agreement: corroborate_agreement(scope),
      disambiguation_gloss: promote_candidates(scope)
    }
  end

  # The lemma is the taxon's scientific name or one of its English common names
  # — either on the concept itself, or on the taxon item it bridges to.
  defp corroborate_taxon(scope) do
    update_links(
      """
      UPDATE concept_links cl
         SET confidence = #{@corroborated_taxon},
             metadata = cl.metadata || '{"corroboration": "taxon_name"}'::jsonb,
             updated_at = now()
        FROM lexemes l, concepts c
       WHERE cl.lexeme_id = l.id
         AND cl.concept_id = c.id
         AND cl.method = 'title_match'
         AND cl.confidence < #{@corroborated_taxon}
         AND EXISTS (
           SELECT 1 FROM concepts t
            WHERE t.id IN (c.id, coalesce(c.taxon_concept_id, c.id))
              AND (
                lower(t.taxon->>'scientific_name') = lower(l.lemma)
                OR EXISTS (
                  SELECT 1
                    FROM jsonb_array_elements_text(
                           CASE WHEN jsonb_typeof(t.taxon->'common_names') = 'array'
                                THEN t.taxon->'common_names' ELSE '[]'::jsonb END) AS n
                   WHERE lower(n) = lower(l.lemma))
              ))
         #{scope_exists(scope, "cl.lexeme_id")}
      """,
      scope
    )
  end

  # The article and a dictionary agree about what the word means. Approximated
  # by shared content words rather than by a stopword list: four letters or more
  # is a good enough proxy, and two of them agreeing is not chance.
  defp corroborate_gloss(scope) do
    update_links(
      """
      UPDATE concept_links cl
         SET confidence = #{@corroborated_gloss},
             metadata = cl.metadata || '{"corroboration": "gloss_overlap"}'::jsonb,
             updated_at = now()
        FROM concepts c, entries e
       WHERE cl.concept_id = c.id
         AND e.concept_id = c.id
         AND cl.method = 'title_match'
         AND cl.confidence < #{@corroborated_gloss}
         AND EXISTS (
           SELECT 1 FROM senses s
            WHERE s.lexeme_id = cl.lexeme_id
              AND s.gloss IS NOT NULL
              AND #{shared_words("s.gloss", "coalesce(e.body, '') || ' ' || coalesce(c.description, '')")}
                >= #{@min_shared_words})
         #{scope_exists(scope, "cl.lexeme_id")}
      """,
      scope
    )
  end

  # Two independent methods naming the same thing. `confirmed` rather than
  # `auto`: this is as sure as anything gets without a person.
  defp corroborate_agreement(scope) do
    update_links(
      """
      UPDATE concept_links cl
         SET confidence = #{@corroborated_agreement},
             status = 'confirmed',
             metadata = cl.metadata || '{"corroboration": "qid_agreement"}'::jsonb,
             updated_at = now()
       WHERE cl.method = 'title_match'
         AND EXISTS (
           SELECT 1 FROM concept_links other
            WHERE other.lexeme_id = cl.lexeme_id
              AND other.concept_id = cl.concept_id
              AND other.method IN ('wiktionary_qid', 'wordnet_wikidata', 'wordnet_ili'))
         #{scope_exists(scope, "cl.lexeme_id")}
      """,
      scope
    )
  end

  # #69 §5: a candidate rises from 0.40 to 0.60 when a Wiktionary sense gloss
  # matches the candidate's description. It stays a `candidate` — the "may refer
  # to" panel is a list of possibilities, and promotion only reorders it.
  defp promote_candidates(scope) do
    update_links(
      """
      UPDATE concept_links cl
         SET confidence = #{@disambiguation_gloss},
             metadata = cl.metadata || '{"corroboration": "candidate_gloss"}'::jsonb,
             updated_at = now()
        FROM concepts c
       WHERE cl.concept_id = c.id
         AND cl.method = 'disambiguation'
         AND cl.confidence < #{@disambiguation_gloss}
         AND c.description IS NOT NULL
         AND EXISTS (
           SELECT 1 FROM senses s
             JOIN sources so ON so.id = s.source_id AND so.slug = 'wiktionary'
            WHERE s.lexeme_id = cl.lexeme_id
              AND s.gloss IS NOT NULL
              AND #{shared_words("s.gloss", "c.description")} >= #{@min_shared_words})
         #{scope_exists(scope, "cl.lexeme_id")}
      """,
      scope
    )
  end

  # ── SQL helpers ──────────────────────────────────────────────────────────

  # `jsonb_array_elements` raises on a scalar, and Postgres is free to evaluate a
  # LATERAL before the WHERE clause that would have filtered the row out. So the
  # guard goes *inside* the call, never beside it: `senses.metadata->'wikidata'`
  # is an array from Wiktionary and a bare string from WordNet, in one table.
  defp jsonb_array(expression) do
    "CASE WHEN jsonb_typeof(#{expression}) = 'array' THEN #{expression} ELSE '[]'::jsonb END"
  end

  # Distinct words of >= @min_word_length letters present in both texts.
  defp shared_words(a, b) do
    """
    (SELECT count(*) FROM (
       SELECT unnest(regexp_split_to_array(lower(#{a}), '[^a-z]+')) AS w
       INTERSECT
       SELECT unnest(regexp_split_to_array(lower(#{b}), '[^a-z]+')) AS w
     ) shared WHERE length(shared.w) >= #{@min_word_length})
    """
  end

  defp scope_join(nil, _column), do: ""

  defp scope_join(%Scope{}, column),
    do: "JOIN scope_lexemes sl ON sl.lexeme_id = #{column} AND sl.scope_id = $1"

  defp scope_exists(nil, _column), do: ""

  defp scope_exists(%Scope{}, column) do
    "AND EXISTS (SELECT 1 FROM scope_lexemes sl WHERE sl.lexeme_id = #{column} AND sl.scope_id = $1)"
  end

  defp params(nil), do: []
  defp params(%Scope{id: id}), do: [id]

  # Every rung ends the same way, so the conflict clause lives once.
  #
  # Two details, both of which Postgres enforces the hard way:
  #
  #   * the unique index is on an expression (`coalesce(sense_id, 0)`), so the
  #     conflict target must be written as the expression, not a column list;
  #   * `ON CONFLICT DO UPDATE` refuses to touch one row twice **within a single
  #     statement**, so a rung that can propose the same key twice — a
  #     Wiktionary sense listing one QID twice, two candidate titles redirecting
  #     to one article — must be deduplicated before it gets there. That is what
  #     the `DISTINCT ON` wrapper is for; it is the SQL twin of the
  #     `Enum.uniq_by/2` calls in `Materializer`.
  #
  # A rung with no sense or no asserting source must write `NULL::bigint`, not a
  # bare `NULL`: inside the subquery an untyped NULL is `text`, and
  # `coalesce(sense_id, 0)` then fails to match types.
  defp insert_links(select, scope) do
    %{num_rows: n} =
      Repo.query!(
        """
        INSERT INTO concept_links
          (lexeme_id, sense_id, concept_id, source_id, method,
           confidence, status, metadata, inserted_at, updated_at)
        SELECT DISTINCT ON (lexeme_id, coalesce(sense_id, 0), concept_id, method) *
          FROM (
        #{select}
          ) AS rows(lexeme_id, sense_id, concept_id, source_id, method,
                    confidence, status, metadata, inserted_at, updated_at)
         ORDER BY lexeme_id, coalesce(sense_id, 0), concept_id, method
        ON CONFLICT (lexeme_id, coalesce(sense_id, 0), concept_id, method)
        DO UPDATE SET confidence = EXCLUDED.confidence,
                      status = EXCLUDED.status,
                      metadata = concept_links.metadata || EXCLUDED.metadata,
                      updated_at = EXCLUDED.updated_at
        """,
        params(scope),
        timeout: :infinity
      )

    n
  end

  # Named `update_links` rather than `update`: `import Ecto.Query` brings its own
  # `update/2` macro into scope and it wins.
  defp update_links(sql, scope) do
    %{num_rows: n} = Repo.query!(sql, params(scope), timeout: :infinity)
    n
  end
end
