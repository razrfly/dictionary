defmodule DevilsDictionary.Installation.DiscoveryProjection do
  @moduledoc "Snapshot-local, payload-safe dd.bundle/2 projections. No source rows are changed."
  alias DevilsDictionary.Snapshot

  @excluded ~w(discovery_results discovery_runs discovery_request_attempts source_records source_record_revisions)
  def excluded, do: @excluded

  def plan(conn, at) do
    case Postgrex.query!(conn, "SELECT to_regclass('source_records') IS NOT NULL", []).rows do
      [[false]] -> %{}
      [[true]] -> projected_plan(conn, at)
    end
  end

  defp projected_plan(conn, at) do
    %{rows: fks} =
      Postgrex.query!(
        conn,
        """
        SELECT c.conrelid::regclass::text,a.attname,c.confrelid::regclass::text
        FROM pg_constraint c JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=c.conkey[1]
        WHERE c.contype='f' AND c.confrelid IN ('source_records'::regclass,'source_record_revisions'::regclass)
        AND cardinality(c.conkey)=1
        """,
        []
      )

    guard = fn target, column ->
      fks
      |> Enum.filter(fn [table, _, to] -> to == target and table not in @excluded end)
      |> Enum.map_join(" OR ", fn [table, key, _] ->
        "EXISTS(SELECT 1 FROM #{quote_id(table)} held WHERE held.#{quote_id(key)}=#{column})"
      end)
      |> case do
        "" -> "false"
        sql -> sql
      end
    end

    held_record = guard.("source_records", "rec.id")
    held_revision = guard.("source_record_revisions", "rv.id")

    retained =
      "(#{held_record} OR EXISTS(SELECT 1 FROM source_record_revisions rv WHERE rv.source_record_id=rec.id AND (#{held_revision})))"

    shape = fn alias_name ->
      "(#{alias_name}.payload ?& ARRAY['external_namespace','external_id','preview_metadata','match_details'] OR #{alias_name}.payload ? '_discovery_redaction')"
    end

    provider =
      "src.slug IN ('guardian','bing-news','spotify','pexels','unsplash','openverse','commons','met','cinegraph','open-library','poetrydb','wikiquote')"

    discovery =
      "#{provider} AND (EXISTS(SELECT 1 FROM source_record_revisions shape WHERE shape.source_record_id=rec.id AND shape.checksum=rec.content_hash AND #{shape.("shape")}) OR EXISTS(SELECT 1 FROM curation_shelf_citations cited WHERE cited.cited_source_record_id=rec.id AND cited.cited_checksum=rec.content_hash AND cited.external_ref_sha256=CASE WHEN rec.external_id LIKE 'redacted-discovery:%' THEN substring(rec.external_id from 20) ELSE encode(sha256(convert_to(rec.external_id,'UTF8')),'hex') END) OR (NOT EXISTS(SELECT 1 FROM source_record_revisions remaining WHERE remaining.source_record_id=rec.id) AND rec.external_id LIKE ANY(ARRAY['guardian_article:%','news_article:%','spotify_track:%','pexels_photo:%','unsplash_photo:%','openverse_media:%','commons_file:%','met_object:%','tmdb_movie:%','olid:%','poetrydb_poem:%','wikiquote_item:%','redacted-discovery:%'])))"

    native =
      "EXISTS(SELECT 1 FROM source_record_revisions native WHERE native.source_record_id=rec.id AND NOT (#{provider} AND #{shape.("native")}))"

    keep = "NOT (#{discovery}) OR #{native} OR #{retained}"
    timestamp = DateTime.to_iso8601(at)

    record = """
    SELECT (jsonb_populate_record(NULL::source_records,
      CASE WHEN #{discovery} THEN discovery_retained_record(src.slug,to_jsonb(rec),'#{timestamp}'::timestamptz)
           ELSE to_jsonb(rec) END)).*
    FROM source_records rec JOIN sources src ON src.id=rec.source_id WHERE #{keep}
    """

    revision = """
    SELECT (jsonb_populate_record(NULL::source_record_revisions,
      CASE WHEN #{provider} AND #{shape.("rv")} THEN to_jsonb(rv) || jsonb_build_object(
        'payload',discovery_retained_payload(src.slug,rv.payload,'#{timestamp}'::timestamptz),
        'revision_key',CASE WHEN discovery_retained_payload(src.slug,rv.payload,'#{timestamp}'::timestamptz) IS DISTINCT FROM (rv.payload)
          THEN CASE WHEN rv.revision_key LIKE 'redacted-discovery:%' THEN rv.revision_key ELSE 'redacted-discovery:' || rv.id::text || ':' || rv.checksum END ELSE rv.revision_key END)
      ELSE to_jsonb(rv) END)).*
    FROM source_record_revisions rv JOIN source_records rec ON rec.id=rv.source_record_id
    JOIN sources src ON src.id=rec.source_id WHERE NOT (#{provider} AND #{shape.("rv")}) OR #{retained}
    """

    Map.new(@excluded, fn table ->
      sql =
        case table do
          "source_records" -> record
          "source_record_revisions" -> revision
          _ -> "SELECT * FROM #{quote_id(table)} WHERE false"
        end

      {table, sql}
    end)
  end

  def copy_out!(config, snapshot, sql, path) do
    unless snapshot =~ ~r/\A[0-9A-F]+-[0-9A-F]+-[0-9]+\z/, do: raise("invalid snapshot")

    command =
      "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET TRANSACTION SNAPSHOT '#{snapshot}'; COPY (#{sql}) TO STDOUT WITH (FORMAT binary); COMMIT;"

    run_psql!(config, ["-q", "-o", path, "-c", command])
  end

  def copy_in!(config, table, path) when table in ~w(source_records source_record_revisions) do
    path = String.replace(path, "'", "''")
    run_psql!(config, ["-q", "-c", "\\copy #{table} FROM '#{path}' WITH (FORMAT binary)"])
  end

  defp run_psql!(config, args) do
    binary = System.find_executable("psql") || raise("psql is not on PATH")

    case System.cmd(
           binary,
           ["-X", "-v", "ON_ERROR_STOP=1"] ++
             Snapshot.connection_args(config) ++ ["-d", config[:database]] ++ args,
           env: [{"PGPASSWORD", to_string(config[:password] || "")}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, status} -> raise("projection psql exited #{status}: #{out}")
    end
  end

  defp quote_id(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
