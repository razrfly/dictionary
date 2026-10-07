-- #172 final sweep, 2026-09-27: read-only; found bunny (Q9394) as a word-level page with catalog artworks.
-- word-level-only lexemes (candidate >= 0.85, no sense link on any lexeme of the same lemma), whose candidate QID a catalog artwork depicts
WITH cand AS (
  SELECT l.object_id lex, lower(l.lemma) pg, ei.external_id qid
    FROM assertion_revisions r JOIN predicates p ON p.id=r.predicate_id AND p.key='lexeme_entity_candidate'
    JOIN lexemes l ON l.object_id=r.subject_object_id AND l.language_tag='en'
    JOIN external_identifiers ei ON ei.object_id=r.object_object_id AND ei.namespace='wikidata' AND ei.status='verified'
   WHERE r.is_current AND r.lifecycle_state='active' AND r.confidence>=0.85),
sensepg AS (SELECT DISTINCT lower(l.lemma) pg FROM lexemes l JOIN senses s ON s.lexeme_id=l.object_id
   JOIN assertion_revisions r ON r.subject_object_id=s.object_id AND r.is_current AND r.lifecycle_state='active'
   JOIN predicates p ON p.id=r.predicate_id AND p.key='refers_to'
  WHERE l.language_tag='en' AND lower(l.lemma) IN (SELECT pg FROM cand)),
art AS (SELECT DISTINCT jsonb_array_elements_text(e.metadata->'depicts_qids') qid FROM entities e JOIN work_details w ON w.entity_id=e.object_id AND w.work_kind='artwork')
SELECT c.pg, c.qid, (SELECT count(*) FROM entities e JOIN work_details w ON w.entity_id=e.object_id AND w.work_kind='artwork' WHERE e.metadata->'depicts_qids' ? c.qid) works
  FROM cand c WHERE c.qid IN (SELECT qid FROM art) AND c.pg NOT IN (SELECT pg FROM sensepg)
 ORDER BY works DESC LIMIT 15;
