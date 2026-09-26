-- Export reproducible policy inputs, not content bodies or account data.
-- psql -X -qAt -v ON_ERROR_STOP=1 ... -f policy-export.sql > /tmp/routing-input.jsonl
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '120s';
SELECT jsonb_build_object('record_type','snapshot','observed_at',current_timestamp,
  'database',current_database(),'read_only',current_setting('transaction_read_only'));
SELECT jsonb_build_object('record_type','class_evidence','qid',r.external_id,
  'revision_id',v.id,'checksum',v.checksum,
  'claims',jsonb_build_object('P31',coalesce(v.payload->'claims'->'P31','[]'::jsonb),
                             'P279',coalesce(v.payload->'claims'->'P279','[]'::jsonb)))
FROM source_records r JOIN sources s ON s.id=r.source_id
JOIN LATERAL (SELECT id,checksum,payload FROM source_record_revisions
              WHERE source_record_id=r.id ORDER BY id DESC LIMIT 1) v ON true
WHERE s.slug='wikidata' AND r.external_id ~ '^Q[0-9]+$' ORDER BY r.external_id;
SELECT jsonb_build_object('record_type','entity','object_id',e.object_id,
  'entity_kind',e.entity_kind,'label',e.preferred_label,'description',e.description,
  'lifecycle',o.lifecycle_state,
  'instance_of',coalesce(e.metadata->'wikidata_instance_of','[]'::jsonb),
  'subclass_of',coalesce(e.metadata->'wikidata_subclass_of','[]'::jsonb),
  'disambiguation',coalesce(e.metadata->'disambiguation','false'::jsonb),
  'taxon',e.metadata->'taxon','work_kind',w.work_kind,
  'edition_work_id',ed.work_id,
  'qids',coalesce((SELECT jsonb_agg(x.external_id ORDER BY x.external_id)
    FROM external_identifiers x WHERE x.object_id=e.object_id
    AND x.namespace='wikidata' AND x.status='verified'),'[]'::jsonb))
FROM entities e JOIN objects o ON o.id=e.object_id
LEFT JOIN work_details w ON w.entity_id=e.object_id
LEFT JOIN edition_details ed ON ed.entity_id=e.object_id ORDER BY e.object_id;
SELECT jsonb_build_object('record_type','lexical_population','count',count(*),
  'languages',array_agg(DISTINCT language_tag),'parts_of_speech',count(DISTINCT part_of_speech)) FROM lexemes;
COMMIT;
