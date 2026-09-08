-- Gate 0, proofs 4 and 5, on the real Wiktionary `bank/noun/1` record:
-- 10 senses, the exact shape that breaks today. Lexeme 3125 is `bank` (noun).
--
-- Run 1  absorb as published            -> 10 new identities
-- Run 2  the identical record again     -> 0 new identities, 0 new revisions
-- Run 3  a sense DELETED from the middle, which renumbers every position after
--        it -- the audit's reproduction -- plus one INSERTED at the front and
--        one REWORDED.
--
-- The thing to watch is sense id for "Money; profit." It is at position 5 in
-- run 1 and at position 4 in run 3. Under the old `word/pos/etym#position` key
-- it would keep id `bank/noun/1#5`, which now holds a different meaning.
\pset footer off

\echo ''
\echo '════ RUN 1: first absorb ══════════════════════════════════════════════'
-- One transaction, because the deferred subtype trigger checks at COMMIT and
-- each bare statement in psql is its own transaction. This is the shape every
-- writer has to take, and it is why the materializer's Ecto.Multi stays.
BEGIN;
INSERT INTO objects (id, kind)
SELECT 20000000 + src_position, 'sense' FROM incoming_senses WHERE source_slug='wiktionary';
INSERT INTO senses (object_id, lexeme_id, source_slug, external_key)
SELECT 20000000 + src_position, lexeme_id, 'wiktionary', external_key FROM incoming_senses WHERE source_slug='wiktionary';
INSERT INTO sense_revisions (sense_id, revision_number, gloss, position)
SELECT 20000000 + src_position, 1, gloss, src_position FROM incoming_senses WHERE source_slug='wiktionary';
UPDATE senses s SET current_revision_id = r.id FROM sense_revisions r
 WHERE r.sense_id = s.object_id AND s.object_id >= 20000000;
COMMIT;

SELECT s.object_id, s.external_key, left(r.gloss, 44) AS gloss
  FROM senses s JOIN sense_revisions r ON r.id = s.current_revision_id
 WHERE s.object_id >= 20000000 ORDER BY s.object_id;

\echo ''
\echo '── an attachment is made to "Money; profit." (object 20000005) ─────────'
BEGIN;
INSERT INTO objects (id, kind) VALUES (30000001, 'entity');
INSERT INTO entities (object_id, entity_kind, preferred_label) VALUES (30000001, 'concept', 'profit');
INSERT INTO predicates (id, key, forward_label, reverse_label) VALUES (99001, 'refers_to', 'refers to', 'Words referring to this');
INSERT INTO predicate_endpoint_rules VALUES (99001, 'sense', '-', 'entity', 'concept');
INSERT INTO assertions (id, source_slug, origin_key) VALUES (88000001, 'curator', 'bank-money-profit');
INSERT INTO assertion_revisions (id, assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
  VALUES (88000001, 88000001, 1, 20000005, 99001, 30000001, true);
UPDATE assertions SET current_revision_id = 88000001 WHERE id = 88000001;
COMMIT;
SELECT 'attachment points at sense ' || subject_object_id || ' = ' ||
       (SELECT left(r.gloss,30) FROM senses s JOIN sense_revisions r ON r.id=s.current_revision_id WHERE s.object_id = ar.subject_object_id) AS attached
  FROM assertion_revisions ar WHERE ar.id = 88000001;

\echo ''
\echo '════ RUN 2: byte-identical input ══════════════════════════════════════'
SELECT src_position, decision, matched_sense, round(score::numeric,3) AS score
  FROM reconcile('wiktionary', 3125) ORDER BY src_position;
\echo '   ^ expected: every row "matched", to the sense it already was'
