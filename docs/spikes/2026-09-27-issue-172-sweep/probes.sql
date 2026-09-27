-- #172 final sweep, 2026-09-27: produced probes.out (Wikiquote runs 366, 367 and the cached runs 238, 263, 264).
WITH t(w, target) AS (VALUES ('nepotism',198692),('war',147197),('grief',78062),('love',9051),('power',51397),('family',17922),('solitude',56434),('justice',19599),('bank',4011),('pop art',484148),('situationship',1161781),('narcissism',194077),('coward',117393)),
lastrun AS (
  SELECT DISTINCT ON (m.target_object_id) m.target_object_id, m.id mapping_id, m.parameters, r.id run_id, r.result_count, r.inserted_at
    FROM discovery_mappings m JOIN sources s ON s.id=m.source_id AND s.slug='wikiquote'
    JOIN discovery_runs r ON r.mapping_id=m.id AND r.status='succeeded'
   WHERE m.enabled ORDER BY m.target_object_id, r.inserted_at DESC)
SELECT t.w, lr.run_id, lr.inserted_at::date,
       coalesce(lr.parameters->'entities'->0->>'level','sense') AS tier,
       (SELECT string_agg(e->>'qid'||' '||(e->>'label'), '; ') FROM jsonb_array_elements(lr.parameters->'entities') e) AS recipe,
       lr.result_count,
       (SELECT x.match_details->'sitelinks'->0->>'title' || ' (' || (x.match_details->'sitelinks'->0->>'qid') || ')' ||
               coalesce(' via '||(x.match_details->'sitelinks'->0->'reached')::text||' from '||(x.match_details->'sitelinks'->0->>'from'),'')
          FROM discovery_results x WHERE x.run_id=lr.run_id LIMIT 1) AS page,
       (SELECT count(*) FROM discovery_results x WHERE x.run_id=lr.run_id AND x.match_details->>'level'='word') AS word_level_results
  FROM t LEFT JOIN lastrun lr ON lr.target_object_id=t.target ORDER BY t.w;
