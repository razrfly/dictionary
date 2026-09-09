alias DevilsDictionary.Repo
scalar = fn sql -> Repo.query!(sql, [], timeout: :infinity).rows |> hd() |> hd() end
counts = Map.new(~w(objects lexemes senses sense_revisions entities content_items content_revisions assertions assertion_revisions source_records source_materialized_outputs source_assertion_outputs lexeme_forms), fn table -> {table, scalar.("SELECT count(*) FROM #{table}")} end)
violations = Map.new([{ "sense_current", "SELECT count(*) FROM (SELECT s.object_id FROM senses s LEFT JOIN sense_revisions r ON r.sense_id=s.object_id AND r.is_current GROUP BY s.object_id HAVING count(r.id)<>1) bad"},
{"content_current", "SELECT count(*) FROM (SELECT c.object_id FROM content_items c LEFT JOIN content_revisions r ON r.content_id=c.object_id AND r.is_current GROUP BY c.object_id HAVING count(r.id)<>1) bad"},
{"assertion_current", "SELECT count(*) FROM (SELECT a.id FROM assertions a LEFT JOIN assertion_revisions r ON r.assertion_id=a.id AND r.is_current GROUP BY a.id HAVING count(r.id)<>1) bad"},
{"unstamped_objects", "SELECT count(*) FROM source_materialized_outputs WHERE last_seen_run_id IS NULL"},
{"unstamped_claims", "SELECT count(*) FROM source_assertion_outputs WHERE last_seen_run_id IS NULL"},
{"missing_source_snapshot", "SELECT count(*) FROM source_records sr WHERE NOT EXISTS (SELECT 1 FROM source_record_revisions rr WHERE rr.source_record_id=sr.id AND rr.revision_key=sr.content_hash)"}], fn {name, sql} -> {name, scalar.(sql)} end)
result = %{database: Repo.config()[:database], measured_at: DateTime.utc_now(), counts: counts, violations: violations,
 database_bytes: scalar.("SELECT pg_database_size(current_database())"),
 assertion_storage_bytes: scalar.("SELECT pg_total_relation_size('assertions')+pg_total_relation_size('assertion_revisions')")}
File.write!("/private/tmp/74-final-metrics.json", Jason.encode!(result, pretty: true))
IO.puts(Jason.encode!(result, pretty: true))
