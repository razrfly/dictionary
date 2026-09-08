-- RUN 3: the audit's reproduction, on the real record.
--
-- Wiktionary is edited: one sense is DELETED from the middle ("A branch office
-- of such an institution.", position 1), one is REWORDED, and one genuinely
-- NEW sense is appended. Every position after the deletion shifts down by one:
--
--   "Money; profit."  was position 5, is now position 4
--   position 5 now holds "In certain games, such as dominos, …"
--
-- Under the shipped `word/pos/etym#position` key the row for #5 is overwritten
-- with the dominos gloss, and the curator's attachment -- still a perfectly
-- valid foreign key -- now means something else. That is the defect, and it is
-- what this run must not reproduce.

TRUNCATE incoming_senses;

INSERT INTO incoming_senses (source_slug, lexeme_id, src_position, pos, etymology, gloss, external_key) VALUES
  ('wiktionary', 3125, 0, 'noun', 1, 'An institution where one can place and borrow money and take care of financial affairs.', 'bank/noun/1#0'),
  -- position 1, "A branch office of such an institution.", is DELETED
  ('wiktionary', 3125, 1, 'noun', 1, 'An underwriter or controller of a card game.', 'bank/noun/1#1'),
  ('wiktionary', 3125, 2, 'noun', 1, 'A fund from deposits or contributions, to be used in transacting business; a joint stock or capital.', 'bank/noun/1#2'),
  ('wiktionary', 3125, 3, 'noun', 1, 'The sum of money etc. which the dealer or banker has as a fund from which to draw stakes and pay losses.', 'bank/noun/1#3'),
  ('wiktionary', 3125, 4, 'noun', 1, 'Money; profit.', 'bank/noun/1#4'),                        -- WAS position 5
  ('wiktionary', 3125, 5, 'noun', 1, 'In certain games, such as dominos, a fund of pieces from which the players draw.', 'bank/noun/1#5'),
  ('wiktionary', 3125, 6, 'noun', 1, 'A safe and guaranteed place of storage for and retrieval of important items or goods.', 'bank/noun/1#6'),
  ('wiktionary', 3125, 7, 'noun', 1, 'A device used to store coins or currency, such as a piggy bank.', 'bank/noun/1#7'),  -- REWORDED
  ('wiktionary', 3125, 8, 'noun', 1, 'A collection of instrument data on a digital synthesizer.', 'bank/noun/1#8'),
  ('wiktionary', 3125, 9, 'noun', 1, 'A blood bank or organ bank; a store of donated biological material.', 'bank/noun/1#9');  -- NEW

\echo ''
\echo '════ RUN 3: one deleted, one reworded, one added ══════════════════════'
SELECT r.src_position AS pos,
       left(i.gloss, 38) AS incoming,
       r.decision,
       r.matched_sense,
       round(r.score::numeric, 3) AS score,
       left((SELECT sr.gloss FROM senses s JOIN sense_revisions sr ON sr.id = s.current_revision_id
              WHERE s.object_id = r.matched_sense), 32) AS matched_to
  FROM reconcile('wiktionary', 3125) r
  JOIN incoming_senses i ON i.src_position = r.src_position
 ORDER BY r.src_position;

\echo ''
\echo '── the question that matters ──────────────────────────────────────────'
SELECT 'incoming position 4 ("Money; profit.") resolves to sense '
       || (SELECT matched_sense FROM reconcile('wiktionary', 3125) WHERE src_position = 4)
       || ' -- the same identity it had at position 5.' AS verdict;

SELECT 'incoming position 5 ("In certain games…") resolves to sense '
       || (SELECT matched_sense FROM reconcile('wiktionary', 3125) WHERE src_position = 5)
       || ' -- NOT the one that used to be at position 5.' AS verdict;

SELECT 'the curator attachment still points at ' || ar.subject_object_id || ' = "' ||
       (SELECT sr.gloss FROM senses s JOIN sense_revisions sr ON sr.id = s.current_revision_id
         WHERE s.object_id = ar.subject_object_id) || '"' AS attachment
  FROM assertion_revisions ar WHERE ar.id = 88000001;

\echo ''
\echo '── the sense the source removed is retired, not deleted ────────────────'
SELECT s.object_id, s.external_key, left(sr.gloss, 44) AS gloss
  FROM senses s JOIN sense_revisions sr ON sr.id = s.current_revision_id
 WHERE s.object_id >= 20000000
   AND s.object_id NOT IN (SELECT matched_sense FROM reconcile('wiktionary', 3125) WHERE matched_sense IS NOT NULL)
 ORDER BY s.object_id;
\echo '   ^ expected: exactly one row, "A branch office of such an institution."'
