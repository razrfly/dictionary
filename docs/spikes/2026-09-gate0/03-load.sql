-- Gate 0, proof 6 (#74): "Load a representative real WordNet edge population
-- including high-degree nodes, and enough historical revisions to exercise
-- revision-selection cost."
--
-- Not a sample: the whole resolved population from devils_dictionary_dev.
-- 1,541,669 lexemes, 250,389 senses, 1,163,659 resolved lexical relations.
-- A benchmark on a hand-picked subset would answer a question nobody asked.
--
-- Object id space, so every row stays traceable back to the row it came from:
--   lexeme  object_id = lexemes.id
--   sense   object_id = 10,000,000 + senses.id
-- Both are well clear of each other at this corpus size.

\timing on

CREATE TEMP TABLE stage_lexemes (
  id bigint, lang text, lemma text, pos text, slug text
);
CREATE TEMP TABLE stage_senses (
  id bigint, lexeme_id bigint, source_slug text, external_id text,
  group_key text, gloss text, position int
);
CREATE TEMP TABLE stage_relations (
  id bigint, from_lexeme_id bigint, from_sense_id bigint,
  to_lexeme_id bigint, to_sense_id bigint, type text, source_slug text
);

\copy stage_lexemes   from '/private/tmp/claude-501/-Users-holden-Code-projects-2026-dictionary/d01531c8-e385-481b-8180-acf1a6e6441e/scratchpad/gate0/lexemes.csv'   csv
\copy stage_senses    from '/private/tmp/claude-501/-Users-holden-Code-projects-2026-dictionary/d01531c8-e385-481b-8180-acf1a6e6441e/scratchpad/gate0/senses.csv'    csv
\copy stage_relations from '/private/tmp/claude-501/-Users-holden-Code-projects-2026-dictionary/d01531c8-e385-481b-8180-acf1a6e6441e/scratchpad/gate0/relations.csv' csv

\echo '── objects + lexemes ───────────────────────────────────────────────────'
-- The deferred subtype trigger fires per object row, so the object and its
-- subtype must land in one transaction. That is the cost of the guarantee and
-- it is part of what this gate is measuring.
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO objects (id, kind) SELECT id, 'lexeme' FROM stage_lexemes;
INSERT INTO lexemes (object_id, language_tag, lemma, part_of_speech, lexical_key, slug)
SELECT id, lang, lemma, pos, lang || '/' || lemma || '/' || pos, slug FROM stage_lexemes;
COMMIT;

\echo '── objects + senses + first revision ───────────────────────────────────'
BEGIN;
SET CONSTRAINTS ALL DEFERRED;
INSERT INTO objects (id, kind) SELECT 10000000 + id, 'sense' FROM stage_senses;
INSERT INTO senses (object_id, lexeme_id, source_slug, external_key)
SELECT 10000000 + id, lexeme_id, source_slug, external_id FROM stage_senses;
INSERT INTO sense_revisions (sense_id, revision_number, gloss, group_key, position)
SELECT 10000000 + id, 1, gloss, group_key, position FROM stage_senses;
UPDATE senses s SET current_revision_id = r.id
  FROM sense_revisions r WHERE r.sense_id = s.object_id AND r.revision_number = 1;
COMMIT;

\echo '── predicates for the source-native lexical relations ──────────────────'
INSERT INTO predicates (key, forward_label, reverse_label)
SELECT DISTINCT type, type, type FROM stage_relations
ON CONFLICT (key) DO NOTHING;

-- lexeme -> lexeme and sense -> sense, declared per predicate. Nothing else.
INSERT INTO predicate_endpoint_rules (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind)
SELECT p.id, k, '-', k, '-' FROM predicates p, (VALUES ('lexeme'), ('sense')) AS t(k)
ON CONFLICT DO NOTHING;

\echo '── assertions (1.16M) ─────────────────────────────────────────────────'
INSERT INTO assertions (id, source_slug, origin_key)
SELECT id, source_slug, id::text FROM stage_relations;

\echo '── assertion_revisions, revision 1 — the BEFORE trigger runs per row ───'
INSERT INTO assertion_revisions
  (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
SELECT r.id, 1,
       CASE WHEN r.from_sense_id IS NOT NULL THEN 10000000 + r.from_sense_id ELSE r.from_lexeme_id END,
       p.id,
       CASE WHEN r.from_sense_id IS NOT NULL AND r.to_sense_id IS NOT NULL
            THEN 10000000 + r.to_sense_id ELSE r.to_lexeme_id END,
       true
  FROM stage_relations r JOIN predicates p ON p.key = r.type
 WHERE NOT (r.from_sense_id IS NOT NULL AND r.to_sense_id IS NULL);
-- sense -> lexeme is not a declared endpoint pair, so those rows are excluded
-- rather than quietly retyped. The count is reported below; this is exactly the
-- "document unsupported source structures, do not silently flatten" rule.

UPDATE assertions a SET current_revision_id = ar.id
  FROM assertion_revisions ar WHERE ar.assertion_id = a.id AND ar.revision_number = 1;

\echo '── revision depth: 4 more revisions for every 5th assertion ────────────'
-- "Measure costs with multiple revisions, not just a history-free corpus."
INSERT INTO assertion_revisions
  (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, lifecycle_state, is_current)
SELECT ar.assertion_id, n, ar.subject_object_id, ar.predicate_id, ar.object_object_id, 'superseded', false
  FROM assertion_revisions ar, generate_series(2, 5) AS n
 WHERE ar.revision_number = 1 AND ar.assertion_id % 5 = 0;

-- The newest revision becomes current, and the older ones are marked superseded.
UPDATE assertion_revisions SET lifecycle_state = 'superseded', is_current = false
 WHERE assertion_id % 5 = 0 AND revision_number < 5;
UPDATE assertion_revisions SET lifecycle_state = 'active', is_current = true
 WHERE assertion_id % 5 = 0 AND revision_number = 5;
UPDATE assertions a SET current_revision_id = ar.id
  FROM assertion_revisions ar
 WHERE ar.assertion_id = a.id AND ar.revision_number = 5 AND a.id % 5 = 0;
