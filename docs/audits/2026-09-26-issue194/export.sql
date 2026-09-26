-- Read-only corpus evidence for issue #194. No account data or content bodies.
-- Run with psql -X -q -v ON_ERROR_STOP=1 ... -f export.sql > /tmp/issue194-entities.csv
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '120s';
COPY (
  SELECT e.object_id, e.entity_kind, e.preferred_label, e.description,
    o.lifecycle_state,
    coalesce(e.metadata->'wikidata_instance_of', '[]'::jsonb) AS instance_of,
    coalesce(e.metadata->'wikidata_subclass_of', '[]'::jsonb) AS subclass_of,
    e.metadata->>'disambiguation' AS disambiguation,
    e.metadata->>'content_type' AS content_type,
    e.metadata->>'catalog_source' AS catalog_source,
    e.metadata->>'taxon' AS taxon,
    w.work_kind,
    coalesce((SELECT jsonb_agg(x.external_id ORDER BY x.external_id)
      FROM external_identifiers x WHERE x.object_id = e.object_id
        AND x.namespace = 'wikidata' AND x.status = 'verified'), '[]'::jsonb) AS qids
  FROM entities e JOIN objects o ON o.id = e.object_id
  LEFT JOIN work_details w ON w.entity_id = e.object_id
  ORDER BY e.object_id
) TO STDOUT WITH (FORMAT csv, HEADER true);
COMMIT;
