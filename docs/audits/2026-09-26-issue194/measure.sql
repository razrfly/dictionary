-- Each output line is a JSON measurement. Read-only, one consistent snapshot.
-- Run with psql -X -qAt -v ON_ERROR_STOP=1 ... -f measure.sql > measurements.jsonl
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '120s';
SELECT jsonb_build_object('measurement', 'snapshot', 'database', current_database(),
  'observed_at', current_timestamp, 'transaction_read_only', current_setting('transaction_read_only'));
SELECT jsonb_build_object('measurement', 'objects', 'rows', jsonb_agg(t)) FROM (
  SELECT kind, lifecycle_state, count(*) FROM objects GROUP BY kind, lifecycle_state ORDER BY kind, lifecycle_state
) t;
SELECT jsonb_build_object('measurement', 'entity_kinds', 'rows', jsonb_agg(t)) FROM (
  SELECT entity_kind, count(*),
    count(*) FILTER (WHERE jsonb_array_length(coalesce(metadata->'wikidata_instance_of','[]'::jsonb)) > 0) AS has_p31,
    count(*) FILTER (WHERE jsonb_array_length(coalesce(metadata->'wikidata_subclass_of','[]'::jsonb)) > 0) AS has_p279,
    count(*) FILTER (WHERE metadata->>'disambiguation' = 'true') AS disambiguation_flag,
    count(*) FILTER (WHERE coalesce(preferred_label, '') = '') AS missing_label,
    count(*) FILTER (WHERE coalesce(description, '') = '') AS missing_description
  FROM entities GROUP BY entity_kind ORDER BY entity_kind
) t;
SELECT jsonb_build_object('measurement', 'lexical_coverage', 'rows', jsonb_agg(t)) FROM (
  SELECT language_tag, count(*) AS lexemes, count(DISTINCT part_of_speech) AS parts_of_speech
  FROM lexemes GROUP BY language_tag ORDER BY language_tag
) t;
SELECT jsonb_build_object('measurement', 'lexical_collisions', 'exact_lemma_groups',
  count(*) FILTER (WHERE exact_lemmas > 1), 'lowercase_lemma_groups',
  count(*) FILTER (WHERE lower_lemmas > 1), 'multiple_pos_groups',
  count(*) FILTER (WHERE pos > 1)) FROM (
  SELECT slug, count(DISTINCT lemma) AS exact_lemmas, count(DISTINCT lower(lemma)) AS lower_lemmas,
    count(DISTINCT part_of_speech) AS pos FROM lexemes GROUP BY slug
) t;
SELECT jsonb_build_object('measurement', 'entity_label_collisions', 'groups', count(*), 'entities', sum(n)) FROM (
  SELECT lower(preferred_label), count(*) n FROM entities
  GROUP BY lower(preferred_label) HAVING count(*) > 1
) t;
SELECT jsonb_build_object('measurement', 'within_kind_label_collisions', 'rows', jsonb_agg(t)) FROM (
  SELECT entity_kind, count(*) AS groups, sum(n) AS entities FROM (
    SELECT entity_kind, lower(preferred_label), count(*) n FROM entities
    GROUP BY entity_kind, lower(preferred_label) HAVING count(*) > 1
  ) c GROUP BY entity_kind ORDER BY entity_kind
) t;
SELECT jsonb_build_object('measurement', 'content_kinds', 'rows', jsonb_agg(t)) FROM (
  SELECT content_kind, count(*) FROM content_items GROUP BY content_kind ORDER BY content_kind
) t;
SELECT jsonb_build_object('measurement', 'classification_targets', 'rows', jsonb_agg(t)) FROM (
  SELECT p.property, count(*) AS references, count(DISTINCT p.qid) AS distinct_targets,
    count(*) FILTER (WHERE x.id IS NULL) AS references_without_local_verified_target,
    count(DISTINCT p.qid) FILTER (WHERE x.id IS NULL) AS targets_without_local_verified_target
  FROM entities e CROSS JOIN LATERAL (
    SELECT 'P31' AS property, jsonb_array_elements_text(coalesce(e.metadata->'wikidata_instance_of', '[]'::jsonb)) AS qid
    UNION ALL
    SELECT 'P279', jsonb_array_elements_text(coalesce(e.metadata->'wikidata_subclass_of', '[]'::jsonb))
  ) p LEFT JOIN external_identifiers x ON x.namespace = 'wikidata' AND x.external_id = p.qid AND x.status = 'verified'
  GROUP BY p.property ORDER BY p.property
) t;
SELECT jsonb_build_object('measurement', 'lexical_examples', 'rows', jsonb_agg(t)) FROM (
  SELECT object_id, lemma, language_tag, part_of_speech, slug FROM lexemes
  WHERE lemma IN ('C++', 'C+', 'Polish', 'polish', 'US', 'us', 'Voltaire', 'Putin', 'Vladimir Putin', 'poutine', 'love', 'Love', 'Apple', 'apple')
  ORDER BY lemma, object_id
) t;
SELECT jsonb_build_object('measurement', 'selected_identifiers', 'rows', jsonb_agg(t)) FROM (
  SELECT external_id, object_id, status FROM external_identifiers
  WHERE namespace = 'wikidata' AND external_id IN ('Q9068', 'Q7747', 'Q308', 'Q925', 'Q1150', 'Q111', 'Q146', 'Q20980826')
  ORDER BY external_id
) t;
COMMIT;
