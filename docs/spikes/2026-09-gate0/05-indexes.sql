-- Gate 0, proof 7: the three current-revision strategies get their indexes,
-- built and timed separately so the storage cost of each is attributable.
\timing on

\echo '── shared: endpoint indexes (every strategy needs these) ───────────────'
CREATE INDEX ar_subject ON assertion_revisions (subject_object_id, predicate_id);
CREATE INDEX ar_object  ON assertion_revisions (object_object_id, predicate_id);

\echo '── strategy A: explicit pointer (assertions.current_revision_id) ───────'
CREATE INDEX a_current ON assertions (current_revision_id);

\echo '── strategy B: DISTINCT ON / latest-row — needs (assertion, rev desc) ──'
CREATE INDEX ar_latest ON assertion_revisions (assertion_id, revision_number DESC);

\echo '── strategy C: partial index on is_current ────────────────────────────'
-- A partial UNIQUE index proves AT MOST one current revision per assertion.
-- It does not prove exactly one -- that still needs a commit-time check --
-- which is the point #74 makes about this option.
CREATE UNIQUE INDEX ar_one_current ON assertion_revisions (assertion_id) WHERE is_current;
CREATE INDEX ar_subject_current ON assertion_revisions (subject_object_id, predicate_id) WHERE is_current;
CREATE INDEX ar_object_current  ON assertion_revisions (object_object_id, predicate_id) WHERE is_current;

ANALYZE;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes WHERE relname = 'assertion_revisions'
 ORDER BY pg_relation_size(indexrelid) DESC;
