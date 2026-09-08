-- Gate 0: strategy C reads 10x faster, but #74 is explicit that a partial
-- unique index proves AT MOST one, not exactly one, and demands "a commit-time
-- guarantee for exactly one selected revision and atomic switching".
--
-- Atomic switching is the part that can quietly not work: a UNIQUE index is
-- checked per row as an UPDATE walks the table, so a single statement that
-- moves the flag from one row to another can fail depending on visit order --
-- and a partial unique index cannot be made DEFERRABLE (only table-level
-- UNIQUE constraints can, and those cannot be partial).
--
-- So: does it fail? Measured, not assumed.

\set ON_ERROR_STOP off
\timing on

\echo ''
\echo '── A: one statement moving the flag, ascending visit order ─────────────'
BEGIN;
  UPDATE assertion_revisions
     SET is_current = (revision_number = 4)
   WHERE assertion_id = 5;
COMMIT;
SELECT revision_number, is_current FROM assertion_revisions WHERE assertion_id = 5 ORDER BY 1;

\echo ''
\echo '── B: the same, moving it the other way (descending) ───────────────────'
BEGIN;
  UPDATE assertion_revisions
     SET is_current = (revision_number = 2)
   WHERE assertion_id = 5;
COMMIT;
SELECT revision_number, is_current FROM assertion_revisions WHERE assertion_id = 5 ORDER BY 1;

\echo ''
\echo '── C: adding a NEW revision and making it current, one statement each ──'
BEGIN;
  INSERT INTO assertion_revisions
    (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
  SELECT 5, 6, subject_object_id, predicate_id, object_object_id, true
    FROM assertion_revisions WHERE assertion_id = 5 AND revision_number = 1;
COMMIT;
\echo '   ^ inserting a second current row must be REJECTED by ar_one_current'
SELECT revision_number, is_current FROM assertion_revisions WHERE assertion_id = 5 ORDER BY 1;

\echo ''
\echo '── D: the correct two-statement switch, inside one transaction ─────────'
BEGIN;
  SELECT id FROM assertions WHERE id = 5 FOR UPDATE;
  UPDATE assertion_revisions SET is_current = false WHERE assertion_id = 5 AND is_current;
  INSERT INTO assertion_revisions
    (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
  SELECT 5, 6, subject_object_id, predicate_id, object_object_id, true
    FROM assertion_revisions WHERE assertion_id = 5 AND revision_number = 1;
COMMIT;
SELECT revision_number, is_current FROM assertion_revisions WHERE assertion_id = 5 ORDER BY 1;
\echo '   ^ expected: exactly one current row, revision 6'
