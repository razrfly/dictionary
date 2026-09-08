-- RUN 4: the other half of proof 5 -- "…or flags ambiguity; it never silently
-- reassigns them."
--
-- A confident match is easy. The case that matters is the one where the source
-- has edited a gloss enough that two existing senses are plausible. `bank` has
-- two that are genuinely close:
--
--   20000003  "A fund from deposits or contributions, to be used in
--              transacting business; a joint stock or capital."
--   20000004  "The sum of money etc. which the dealer or banker has as a fund
--              from which to draw stakes and pay losses."
--
-- An incoming gloss that sits between them must NOT be assigned to whichever
-- scores a hair higher. It becomes a reconciliation case, the sense goes to
-- needs_review, and a person decides.

TRUNCATE incoming_senses;

INSERT INTO incoming_senses (source_slug, lexeme_id, src_position, pos, etymology, gloss, external_key) VALUES
  ('wiktionary', 3125, 0, 'noun', 1, 'A fund of money from which the banker draws to transact business.', 'bank/noun/1#0');

\echo ''
\echo '════ RUN 4: an edited gloss that sits between two existing senses ══════'
SELECT r.src_position AS pos, r.decision,
       r.matched_sense,
       round(r.score::numeric, 3)     AS best,
       round(r.runner_up::numeric, 3) AS runner_up,
       round((r.score - r.runner_up)::numeric, 3) AS gap
  FROM reconcile('wiktionary', 3125) r ORDER BY r.src_position;
\echo '   ^ decision must be "ambiguous". Note WHICH rule fired: the best score'
\echo '     0.430 is above weak (0.30) but below strong (0.60), so no candidate'
\echo '     is good enough to claim the identity. The band rule is exercised'
\echo '     separately below -- there are two ways into "ambiguous" and both'
\echo '     have to work.'

\echo ''
\echo '── what an ambiguous decision does ────────────────────────────────────'
BEGIN;
INSERT INTO reconciliation_cases (source_slug, kind, lexeme_id, sense_id, payload)
SELECT 'wiktionary', 'ambiguous_sense_identity', 3125, r.matched_sense,
       jsonb_build_object(
         'incoming_gloss', i.gloss,
         'best_score', r.score, 'runner_up_score', r.runner_up,
         'candidates', (SELECT jsonb_agg(jsonb_build_object('sense_id', s.object_id, 'gloss', sr.gloss))
                          FROM senses s JOIN sense_revisions sr ON sr.id = s.current_revision_id
                         WHERE s.object_id IN (20000003, 20000004)))
  FROM reconcile('wiktionary', 3125) r JOIN incoming_senses i ON i.src_position = r.src_position
 WHERE r.decision = 'ambiguous';

UPDATE senses SET identity_state = 'needs_review'
 WHERE object_id IN (SELECT sense_id FROM reconciliation_cases WHERE status = 'open' AND sense_id IS NOT NULL);
COMMIT;

SELECT id, kind, sense_id, status, payload->>'best_score' AS best, payload->>'runner_up_score' AS runner_up
  FROM reconciliation_cases;
SELECT object_id, identity_state FROM senses WHERE identity_state <> 'active' AND object_id >= 20000000;
\echo '   ^ a case is open and the sense is needs_review. No revision was written,'
\echo '     no attachment moved, and no identity was reused for a new meaning.'

\echo ''
\echo '════ RUN 5: the band rule -- two candidates too close to choose ════════'
-- The first case was ambiguous because nothing scored well enough. This is the
-- other one: something scores very well against TWO senses, and picking the
-- higher would be arbitrary. A source that splits one meaning into two nearly
-- identical ones produces exactly this, so it is not a contrived shape --
-- though these two rows are inserted deliberately to make it reproducible.
BEGIN;
INSERT INTO objects (id, kind) VALUES (20000100, 'sense'), (20000101, 'sense');
INSERT INTO senses (object_id, lexeme_id, source_slug, external_key) VALUES
  (20000100, 3125, 'wiktionary', 'bank/noun/9#0'),
  (20000101, 3125, 'wiktionary', 'bank/noun/9#1');
INSERT INTO sense_revisions (sense_id, revision_number, gloss, position) VALUES
  (20000100, 1, 'A raised area of seabed or riverbed; a shoal.', 0),
  (20000101, 1, 'A raised area of seabed or riverbed; a shelf.', 1);
UPDATE senses s SET current_revision_id = r.id FROM sense_revisions r
 WHERE r.sense_id = s.object_id AND s.object_id IN (20000100, 20000101);
COMMIT;

TRUNCATE incoming_senses;
INSERT INTO incoming_senses (source_slug, lexeme_id, src_position, pos, etymology, gloss, external_key) VALUES
  ('wiktionary', 3125, 0, 'noun', 9, 'A raised area of seabed or riverbed; a shoal or shelf.', 'bank/noun/9#0');

SELECT r.src_position AS pos, r.decision, r.matched_sense,
       round(r.score::numeric, 3) AS best,
       round(r.runner_up::numeric, 3) AS runner_up,
       round((r.score - r.runner_up)::numeric, 3) AS gap
  FROM reconcile('wiktionary', 3125) r ORDER BY r.src_position;
\echo '   ^ best is above strong (0.60) but the gap is inside the 0.08 band,'
\echo '     so it is ambiguous rather than assigned to whichever sorted first.'
