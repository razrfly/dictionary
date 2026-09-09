defmodule DevilsDictionary.Absorb.Linker do
  @moduledoc """
  The word ↔ thing ladder (#69 §5): every link records **how** we know and **how
  sure** we are, and a conflict is surfaced rather than resolved.

  Six rungs, each one statement, each re-runnable:

  | # | method | signal | confidence |
  |---|---|---|---|
  | 1 | `wiktionary_qid` | a Wiktionary sense carries `wikidata: ["Q146"]` | 0.95 |
  | 2 | `wordnet_wikidata` | the OEWN synset itself carries a QID | 0.90 |
  | 3 | `wordnet_ili` | the synset's ILI matches the entity's `P5063` | 0.85 |
  | 4 | `title_match` | the lemma's Wikipedia title is the entity's article | 0.70 |
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
  agrees, and records which one in the revision's `metadata["corroboration"]`:

    * the entity is a taxon whose scientific name (`P225`) or English common
      name (`P1843`) is the lemma → **0.90**
    * a QID rung already links that same word to that same entity → **0.90**
    * the article's description or extract shares content words with a WordNet
      or Wiktionary gloss for the lexeme → **0.85**

  `mix dd.link` prints L1 **both ways**, strict ladder and corroborated, so the
  honest number and the useful one are both on the record.

  ## Two policy changes #74 requires

  **A sense-backed link and a spelling-level guess are different claims.** Rungs
  1–3 read a *source's own* mapping from one meaning to one thing and write
  `refers_to`, whose subject is the sense. Rungs 4 and 5 match a spelling
  against an article title and write `lexeme_entity_candidate`, whose subject is
  the word. A candidate can appear as a possible subject; it never confers sense
  equivalence and never propagates examples. That was audit finding #7.

  **A rerun may not resurrect a rejected link.** MVP-0 wrote `status` as a
  column and every rung's `ON CONFLICT DO UPDATE` overwrote it, so a link a
  curator rejected returned to `auto` the next time the rung ran. Editorial
  state is an append-only review now, and the rungs skip any claim whose
  standing decision is `rejected`. The automatic `confirmed` is gone with it:
  two methods agreeing is strong evidence and is recorded as confidence and
  provenance, not as a review nobody performed — the audit asked for exactly
  that distinction.

  ## Why the write is not raw SQL

  The reads are: each rung is one set-based statement over a million rows, which
  is the only sane way to do this. The **write** goes through
  `Materializer.write_assertions/3`, so the ladder and the importer share one
  revision policy, one idempotency key and one ownership rule. Two spellings of
  "write a claim" is how the two halves of a corpus come to disagree.
  """

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

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

  @sense_backed "refers_to"
  @word_level "lexeme_entity_candidate"

  @doc "The confidence each method is written at, before corroboration."
  def confidence, do: @confidence

  @doc "The parts of speech a thing can attach to."
  def nominal_pos, do: @nominal

  defp nominal, do: "(" <> Enum.map_join(@nominal, ", ", &"'#{&1}'") <> ")"

  @doc """
  Runs every rung, then the corroboration pass. Returns counts per step.

  Idempotent: identity is `(source_id, origin_key)`, so a second run revises the
  claims it made last time rather than duplicating them — and writes no revision
  at all where nothing changed.
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
    write(
      """
      SELECT s.object_id, e.object_id, s.source_id,
             'wiktionary_qid', #{@confidence.wiktionary_qid}, '{}'::jsonb
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wiktionary'
        JOIN sense_revisions rev ON rev.sense_id = s.object_id AND rev.is_current
        CROSS JOIN LATERAL jsonb_array_elements_text(#{jsonb_array("rev.metadata->'wikidata'")}) AS q(qid)
        JOIN external_identifiers x
          ON x.namespace = 'wikidata' AND x.external_id = q.qid AND x.status = 'verified'
        JOIN entities e ON e.object_id = x.object_id
       #{scope_join(scope, "s.lexeme_id")}
       WHERE jsonb_typeof(rev.metadata->'wikidata') = 'array'
      """,
      @sense_backed,
      scope
    )
  end

  # ── rung 2 · wordnet_wikidata ────────────────────────────────────────────

  # A synset usually carries one QID as a string, but 1,887 of them carry an
  # array (`panther` → `["Q35255", "Q109647288"]`). Reading only the string
  # shape skipped 265 references in the Animals scope, so those senses never
  # got a link however good the entity was.
  @doc false
  def wordnet_wikidata(scope) do
    write(
      """
      SELECT s.object_id, e.object_id, s.source_id,
             'wordnet_wikidata', #{@confidence.wordnet_wikidata}, '{}'::jsonb
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wordnet'
        JOIN sense_revisions rev ON rev.sense_id = s.object_id AND rev.is_current
        CROSS JOIN LATERAL jsonb_array_elements_text(#{jsonb_qids("rev.metadata->'wikidata'")}) AS q(qid)
        JOIN external_identifiers x
          ON x.namespace = 'wikidata' AND x.external_id = q.qid AND x.status = 'verified'
        JOIN entities e ON e.object_id = x.object_id
       #{scope_join(scope, "s.lexeme_id")}
       WHERE jsonb_typeof(rev.metadata->'wikidata') IN ('string', 'array')
      """,
      @sense_backed,
      scope
    )
  end

  # ── rung 3 · wordnet_ili ─────────────────────────────────────────────────

  @doc false
  def wordnet_ili(scope) do
    write(
      """
      SELECT s.object_id, e.object_id, s.source_id,
             'wordnet_ili', #{@confidence.wordnet_ili}, '{}'::jsonb
        FROM senses s
        JOIN sources so ON so.id = s.source_id AND so.slug = 'wordnet'
        JOIN sense_revisions rev ON rev.sense_id = s.object_id AND rev.is_current
        JOIN entities e ON e.metadata->>'wordnet_ili' = rev.metadata->>'ili'
       #{scope_join(scope, "s.lexeme_id")}
       WHERE rev.metadata->>'ili' IS NOT NULL
      """,
      @sense_backed,
      scope
    )
  end

  # ── rung 4 · title_match ─────────────────────────────────────────────────

  # A spelling matched against an article title. `lexeme_entity_candidate`, not
  # `refers_to`: nobody asserted that this *meaning* names that thing, and
  # #74 §C is explicit that a title match is not sense equivalence.
  #
  # Nominal parts of speech only, and never a disambiguation page — "Seal may
  # refer to…" is not a thing the word denotes.
  @doc false
  def title_match(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, #{source_id("wikipedia")},
             'title_match', #{@confidence.title_match}, '{}'::jsonb
        FROM lexemes l
        JOIN entities e ON e.metadata->>'wikipedia_title' = l.metadata->>'wikipedia_title'
       #{scope_join(scope, "l.object_id")}
       WHERE l.part_of_speech IN #{nominal()}
         AND NOT jsonb_exists(e.metadata, 'disambiguation')
         AND NOT jsonb_exists(l.metadata, 'wikipedia_disambiguation')
      """,
      @word_level,
      scope
    )
  end

  # ── rung 5 · disambiguation ──────────────────────────────────────────────

  # Candidates come out of the record the Wikipedia pass already stored, so the
  # "may refer to" panel and this rung cost no extra fetch. They sit below the
  # asserted floor deliberately: these are possibilities, not conclusions, and
  # `Encyclopedia.asserted_floor/0` is what keeps them out of the populations
  # A10 and L3 report on.
  @doc false
  def disambiguation(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, r.source_id,
             'disambiguation', #{@confidence.disambiguation},
             jsonb_build_object('disambiguation_page', payload.raw->>'title')
        FROM source_records r
        JOIN sources so ON so.id = r.source_id AND so.slug = 'wikipedia'
        JOIN LATERAL (
          SELECT rev.payload AS raw FROM source_record_revisions rev
           WHERE rev.source_record_id = r.id AND rev.revision_key = r.content_hash
           LIMIT 1
        ) payload ON TRUE
        CROSS JOIN LATERAL jsonb_array_elements(#{jsonb_array("payload.raw->'_candidates'")}) AS cand
        JOIN external_identifiers x
          ON x.namespace = 'wikidata' AND x.external_id = cand->>'qid' AND x.status = 'verified'
        JOIN entities e ON e.object_id = x.object_id
        CROSS JOIN LATERAL jsonb_array_elements(#{jsonb_array("payload.raw->'_probe'->'lexemes'")}) AS key
        JOIN lexemes l ON l.language_tag = key->>0 AND l.lemma = key->>1
                      AND l.part_of_speech = key->>2
       #{scope_join(scope, "l.object_id")}
       WHERE jsonb_typeof(payload.raw->'_candidates') = 'array'
         AND l.part_of_speech IN #{nominal()}
      """,
      @word_level,
      scope
    )
  end

  # ── corroboration ────────────────────────────────────────────────────────

  @doc """
  Raises `title_match` confidence where a second signal agrees, and promotes a
  disambiguation candidate whose description matches a gloss.

  Runs last and in this order: agreement is the strongest evidence, so it is
  applied after the weaker two and overwrites them.

  Each of these re-emits the claim its rung already made, at a higher confidence
  and with `metadata["corroboration"]` naming the signal. That is a revision,
  written through the same path — which is why a rerun that finds nothing new
  writes nothing at all rather than bumping `updated_at` on a million rows.
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
  # — either on the entity itself, or on the taxon item it bridges to.
  defp corroborate_taxon(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, #{source_id("wikipedia")},
             'title_match', #{@corroborated_taxon},
             '{"corroboration": "taxon_name"}'::jsonb
        FROM assertion_revisions r
        JOIN predicates p ON p.id = r.predicate_id AND p.key = '#{@word_level}'
        JOIN lexemes l ON l.object_id = r.subject_object_id
        JOIN entities e ON e.object_id = r.object_object_id
       #{scope_join(scope, "l.object_id")}
       WHERE r.is_current AND r.lifecycle_state = 'active'
         AND r.method = 'title_match'
         AND r.confidence < #{@corroborated_taxon}
         -- The parentheses matter: `OR` binds looser than `AND`, so without them
         -- the first disjunct alone satisfies the EXISTS and every title match
         -- reads as corroborated by a taxon name.
         AND EXISTS (
           SELECT 1 FROM entities t
            WHERE (
                t.object_id = e.object_id
                OR t.object_id = (
                     SELECT tr.object_object_id FROM assertion_revisions tr
                       JOIN predicates tp ON tp.id = tr.predicate_id AND tp.key = 'taxon_item'
                      WHERE tr.subject_object_id = e.object_id AND tr.is_current
                      LIMIT 1)
              )
              AND (
                lower(t.metadata->'taxon'->>'scientific_name') = lower(l.lemma)
                OR EXISTS (
                  SELECT 1
                    FROM jsonb_array_elements_text(
                           #{jsonb_array("t.metadata->'taxon'->'common_names'")}) AS n
                   WHERE lower(n) = lower(l.lemma))
              ))
      """,
      @word_level,
      scope
    )
  end

  # The article and a dictionary agree about what the word means. Approximated
  # by shared content words rather than by a stopword list: four letters or more
  # is a good enough proxy, and two of them agreeing is not chance.
  defp corroborate_gloss(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, #{source_id("wikipedia")},
             'title_match', #{@corroborated_gloss},
             '{"corroboration": "gloss_overlap"}'::jsonb
        FROM assertion_revisions r
        JOIN predicates p ON p.id = r.predicate_id AND p.key = '#{@word_level}'
        JOIN lexemes l ON l.object_id = r.subject_object_id
        JOIN entities e ON e.object_id = r.object_object_id
        JOIN assertion_revisions ar ON ar.object_object_id = e.object_id AND ar.is_current
        JOIN predicates ap ON ap.id = ar.predicate_id AND ap.key = 'about'
        JOIN content_revisions cr
          ON cr.content_id = ar.subject_object_id AND cr.is_current
       #{scope_join(scope, "l.object_id")}
       WHERE r.is_current AND r.lifecycle_state = 'active'
         AND r.method = 'title_match'
         AND r.confidence < #{@corroborated_gloss}
         AND EXISTS (
           SELECT 1 FROM senses s
             JOIN sense_revisions srev ON srev.sense_id = s.object_id AND srev.is_current
            WHERE s.lexeme_id = l.object_id
              AND srev.gloss IS NOT NULL
              AND #{shared_words("srev.gloss", "coalesce(cr.body, '') || ' ' || coalesce(e.description, '')")}
                >= #{@min_shared_words})
      """,
      @word_level,
      scope
    )
  end

  # Two independent methods naming the same thing. In MVP-0 this also wrote
  # `status = 'confirmed'`, which is an editorial decision nobody made; #74 asks
  # for that policy not to be preserved blindly. So agreement raises confidence
  # and records its provenance, and a review stays something a person does.
  defp corroborate_agreement(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, #{source_id("wikipedia")},
             'title_match', #{@corroborated_agreement},
             '{"corroboration": "qid_agreement"}'::jsonb
        FROM assertion_revisions r
        JOIN predicates p ON p.id = r.predicate_id AND p.key = '#{@word_level}'
        JOIN lexemes l ON l.object_id = r.subject_object_id
        JOIN entities e ON e.object_id = r.object_object_id
       #{scope_join(scope, "l.object_id")}
       WHERE r.is_current AND r.lifecycle_state = 'active'
         AND r.method = 'title_match'
         AND EXISTS (
           SELECT 1 FROM assertion_revisions other
             JOIN predicates op ON op.id = other.predicate_id AND op.key = '#{@sense_backed}'
             JOIN senses os ON os.object_id = other.subject_object_id
            WHERE os.lexeme_id = l.object_id
              AND other.object_object_id = e.object_id
              AND other.is_current
              AND other.method IN ('wiktionary_qid', 'wordnet_wikidata', 'wordnet_ili'))
      """,
      @word_level,
      scope
    )
  end

  # #69 §5: a candidate rises from 0.40 to 0.60 when a Wiktionary sense gloss
  # matches the candidate's description. It stays below the asserted floor — the
  # "may refer to" panel is a list of possibilities, and promotion only reorders
  # it.
  defp promote_candidates(scope) do
    write(
      """
      SELECT l.object_id, e.object_id, #{source_id("wikipedia")},
             'disambiguation', #{@disambiguation_gloss},
             '{"corroboration": "candidate_gloss"}'::jsonb
        FROM assertion_revisions r
        JOIN predicates p ON p.id = r.predicate_id AND p.key = '#{@word_level}'
        JOIN lexemes l ON l.object_id = r.subject_object_id
        JOIN entities e ON e.object_id = r.object_object_id
       #{scope_join(scope, "l.object_id")}
       WHERE r.is_current AND r.lifecycle_state = 'active'
         AND r.method = 'disambiguation'
         AND r.confidence < #{@disambiguation_gloss}
         AND e.description IS NOT NULL
         AND EXISTS (
           SELECT 1 FROM senses s
             JOIN sources so ON so.id = s.source_id AND so.slug = 'wiktionary'
             JOIN sense_revisions srev ON srev.sense_id = s.object_id AND srev.is_current
            WHERE s.lexeme_id = l.object_id
              AND srev.gloss IS NOT NULL
              AND #{shared_words("srev.gloss", "e.description")} >= #{@min_shared_words})
      """,
      @word_level,
      scope
    )
  end

  # ── SQL helpers ──────────────────────────────────────────────────────────

  # `jsonb_array_elements` raises on a scalar, and Postgres is free to evaluate a
  # LATERAL before the WHERE clause that would have filtered the row out. So the
  # guard goes *inside* the call, never beside it: a sense revision's
  # `metadata->'wikidata'` is an array from Wiktionary and a bare string from
  # WordNet, in one table.
  defp jsonb_array(expression) do
    "CASE WHEN jsonb_typeof(#{expression}) = 'array' THEN #{expression} ELSE '[]'::jsonb END"
  end

  # Same guard, one shape wider: a bare string is wrapped into a one-element
  # array rather than discarded, so a column that holds both shapes (WordNet's
  # `wikidata`) can be read by a single rung.
  defp jsonb_qids(expression) do
    """
    CASE jsonb_typeof(#{expression})
      WHEN 'array' THEN #{expression}
      WHEN 'string' THEN jsonb_build_array(#{expression})
      ELSE '[]'::jsonb
    END\
    """
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

  # A word-level rung infers rather than reads, so nobody *asserted* it — but
  # the evidence is Wikipedia's article title, and an assertion with a null
  # `source_id` would fall out of the `(source_id, origin_key)` unique index
  # (NULLs are distinct) and duplicate on every run. Naming the source of the
  # evidence is both true and enforceable; `method` is what records that we
  # inferred it.
  defp source_id(slug) do
    case Sources.get_source_by_slug(slug) do
      nil -> "NULL::bigint"
      source -> "#{source.id}::bigint"
    end
  end

  defp scope_join(nil, _column), do: ""

  defp scope_join(%Scope{}, column),
    do: "JOIN scope_lexeme_members sl ON sl.lexeme_id = #{column} AND sl.scope_id = $1"

  defp params(nil), do: []
  defp params(%Scope{id: id}), do: [id]

  # Every rung ends the same way: read set-based, write through the shared path.
  #
  # The `SELECT` yields `(subject_id, entity_id, source_id, method, confidence,
  # metadata)`. Deduplication happens here rather than in SQL because a rung can
  # propose the same claim twice — a Wiktionary sense listing one QID twice, two
  # candidate titles redirecting to one article — and `write_assertions/3` keys
  # on `origin_key`, which is what makes the second proposal the same claim.
  defp write(select, predicate, scope) do
    %{rows: rows} = Repo.query!(select, params(scope), timeout: :infinity)

    claims =
      for [subject, object, source, method, confidence, metadata] <- rows do
        %{
          subject: subject,
          predicate: predicate,
          object: object,
          source_id: source,
          origin_key: "link|#{method}|#{subject}|#{object}",
          method: method,
          # A bare `0.70` in SQL is `numeric`, and Postgrex hands numerics back
          # as `Decimal`. `assertion_revisions.confidence` is a float8, so it is
          # cast here rather than by decorating every literal in five rungs.
          confidence: to_float(confidence),
          metadata: metadata || %{}
        }
      end
      |> Enum.uniq_by(& &1.origin_key)
      |> filter_claims()

    claims
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(0, fn chunk, acc -> acc + Materializer.write_assertions(chunk) end)
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  # Two reasons a rung's proposal is not written.
  #
  # **A curator rejected it.** In MVP-0 `status` was a column and every rung's
  # `ON CONFLICT DO UPDATE` overwrote it, so a rejected link returned to `auto`
  # the next time the rung ran — the audit reproduced exactly that. Reviews are
  # append-only rows now, and this is where the importer is made to respect
  # them.
  #
  # **Corroboration already outranks it.** A base rung writes `title_match` at
  # 0.70 and `corroborate/1` then raises it to 0.90; on the next run the rung
  # proposes 0.70 again. In MVP-0 that flip-flop was an in-place UPDATE and left
  # no trace, so nobody saw it. Here it would write two revisions per run for
  # ever, and the history would record a claim oscillating between two
  # confidences it never actually changed between. A stored revision carrying a
  # `corroboration` at or above the proposal is the better answer, and the rung
  # defers to it.
  defp filter_claims([]), do: []

  defp filter_claims(claims) do
    keys = Enum.map(claims, & &1.origin_key)

    standing =
      Repo.query!(
        """
        SELECT a.origin_key,
               COALESCE(
                 (SELECT rv.decision FROM assertion_reviews rv
                   WHERE rv.assertion_revision_id = ar.id
                   ORDER BY rv.inserted_at DESC, rv.id DESC LIMIT 1),
                 'needs_review'
               ),
               ar.confidence,
               jsonb_exists(ar.metadata, 'corroboration')
          FROM assertions a
          JOIN assertion_revisions ar ON ar.assertion_id = a.id AND ar.is_current
         WHERE a.origin_key = ANY($1)
        """,
        [keys]
      )
      |> Map.fetch!(:rows)
      |> Map.new(fn [key, decision, confidence, corroborated] ->
        {key, {decision, to_float(confidence), corroborated}}
      end)

    Enum.reject(claims, fn claim ->
      case standing[claim.origin_key] do
        nil -> false
        {decision, _confidence, _} when decision in ["rejected", "withdrawn"] -> true
        {_, held, true} -> held >= (claim.confidence || 0.0)
        _ -> false
      end
    end)
  end

  @doc """
  The link population `Encyclopedia` reads, for tests and the health page.

  Exposed so a caller never has to spell the rule again — see
  `Encyclopedia.linked_lexemes_query/1`.
  """
  defdelegate links(opts \\ []), to: Encyclopedia, as: :linked_lexemes_query
end
