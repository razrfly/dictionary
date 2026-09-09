defmodule DevilsDictionary.Health.RebuildSnapshot do
  @moduledoc "ID-independent multiset fingerprints of a freshly rebuilt corpus, including exact text and source ownership."

  def capture(database) do
    config =
      DevilsDictionary.Repo.config() |> Keyword.take([:hostname, :port, :username, :password])

    {:ok, conn} = Postgrex.start_link(Keyword.merge(config, database: database))

    try do
      query(conn, "BEGIN ISOLATION LEVEL REPEATABLE READ")

      query(conn, """
      CREATE TEMP TABLE audit_nodes AS
      SELECT o.id, encode(sha256(convert_to(jsonb_build_array(o.kind,
        CASE o.kind
          WHEN 'lexeme' THEN jsonb_build_array(l.lexical_key)
          WHEN 'sense' THEN jsonb_build_array(ss.slug, sl.lexical_key, s.external_key)
          WHEN 'entity' THEN jsonb_build_array(e.entity_kind, e.preferred_label,
            (SELECT jsonb_agg(jsonb_build_array(x.namespace,x.external_id,x.status) ORDER BY x.namespace,x.external_id,x.status)
             FROM external_identifiers x WHERE x.object_id=o.id))
          WHEN 'content' THEN jsonb_build_array(cs.slug,c.content_kind,cr.headword,cr.body,cr.canonical_url)
        END)::text, 'UTF8')), 'hex') AS k
      FROM objects o
      LEFT JOIN lexemes l ON l.object_id=o.id
      LEFT JOIN senses s ON s.object_id=o.id
      LEFT JOIN lexemes sl ON sl.object_id=s.lexeme_id
      LEFT JOIN sources ss ON ss.id=s.source_id
      LEFT JOIN entities e ON e.object_id=o.id
      LEFT JOIN content_items c ON c.object_id=o.id
      LEFT JOIN sources cs ON cs.id=c.source_id
      LEFT JOIN content_revisions cr ON cr.content_id=c.object_id AND cr.is_current
      """)

      query(conn, "CREATE UNIQUE INDEX ON audit_nodes(id)")

      query(conn, """
      CREATE TEMP TABLE audit_claims AS
      SELECT a.id, jsonb_build_array(src.slug,p.key,ns.k,nt.k,nc.k,nj.k,
        to_jsonb(r)-ARRAY['id','assertion_id','subject_object_id','object_object_id','predicate_id',
          'context_object_id','jurisdiction_entity_id','inserted_at','updated_at','revision_number','is_current'],
        oa.actor_kind,oe.k,oa.label,sa.actor_kind,se.k,sa.label) AS payload
      FROM assertions a JOIN assertion_revisions r ON r.assertion_id=a.id AND r.is_current
      JOIN predicates p ON p.id=r.predicate_id
      JOIN audit_nodes ns ON ns.id=r.subject_object_id JOIN audit_nodes nt ON nt.id=r.object_object_id
      LEFT JOIN audit_nodes nc ON nc.id=r.context_object_id LEFT JOIN audit_nodes nj ON nj.id=r.jurisdiction_entity_id
      LEFT JOIN sources src ON src.id=a.source_id
      LEFT JOIN actors oa ON oa.id=a.origin_actor_id LEFT JOIN audit_nodes oe ON oe.id=oa.entity_id
      LEFT JOIN actors sa ON sa.id=a.submitted_by_actor_id LEFT JOIN audit_nodes se ON se.id=sa.entity_id
      """)

      query(conn, "CREATE UNIQUE INDEX ON audit_claims(id)")
      Map.new(dimensions(), fn {name, sql} -> {name, fingerprint(conn, sql)} end)
    after
      GenServer.stop(conn)
    end
  end

  defp dimensions do
    [
      {"source_records",
       "SELECT jsonb_build_array(s.slug,r.external_id,r.url,r.content_hash,rr.payload) payload FROM source_records r JOIN sources s ON s.id=r.source_id JOIN source_record_revisions rr ON rr.source_record_id=r.id AND rr.revision_key=r.content_hash"},
      {"objects",
       "SELECT jsonb_build_array(n.k,o.lifecycle_state) payload FROM objects o JOIN audit_nodes n ON n.id=o.id"},
      {"lexemes",
       """
       SELECT jsonb_build_array(n.k,cn.k,os.slug,es.slug,
         (SELECT jsonb_agg(src.slug ORDER BY src.slug) FROM sources src WHERE src.id=ANY(l.source_ids)),
         to_jsonb(l)-ARRAY['object_id','canonical_lexeme_id','origin_source_id','etymology_source_id','source_ids','inserted_at','updated_at','enriched_at']) payload
       FROM lexemes l JOIN audit_nodes n ON n.id=l.object_id LEFT JOIN audit_nodes cn ON cn.id=l.canonical_lexeme_id
       LEFT JOIN sources os ON os.id=l.origin_source_id LEFT JOIN sources es ON es.id=l.etymology_source_id
       """},
      {"senses",
       """
       SELECT jsonb_build_array(n.k,s.identity_state,to_jsonb(r)-ARRAY['id','sense_id','source_record_revision_id','revision_number','inserted_at','updated_at','is_current']) payload
       FROM senses s JOIN audit_nodes n ON n.id=s.object_id JOIN sense_revisions r ON r.sense_id=s.object_id AND r.is_current
       """},
      {"content",
       """
       SELECT jsonb_build_array(n.k,c.content_kind,c.original_language,c.metadata,to_jsonb(r)-ARRAY['id','content_id','source_record_revision_id','revision_number','inserted_at','updated_at','is_current']) payload
       FROM content_items c JOIN audit_nodes n ON n.id=c.object_id JOIN content_revisions r ON r.content_id=c.object_id AND r.is_current
       """},
      {"entities",
       "SELECT jsonb_build_array(n.k,to_jsonb(e)-ARRAY['object_id','inserted_at','updated_at']) payload FROM entities e JOIN audit_nodes n ON n.id=e.object_id"},
      {"person_details",
       "SELECT jsonb_build_array(n.k,to_jsonb(d)-ARRAY['entity_id','inserted_at','updated_at']) payload FROM person_details d JOIN audit_nodes n ON n.id=d.entity_id"},
      {"work_details",
       "SELECT jsonb_build_array(n.k,to_jsonb(d)-ARRAY['entity_id','inserted_at','updated_at']) payload FROM work_details d JOIN audit_nodes n ON n.id=d.entity_id"},
      {"edition_details",
       "SELECT jsonb_build_array(n.k,w.k,to_jsonb(d)-ARRAY['entity_id','work_id','inserted_at','updated_at']) payload FROM edition_details d JOIN audit_nodes n ON n.id=d.entity_id LEFT JOIN audit_nodes w ON w.id=d.work_id"},
      {"forms",
       "SELECT jsonb_build_array(n.k,src.slug,sr.external_id,to_jsonb(f)-ARRAY['id','lexeme_id','source_record_revision_id','inserted_at','updated_at']) payload FROM lexeme_forms f JOIN audit_nodes n ON n.id=f.lexeme_id LEFT JOIN source_record_revisions rr ON rr.id=f.source_record_revision_id LEFT JOIN source_records sr ON sr.id=rr.source_record_id LEFT JOIN sources src ON src.id=sr.source_id"},
      {"names",
       "SELECT jsonb_build_array(n.k,src.slug,sr.external_id,to_jsonb(f)-ARRAY['id','object_id','source_record_revision_id','inserted_at','updated_at']) payload FROM object_names f JOIN audit_nodes n ON n.id=f.object_id LEFT JOIN source_record_revisions rr ON rr.id=f.source_record_revision_id LEFT JOIN source_records sr ON sr.id=rr.source_record_id LEFT JOIN sources src ON src.id=sr.source_id"},
      {"external_identifiers",
       "SELECT jsonb_build_array(n.k,to_jsonb(x)-ARRAY['id','object_id','source_record_revision_id','inserted_at','updated_at']) payload FROM external_identifiers x JOIN audit_nodes n ON n.id=x.object_id"},
      {"claims", "SELECT payload FROM audit_claims"},
      {"object_attestations",
       """
       SELECT jsonb_build_array(src.slug,sr.external_id,n.k,o.output_role,o.retired_at IS NOT NULL) payload
       FROM source_materialized_outputs o JOIN source_records sr ON sr.id=o.source_record_id
       JOIN sources src ON src.id=sr.source_id JOIN audit_nodes n ON n.id=o.output_object_id
       """},
      {"claim_attestations",
       """
       SELECT jsonb_build_array(src.slug,sr.external_id,c.payload,o.retired_at IS NOT NULL) payload
       FROM source_assertion_outputs o JOIN source_records sr ON sr.id=o.source_record_id
       JOIN sources src ON src.id=sr.source_id JOIN audit_claims c ON c.id=o.assertion_id
       """},
      {"scopes",
       """
       SELECT jsonb_build_array(s.slug,n.k,m.reasons) payload FROM scope_lexeme_members m
       JOIN scopes s ON s.id=m.scope_id JOIN audit_nodes n ON n.id=m.lexeme_id
       """}
    ]
  end

  defp fingerprint(conn, sql) do
    rows =
      query(conn, """
      WITH data AS (#{sql}), hashes AS (
        SELECT encode(sha256(convert_to(payload::text, 'UTF8')), 'hex') h FROM data
      ) SELECT left(h,2),count(*),encode(sha256(convert_to(string_agg(h,'' ORDER BY h), 'UTF8')),'hex')
        FROM hashes GROUP BY left(h,2) ORDER BY left(h,2)
      """).rows

    %{
      "rows" => Enum.reduce(rows, 0, fn [_, n, _], acc -> acc + n end),
      "sha256" => Base.encode16(:crypto.hash(:sha256, Jason.encode!(rows)), case: :lower)
    }
  end

  defp query(conn, sql), do: Postgrex.query!(conn, sql, [], timeout: :infinity)
end
