defmodule DevilsDictionary.Curation.DiscoveryRetention do
  @moduledoc "One read-only action plan shared by dry run and bounded, canonically locked cleanup."
  import Ecto.Query
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Discovery.{Result, Run, Policy}
  alias DevilsDictionary.Curation.ShelfCitations

  @record_guards ~w(pending_relations reconciliation_cases source_assertion_outputs source_materialized_outputs)
  @revision_guards ~w(assertion_evidence content_revisions external_identifiers lexeme_forms object_names sense_revisions editorial_composition_items)

  def capture_legacy(run_ids) do
    Repo.all(from d in Result, where: d.run_id in ^run_ids) |> Enum.each(&capture_result/1)
    :ok
  end

  defp capture_result(result) do
    Repo.transaction(fn ->
      run = Repo.get!(Run, result.run_id) |> Repo.preload(:mapping)

      digest =
        DevilsDictionary.Curation.Digest.sha256(
          result.external_namespace <> ":" <> result.external_id
        )

      canonical_lock(run.mapping.source_id, digest, result.source_record_id)

      if revision = ShelfCitations.bound_revision(result) do
        run = Repo.preload(run, mapping: :source)

        expiry =
          if run.expires_at && DateTime.compare(run.expires_at, run.completed_at) == :gt,
            do: run.expires_at,
            else:
              DateTime.add(run.completed_at, Policy.retention_seconds(run.mapping.source.slug))

        Repo.update_all(
          from(d in Result, where: d.id == ^result.id and is_nil(d.source_record_revision_id)),
          set: [source_record_revision_id: revision.id]
        )

        Repo.query!(
          """
          UPDATE source_record_revisions SET
            discovery_retention_policy_sha256=CASE WHEN discovery_retain_until IS NULL OR discovery_retain_until<$2 THEN $3 ELSE discovery_retention_policy_sha256 END,
            discovery_retain_until=GREATEST(discovery_retain_until,$2),
            discovery_last_observed_at=GREATEST(discovery_last_observed_at,$4)
          WHERE id=$1
          """,
          [revision.id, expiry, run.retention_policy_sha256, run.completed_at]
        )
      end
    end)
  end

  def purge_results(ids) do
    # No outer transaction may hold a revision lock and then seek a different
    # canonical lock. Each capture commits before the subsequent sweep.
    capture_legacy(ids)
    {deleted, _} = Repo.delete_all(from d in Result, where: d.run_id in ^ids)
    {deleted, 0}
  end

  def sweep(limit, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    installed = installed?()
    policies = policies()
    %{rows: rows} = Repo.query!(plan_sql(columns(), installed, true), [now, policies, limit])

    counts =
      Enum.reduce(
        rows,
        %{deleted_revisions: 0, redacted_revisions: 0, deleted_records: 0},
        fn row, acc ->
          [revision_id, record_id, source_id, slug, digest, checksum, _held, _deadline] = row

          {:ok, delta} =
            Repo.transaction(fn ->
              canonical_lock(source_id, digest, record_id)

              Repo.query!("SELECT id FROM source_record_revisions WHERE id=$1 FOR UPDATE", [
                revision_id
              ])

              %{rows: due} =
                Repo.query!(plan_sql(columns(), installed, false) <> " AND rev.id=$3", [
                  now,
                  policies,
                  revision_id
                ])

              case due do
                [] ->
                  zero()

                [[_, _, _, _, _, _, held, deadline]] ->
                  # Bind only this canonical record before projection; no other
                  # record's advisory lock can be acquired in this transaction.
                  Repo.all(from d in Result, where: d.source_record_id == ^record_id)
                  |> Enum.filter(
                    &(DevilsDictionary.Curation.Digest.sha256(
                        &1.external_namespace <> ":" <> &1.external_id
                      ) == digest)
                  )
                  |> Enum.each(&capture_result/1)

                  if held do
                    %{num_rows: n} =
                      Repo.query!(
                        """
                        UPDATE source_record_revisions SET
                          payload=jsonb_set(discovery_retained_payload($2,payload,$3),'{_discovery_redaction,reason}',to_jsonb($4::text),true),
                          revision_key=CASE WHEN revision_key LIKE 'redacted-discovery:%' THEN revision_key ELSE 'redacted-discovery:' || id || ':' || checksum END
                        WHERE id=$1 AND payload IS DISTINCT FROM discovery_retained_payload($2,payload,$3)
                        """,
                        [
                          revision_id,
                          slug,
                          now,
                          if(is_nil(deadline),
                            do: "legacy_retention_unproven",
                            else: "retention_expired"
                          )
                        ]
                      )

                    Repo.query!(
                      """
                      UPDATE source_records sr SET
                        external_id=discovery_retained_record($2,to_jsonb(sr),$3)->>'external_id',
                        url=discovery_retained_record($2,to_jsonb(sr),$3)->>'url'
                      WHERE sr.id=$1 AND sr.content_hash=$4
                      """,
                      [record_id, slug, now, checksum]
                    )

                    %{deleted_revisions: 0, redacted_revisions: n, deleted_records: 0}
                  else
                    %{num_rows: n} =
                      Repo.query!("DELETE FROM source_record_revisions WHERE id=$1", [revision_id])

                    %{
                      deleted_revisions: n,
                      redacted_revisions: 0,
                      deleted_records: delete_orphan(record_id, true)
                    }
                  end
              end
            end)

          Map.merge(acc, delta, fn _, a, b -> a + b end)
        end
      )

    # A result may have protected an empty record until its own cache row was
    # purged on a later tick. Such records also make bounded progress.
    %{rows: orphans} = Repo.query!(orphan_sql() <> " ORDER BY rec.id LIMIT $1", [limit])

    orphan_count =
      Enum.reduce(orphans, 0, fn [id, source_id, digest], acc ->
        {:ok, n} =
          Repo.transaction(fn ->
            canonical_lock(source_id, digest, id)
            delete_orphan(id)
          end)

        acc + n
      end)

    %{rows: empty_protected} =
      Repo.query!(empty_record_projection_sql() <> " ORDER BY rec.id LIMIT $2", [now, limit])

    projected =
      Enum.reduce(empty_protected, 0, fn [id, source_id, slug, digest], acc ->
        {:ok, n} =
          Repo.transaction(fn ->
            canonical_lock(source_id, digest, id)

            case Repo.query!(empty_record_projection_sql() <> " AND rec.id=$2", [now, id]).rows do
              [] ->
                0

              _ ->
                Repo.query!(
                  "UPDATE source_records SET external_id=discovery_retained_record($2,to_jsonb(source_records),$3)->>'external_id',url=discovery_retained_record($2,to_jsonb(source_records),$3)->>'url' WHERE id=$1",
                  [id, slug, now]
                ).num_rows
            end
          end)

        acc + n
      end)

    counts
    |> Map.update!(:deleted_records, &(&1 + orphan_count))
    |> Map.put(:redacted_empty_records, projected)
  end

  def dry_run(limit \\ 500) do
    now = DateTime.utc_now()
    policy = policies()
    installed = installed?()

    %{rows: totals} =
      Repo.query!(
        plan_sql("SELECT src.slug,protection.held,count(*)", installed, false) <>
          " GROUP BY src.slug,protection.held ORDER BY src.slug",
        [now, policy]
      )

    %{rows: batch} =
      Repo.query!(
        plan_sql(
          "SELECT rev.id,rec.id,src.slug,protection.held,deadline.effective",
          installed,
          true
        ),
        [now, policy, limit]
      )

    %{rows: orphans} = Repo.query!(orphan_sql() <> " ORDER BY rec.id LIMIT $1", [limit])

    %{rows: [[orphan_total]]} =
      Repo.query!("SELECT count(*) FROM (" <> orphan_sql() <> ") empty_records")

    %{rows: record_totals} = Repo.query!(record_deletions_sql(installed, false), [now, policy])

    %{rows: record_batch} =
      Repo.query!(record_deletions_sql(installed, true), [now, policy, limit])

    cache_runs = DevilsDictionary.Discovery.retention_due(limit)
    cache_ids = Enum.map(cache_runs, & &1.id)

    cache_counts =
      Repo.all(
        from d in Result,
          join: r in Run,
          on: r.id == d.run_id,
          join: m in assoc(r, :mapping),
          join: source in assoc(m, :source),
          where: r.id in ^cache_ids,
          group_by: source.slug,
          select: %{provider: source.slug, action: "delete_result", count: count(d.id)}
      )

    %{
      total_by_provider:
        Enum.map(totals, fn [slug, held, n] ->
          %{
            provider: slug,
            action: if(held, do: :redact_revision, else: :delete_revision),
            count: n
          }
        end),
      next_batch:
        Enum.map(batch, fn [revision, record, slug, held, deadline] ->
          %{
            revision_id: revision,
            record_id: record,
            provider: slug,
            action: if(held, do: :redact_revision, else: :delete_revision),
            deadline: deadline
          }
        end),
      total_record_deletions_by_provider:
        Enum.map(record_totals, fn [slug, n] -> %{provider: slug, count: n} end),
      next_record_deletions:
        Enum.map(record_batch, fn [slug, n] -> %{provider: slug, count: n} end),
      next_result_pruning: cache_counts,
      empty_record_projection_batch:
        Repo.query!(empty_record_projection_sql() <> " ORDER BY rec.id LIMIT $2", [now, limit]).rows
        |> Enum.map(&hd/1),
      orphan_record_batch: Enum.map(orphans, fn [id, _, _] -> id end),
      orphan_record_total: orphan_total,
      limit: limit,
      legacy_resolution: :read_only_exact_matches
    }
  end

  # Count entire records only when every revision is in this deletion plan and
  # every remaining cache row is due. Native or referenced revisions prevent it.
  defp record_deletions_sql(installed, limited) do
    selected =
      plan_sql("SELECT rev.id,rec.id AS record_id,src.slug,protection.held", installed, limited)

    cache_limit = if limited, do: " LIMIT $3", else: ""

    """
    WITH planned AS (#{selected}), cache_due AS (
      SELECT r.id FROM discovery_runs r JOIN discovery_mappings m ON m.id=r.mapping_id JOIN sources s ON s.id=m.source_id
      WHERE r.status='succeeded' AND (r.display_allowed OR EXISTS(SELECT 1 FROM discovery_results d WHERE d.run_id=r.id))
      AND CASE WHEN r.expires_at>r.completed_at THEN LEAST(r.expires_at,r.completed_at+(($2::jsonb->>s.slug)::bigint*interval '1 second')) ELSE r.completed_at+(($2::jsonb->>s.slug)::bigint*interval '1 second') END <= $1
      ORDER BY CASE WHEN r.expires_at>r.completed_at THEN LEAST(r.expires_at,r.completed_at+(($2::jsonb->>s.slug)::bigint*interval '1 second')) ELSE r.completed_at+(($2::jsonb->>s.slug)::bigint*interval '1 second') END,r.id #{cache_limit}
    ), deletable AS (
      SELECT DISTINCT p.record_id,p.slug FROM planned p WHERE NOT p.held
      AND NOT EXISTS(SELECT 1 FROM source_record_revisions existing WHERE existing.source_record_id=p.record_id AND existing.id NOT IN (SELECT id FROM planned WHERE NOT held))
      AND NOT EXISTS(SELECT 1 FROM discovery_results d WHERE d.source_record_id=p.record_id AND d.run_id NOT IN (SELECT id FROM cache_due))
    ) SELECT slug,count(*) FROM deletable GROUP BY slug ORDER BY slug
    """
  end

  defp zero, do: %{deleted_revisions: 0, redacted_revisions: 0, deleted_records: 0}

  defp installed? do
    %{rows: [[present]]} =
      Repo.query!("SELECT to_regclass('curation_shelf_citations') IS NOT NULL")

    present
  end

  defp policies,
    do:
      Map.new(
        DevilsDictionary.Discovery.Providers.all(),
        &{&1.slug(), Policy.retention_seconds(&1.slug())}
      )

  defp columns,
    do:
      "SELECT rev.id,rec.id,src.id,src.slug,#{digest_sql()},rev.checksum,protection.held,deadline.effective"

  defp canonical_lock(source_id, digest, record_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
      "discovery:#{source_id}:#{digest}"
    ])

    Repo.query!("SELECT id FROM source_records WHERE id=$1 FOR UPDATE", [record_id])
  end

  defp digest_sql,
    do:
      "CASE WHEN rec.external_id LIKE 'redacted-discovery:%' THEN substring(rec.external_id from 20) ELSE encode(sha256(convert_to(rec.external_id,'UTF8')),'hex') END"

  defp protected_sql(installed) do
    revisions = @revision_guards ++ if(installed, do: ["curation_shelf_citations"], else: [])

    Enum.map_join(
      @record_guards,
      " OR ",
      &"EXISTS(SELECT 1 FROM #{&1} WHERE source_record_id=rec.id)"
    ) <>
      " OR " <>
      Enum.map_join(
        revisions,
        " OR ",
        &"EXISTS(SELECT 1 FROM #{&1} WHERE source_record_revision_id=rev.id)"
      )
  end

  defp empty_record_projection_sql do
    # A deleted revision is no permission to keep its orphaned provider URL.
    # Scope stays restricted to recognized discovery keys, not native records.
    """
    SELECT rec.id,src.id,src.slug,#{digest_sql()} FROM source_records rec JOIN sources src ON src.id=rec.source_id
    WHERE src.slug IN ('guardian','bing-news','spotify','pexels','unsplash','openverse','cinegraph')
    AND rec.external_id LIKE ANY(ARRAY['guardian_article:%','news_article:%','spotify_track:%','pexels_photo:%','unsplash_photo:%','openverse_media:%','tmdb_movie:%','redacted-discovery:%'])
    AND NOT EXISTS(SELECT 1 FROM source_record_revisions WHERE source_record_id=rec.id)
    AND to_jsonb(rec) IS DISTINCT FROM (CASE WHEN src.slug='cinegraph' THEN to_jsonb(rec)||jsonb_build_object('url',NULL) ELSE to_jsonb(rec)||jsonb_build_object('url',NULL,'external_id',CASE WHEN rec.external_id LIKE 'redacted-discovery:%' THEN rec.external_id ELSE 'redacted-discovery:'||encode(sha256(convert_to(rec.external_id,'UTF8')),'hex') END) END)
    AND $1::timestamptz IS NOT NULL
    """
  end

  defp orphan_sql(known_discovery \\ false) do
    guards =
      Enum.map_join(
        @record_guards,
        " OR ",
        &"EXISTS(SELECT 1 FROM #{&1} WHERE source_record_id=rec.id)"
      )

    citation_guard =
      if installed?(),
        do: " OR EXISTS(SELECT 1 FROM curation_shelf_citations WHERE source_record_id=rec.id)",
        else: ""

    "SELECT rec.id,rec.source_id,#{digest_sql()} FROM source_records rec JOIN sources src ON src.id=rec.source_id WHERE #{if known_discovery, do: "true", else: "src.slug IN ('guardian','bing-news','spotify','pexels','unsplash','openverse','commons','met','cinegraph','open-library','poetrydb','wikiquote') AND rec.external_id LIKE ANY(ARRAY['guardian_article:%','news_article:%','spotify_track:%','pexels_photo:%','unsplash_photo:%','openverse_media:%','commons_file:%','met_object:%','tmdb_movie:%','olid:%','poetrydb_poem:%','wikiquote_item:%','redacted-discovery:%'])"} AND NOT EXISTS(SELECT 1 FROM source_record_revisions WHERE source_record_id=rec.id) AND NOT EXISTS(SELECT 1 FROM discovery_results WHERE source_record_id=rec.id) AND NOT (#{guards}#{citation_guard})"
  end

  defp delete_orphan(id, known_discovery \\ false) do
    %{rows: eligible} = Repo.query!(orphan_sql(known_discovery) <> " AND rec.id=$1", [id])

    if eligible == [],
      do: 0,
      else: Repo.query!("DELETE FROM source_records WHERE id=$1", [id]).num_rows
  end

  # Same pure retained-field expression as the migration projection. It works
  # before the migration exists and makes terminal filtering occur before LIMIT.
  defp retained_base do
    """
    CASE WHEN src.slug IN ('commons','met','poetrydb','wikiquote') THEN rev.payload-'_discovery_redaction'
    WHEN src.slug='cinegraph' THEN jsonb_build_object('external_namespace',rev.payload->'external_namespace','external_id',rev.payload->'external_id','identifiers',COALESCE(rev.payload->'identifiers','[]'::jsonb))
    WHEN src.slug='open-library' THEN jsonb_build_object('external_namespace',rev.payload->'external_namespace','external_id',rev.payload->'external_id','identifiers',COALESCE(rev.payload->'identifiers','[]'::jsonb),'preview_metadata',(SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) FROM jsonb_each(COALESCE(rev.payload->'preview_metadata','{}')) WHERE key=ANY(ARRAY['title','year','author','author_keys','olid','ia','source_url','read_url','cover_url'])))
    ELSE jsonb_build_object('external_namespace',rev.payload->'external_namespace','external_ref_sha256',COALESCE(rev.payload->>'external_ref_sha256',encode(sha256(convert_to((rev.payload->>'external_namespace') || ':' || (rev.payload->>'external_id'),'UTF8')),'hex'))) END
    """
  end

  defp plan_sql(select, installed, limited) do
    match = """
    rev.payload->'match_details'=d.match_details AND rev.payload->'preview_metadata'=(d.preview_metadata-'creators')
    AND rev.payload->>'external_namespace'=d.external_namespace AND rev.payload->>'external_id'=d.external_id
    """

    unique = """
    (SELECT count(*) FROM source_record_revisions exact WHERE exact.source_record_id=rec.id
      AND exact.payload->'match_details'=d.match_details AND exact.payload->'preview_metadata'=(d.preview_metadata-'creators')
      AND exact.payload->>'external_namespace'=d.external_namespace AND exact.payload->>'external_id'=d.external_id)=1
    """

    base = """
    #{select} FROM source_record_revisions rev JOIN source_records rec ON rec.id=rev.source_record_id JOIN sources src ON src.id=rec.source_id
    LEFT JOIN LATERAL (
      SELECT max(CASE WHEN r.expires_at>r.completed_at THEN r.expires_at ELSE r.completed_at+(($2::jsonb->>src.slug)::bigint*interval '1 second') END) AS expires,
             max(r.completed_at) AS observed
      FROM discovery_results d JOIN discovery_runs r ON r.id=d.run_id
      WHERE d.source_record_id=rec.id AND r.status='succeeded'
      AND ((to_jsonb(d)->>'source_record_revision_id')::bigint=rev.id OR
        ((to_jsonb(d)->>'source_record_revision_id') IS NULL AND #{match} AND #{unique}))
    ) observation ON true
    CROSS JOIN LATERAL (SELECT CASE WHEN GREATEST((to_jsonb(rev)->>'discovery_last_observed_at')::timestamptz,observation.observed) IS NULL THEN NULL ELSE
      LEAST(GREATEST((to_jsonb(rev)->>'discovery_retain_until')::timestamptz,observation.expires),
        GREATEST((to_jsonb(rev)->>'discovery_last_observed_at')::timestamptz,observation.observed)+(($2::jsonb->>src.slug)::bigint*interval '1 second')) END AS effective) deadline
    CROSS JOIN LATERAL (SELECT (#{protected_sql(installed)}) AS held) protection
    WHERE (rev.payload ?& ARRAY['external_namespace','external_id','preview_metadata','match_details'] OR rev.payload ? '_discovery_redaction') AND ($2::jsonb ? src.slug)
      AND (deadline.effective IS NULL OR deadline.effective <= $1)
      AND (NOT protection.held OR (rev.payload-'_discovery_redaction') IS DISTINCT FROM (#{retained_base()}))
    """

    if limited, do: base <> " ORDER BY deadline.effective NULLS FIRST,rev.id LIMIT $3", else: base
  end
end
