SELECT count(*) AS indexed_lexemes FROM lexemes;
SELECT count(DISTINCT s.lexeme_id) AS defined_lexemes
FROM senses s JOIN sense_revisions r ON r.sense_id=s.object_id AND r.is_current
WHERE r.lifecycle_state='active' AND length(trim(r.gloss))>0;
SELECT entity_kind,count(*) FROM entities GROUP BY entity_kind ORDER BY entity_kind;
SELECT r.subject_object_id,p.key,r.object_object_id,r.method
FROM assertion_revisions r JOIN predicates p ON p.id=r.predicate_id
WHERE r.is_current AND r.lifecycle_state='active'
AND (r.subject_object_id=341814 OR r.subject_object_id=342580
OR (r.object_object_id=1 AND p.key IN ('refers_to','lexeme_entity_candidate')));
