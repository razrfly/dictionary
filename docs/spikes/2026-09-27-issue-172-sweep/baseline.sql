-- #172 final sweep, 2026-09-27: produced baseline.out (before runs 206-211) and after.out (after them).
\timing off
-- links (current, active) per method, with revisions total for contrast
SELECT p.key, r.method, count(*) FILTER (WHERE r.is_current AND r.lifecycle_state='active') AS active_links,
       count(*) FILTER (WHERE r.is_current) AS current_links, count(*) AS revisions
  FROM assertion_revisions r JOIN predicates p ON p.id=r.predicate_id AND p.key IN ('refers_to','lexeme_entity_candidate')
 GROUP BY 1,2 ORDER BY 1,2;
CREATE TEMP TABLE sl AS
  SELECT DISTINCT s.lexeme_id, r.method FROM senses s
    JOIN assertion_revisions r ON r.subject_object_id=s.object_id AND r.is_current AND r.lifecycle_state='active'
    JOIN predicates p ON p.id=r.predicate_id AND p.key='refers_to'
    JOIN external_identifiers ei ON ei.object_id=r.object_object_id AND ei.namespace='wikidata' AND ei.status='verified';
CREATE TEMP TABLE wl AS
  SELECT DISTINCT r.subject_object_id AS lexeme_id FROM assertion_revisions r
    JOIN predicates p ON p.id=r.predicate_id AND p.key='lexeme_entity_candidate'
    JOIN external_identifiers ei ON ei.object_id=r.object_object_id AND ei.namespace='wikidata' AND ei.status='verified'
   WHERE r.is_current AND r.lifecycle_state='active' AND r.confidence>=0.85;
CREATE TEMP TABLE en AS SELECT object_id, lower(lemma) pg FROM lexemes WHERE language_tag='en';
CREATE INDEX ON en(object_id); ANALYZE en;
CREATE TEMP TABLE spg AS SELECT DISTINCT en.pg FROM sl JOIN en ON en.object_id=sl.lexeme_id; ANALYZE spg;
SELECT
 (SELECT count(*) FROM en) en_lexemes,
 (SELECT count(DISTINCT pg) FROM en) en_pages,
 (SELECT count(DISTINCT sl.lexeme_id) FROM sl JOIN en ON en.object_id=sl.lexeme_id) sense_lexemes,
 (SELECT count(DISTINCT en.pg) FROM sl JOIN en ON en.object_id=sl.lexeme_id) sense_pages,
 (SELECT count(DISTINCT sl.lexeme_id) FROM sl JOIN en ON en.object_id=sl.lexeme_id WHERE sl.method<>'corroborated_gloss') sense_lexemes_excl_promotion,
 (SELECT count(DISTINCT en.pg) FROM sl JOIN en ON en.object_id=sl.lexeme_id WHERE sl.method<>'corroborated_gloss') sense_pages_excl_promotion,
 (SELECT count(*) FROM wl JOIN en ON en.object_id=wl.lexeme_id) cand_lexemes,
 (SELECT count(DISTINCT en.pg) FROM wl JOIN en ON en.object_id=wl.lexeme_id
    WHERE NOT EXISTS (SELECT 1 FROM spg WHERE spg.pg=en.pg)) word_level_only_pages;
-- promotions whose sense now also has an active source link: same entity vs other
SELECT (o.object_object_id = r.object_object_id) AS same_entity, count(DISTINCT r.assertion_id)
  FROM assertion_revisions r JOIN predicates p ON p.id=r.predicate_id AND p.key='refers_to'
  JOIN assertion_revisions o ON o.subject_object_id=r.subject_object_id AND o.is_current AND o.lifecycle_state='active'
       AND o.predicate_id=r.predicate_id AND o.method IS DISTINCT FROM 'corroborated_gloss'
 WHERE r.is_current AND r.lifecycle_state='active' AND r.method='corroborated_gloss'
 GROUP BY 1;
SELECT count(*) AS reviews, string_agg(DISTINCT decision::text, ',') FROM assertion_reviews;
