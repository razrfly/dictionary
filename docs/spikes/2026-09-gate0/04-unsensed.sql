-- Gate 0 finding: 36,434 of the 1,163,659 resolved relations are sense -> lexeme.
--
-- The first load declared only lexeme->lexeme and sense->sense, and those rows
-- fell out. They are not junk: a source can say "this meaning relates to that
-- WORD" without naming which of the word's meanings, and #74 §C requires
-- exactly that — "preserve unsensed lexical relations without inventing sense
-- IDs". Inventing one would be the bug.
--
-- So the endpoint rule set gains a third pair. This is what the gate is for:
-- the shape was discovered by loading the real population, not by reasoning
-- about it.

\timing on

INSERT INTO predicate_endpoint_rules (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind)
SELECT id, 'sense', '-', 'lexeme', '-' FROM predicates
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE stage_relations (
  id bigint, from_lexeme_id bigint, from_sense_id bigint,
  to_lexeme_id bigint, to_sense_id bigint, type text, source_slug text
);
\copy stage_relations from '/private/tmp/claude-501/-Users-holden-Code-projects-2026-dictionary/d01531c8-e385-481b-8180-acf1a6e6441e/scratchpad/gate0/relations.csv' csv

INSERT INTO assertion_revisions
  (assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, is_current)
SELECT r.id, 1, 10000000 + r.from_sense_id, p.id, r.to_lexeme_id, true
  FROM stage_relations r JOIN predicates p ON p.key = r.type
 WHERE r.from_sense_id IS NOT NULL AND r.to_sense_id IS NULL;

UPDATE assertions a SET current_revision_id = ar.id
  FROM assertion_revisions ar
 WHERE ar.assertion_id = a.id AND ar.revision_number = 1 AND a.current_revision_id IS NULL;

SELECT subject_kind, object_kind, count(*) FROM assertion_revisions
 WHERE revision_number = 1 GROUP BY 1,2 ORDER BY 3 DESC;
SELECT count(*) AS assertions_with_no_current FROM assertions WHERE current_revision_id IS NULL;
