-- Gate 0, proofs 2 and 3 (#74): "Demonstrate deferred rejection of an object
-- without its matching subtype and rejection of invalid predicate endpoints."
--
-- Every block below MUST fail. The harness records the SQLSTATE and message;
-- a block that succeeds is a failed gate. Each runs in its own transaction so
-- one abort does not mask the next.

\set ON_ERROR_STOP off
\echo '── seed ────────────────────────────────────────────────────────────────'

BEGIN;
  -- Bierce the person
  INSERT INTO objects (id, kind) VALUES (101, 'entity');
  INSERT INTO entities (object_id, entity_kind, preferred_label)
    VALUES (101, 'person', 'Ambrose Bierce');
  INSERT INTO person_details (entity_id, birth_date, death_date)
    VALUES (101, '1842-06-24', '1914-01-01');

  -- nepotism the word
  INSERT INTO objects (id, kind) VALUES (104, 'lexeme');
  INSERT INTO lexemes (object_id, lemma, part_of_speech, lexical_key, slug)
    VALUES (104, 'nepotism', 'noun', 'en/nepotism/noun', 'nepotism');

  -- his definition of it
  INSERT INTO objects (id, kind) VALUES (105, 'content');
  INSERT INTO content_items (object_id, content_kind) VALUES (105, 'definition');

  -- nepotism the practice
  INSERT INTO objects (id, kind) VALUES (107, 'entity');
  INSERT INTO entities (object_id, entity_kind, preferred_label)
    VALUES (107, 'concept', 'nepotism');

  INSERT INTO predicates (id, key, forward_label, reverse_label) VALUES
    (1, 'defines',     'defines',     'Definitions'),
    (2, 'authored_by', 'authored by', 'Definitions authored'),
    (3, 'refers_to',   'refers to',   'Words referring to this');

  INSERT INTO predicate_endpoint_rules
    (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind) VALUES
    (1, 'content', 'definition', 'lexeme', '-'),      -- a definition defines a word
    (1, 'content', 'definition', 'sense',  '-'),      -- …or a source meaning
    (2, 'content', 'definition', 'entity', 'person'), -- authored by a person
    (3, 'sense',   '-',          'entity', 'concept');
COMMIT;

\echo ''
\echo '── PROOF 2: an object with no subtype is rejected AT COMMIT ─────────────'
\echo '   (it must be legal mid-transaction: the object row has to exist first)'
BEGIN;
  INSERT INTO objects (id, kind) VALUES (900, 'lexeme');
  SELECT 'mid-transaction: still legal, as designed' AS note;
COMMIT;
\echo '   ^ expected: ERROR object 900 (kind lexeme) has no lexeme row'

\echo ''
\echo '── PROOF 2b: a subtype of the WRONG kind is rejected immediately ────────'
BEGIN;
  INSERT INTO objects (id, kind) VALUES (901, 'entity');
  INSERT INTO lexemes (object_id, lemma, part_of_speech, lexical_key, slug)
    VALUES (901, 'wrong', 'noun', 'en/wrong/noun', 'wrong');
COMMIT;
\echo '   ^ expected: ERROR insert violates foreign key lexemes_object_id_kind_fkey'

\echo ''
\echo '── PROOF 2c: two subtypes for one object is rejected ────────────────────'
BEGIN;
  INSERT INTO lexemes (object_id, lemma, part_of_speech, lexical_key, slug)
    VALUES (105, 'dup', 'noun', 'en/dup/noun', 'dup');
COMMIT;
\echo '   ^ expected: ERROR duplicate key / foreign key — 105 is content, not lexeme'

\echo ''
\echo '── PROOF 2d: objects.kind cannot change ─────────────────────────────────'
BEGIN;
  UPDATE objects SET kind = 'entity' WHERE id = 104;
COMMIT;
\echo '   ^ expected: ERROR objects.kind is immutable (lexeme -> entity)'

\echo ''
\echo '── PROOF 2e: a person subtype cannot attach to a concept entity ─────────'
BEGIN;
  INSERT INTO person_details (entity_id) VALUES (107);
COMMIT;
\echo '   ^ expected: ERROR foreign key — 107 is a concept, not a person'

\echo ''
\echo '── PROOF 2f: deleting a subtype cannot orphan its object ────────────────'
\echo '   The gap the first run of this spike found: an AFTER INSERT trigger on'
\echo '   `objects` cannot see a subtype being deleted out from under it.'
BEGIN;
  DELETE FROM person_details WHERE entity_id = 101;
  DELETE FROM entities WHERE object_id = 101;
COMMIT;
\echo '   ^ expected: ERROR object 101 would be left with no subtype row'

\echo ''
\echo '── PROOF 2g: deleting the object itself cascades, and is allowed ────────'
BEGIN;
  INSERT INTO objects (id, kind) VALUES (902, 'entity');
  INSERT INTO entities (object_id, entity_kind) VALUES (902, 'concept');
COMMIT;
BEGIN;
  DELETE FROM objects WHERE id = 902;
COMMIT;
SELECT count(*) AS entities_left_for_902 FROM entities WHERE object_id = 902;
\echo '   ^ expected: no error, 0 rows — the cascade path is not blocked'

\echo ''
\echo '── PROOF 3: `defines` pointing at a person is rejected ──────────────────'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES (9001, 'spike', 'bad-defines');
  INSERT INTO assertion_revisions (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id)
    VALUES (9001, 1, 105, 1, 101);
COMMIT;
\echo '   ^ expected: ERROR assertion_revisions_endpoints — content/definition -> entity/person'

\echo ''
\echo '── PROOF 3b: the same rejection on a BULK write (insert_all / COPY) ─────'
\echo '   One good row and one bad row in a single statement.'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES
    (9002, 'spike', 'bulk-good'), (9003, 'spike', 'bulk-bad');
  INSERT INTO assertion_revisions (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id)
  VALUES
    (9002, 1, 105, 1, 104),   -- good: definition defines the lexeme
    (9003, 1, 105, 1, 101);   -- bad:  definition "defines" a person
COMMIT;
\echo '   ^ expected: ERROR — the whole statement rejected, not just filtered'

\echo ''
\echo '── PROOF 3c: refers_to from a lexeme (not a sense) is rejected ──────────'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES (9004, 'spike', 'bad-refers');
  INSERT INTO assertion_revisions (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id)
    VALUES (9004, 1, 104, 3, 107);
COMMIT;
\echo '   ^ expected: ERROR — refers_to is sense -> concept; a lexeme is not a sense'

\echo ''
\echo '── PROOF 3d: confidence outside [0,1] is rejected ───────────────────────'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES (9005, 'spike', 'bad-conf');
  INSERT INTO assertion_revisions (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, confidence)
    VALUES (9005, 1, 105, 1, 104, 1.4);
COMMIT;
\echo '   ^ expected: ERROR assertion_revisions_confidence'

\echo ''
\echo '── PROOF 3e: a current-revision pointer at ANOTHER assertion is rejected ─'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES (9006, 'spike', 'good-a');
  INSERT INTO assertion_revisions (id, assertion_id, revision_number, subject_object_id, predicate_id, object_object_id)
    VALUES (77001, 9006, 1, 105, 1, 104);
  INSERT INTO assertions (id, source_slug, origin_key, current_revision_id)
    VALUES (9007, 'spike', 'steals-a-revision', 77001);
COMMIT;
\echo '   ^ expected: ERROR assertions_current_revision — revision 77001 belongs to 9006'

\echo ''
\echo '── CONTROL: the valid Bierce assertions all commit ──────────────────────'
BEGIN;
  INSERT INTO assertions (id, source_slug, origin_key) VALUES
    (1001, 'bierce', 'nepotism/defines'),
    (1002, 'bierce', 'nepotism/authored_by');
  INSERT INTO assertion_revisions (id, assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
  VALUES
    (2001, 1001, 1, 105, 1, 104, true),   -- definition  defines      nepotism
    (2002, 1002, 1, 105, 2, 101, true);   -- definition  authored_by  Bierce
  UPDATE assertions SET current_revision_id = 2001 WHERE id = 1001;
  UPDATE assertions SET current_revision_id = 2002 WHERE id = 1002;
COMMIT;
SELECT a.id, ar.subject_kind || '/' || ar.subject_subkind AS subject,
       p.key AS predicate,
       ar.object_kind || '/' || ar.object_subkind AS object
  FROM assertions a
  JOIN assertion_revisions ar ON ar.id = a.current_revision_id
  JOIN predicates p ON p.id = ar.predicate_id
 WHERE a.id IN (1001, 1002) ORDER BY a.id;
\echo '   ^ expected: two rows, kinds filled in by the trigger, nothing rejected'
