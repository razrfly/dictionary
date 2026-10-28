defmodule DevilsDictionary.Installation.CitationPreMigrationTest do
  use DevilsDictionary.DataCase, async: false
  alias DevilsDictionary.{Repo, Fixtures}
  alias DevilsDictionary.Curation.{Digest, DiscoveryRetention}
  alias DevilsDictionary.Routing.Recovery
  @moduletag :unboxed
  @moduletag timeout: 300_000
  test "the sitting3 dry run works read-only on the deployed #264 schema" do
    name = Repo.config()[:database] <> "_c270_pre"
    config = Keyword.put(Repo.config(), :database, name)
    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

    Recovery.with_database(name, fn ->
      Ecto.Migrator.run(Repo, Ecto.Migrator.migrations_path(Repo), :up,
        to: 20_261_027_175_309,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      Fixtures.seed_catalog!()
      source = DevilsDictionary.Sources.get_source_by_slug("guardian")
      now = DateTime.utc_now()

      raw = %{
        "external_namespace" => "guardian_article",
        "external_id" => "legacy-fixture",
        "preview_metadata" => %{"title" => "An expired legacy fixture headline"},
        "match_details" => %{},
        "identifiers" => []
      }

      checksum = Digest.term(raw)

      %{rows: [[record]]} =
        Repo.query!(
          "INSERT INTO source_records(source_id,external_id,url,content_hash,fetched_at,changed_at,inserted_at,updated_at) VALUES($1,'guardian_article:legacy-fixture','https://example.test/legacy',$2,$3,$3,$3,$3) RETURNING id",
          [source.id, checksum, now]
        )

      Repo.query!(
        "INSERT INTO source_record_revisions(source_record_id,revision_key,checksum,payload,observed_at,inserted_at,updated_at) VALUES($1,$2,$2,$3,$4,$4,$4)",
        [record, checksum, raw, now]
      )

      assert %{rows: [[false]]} =
               Repo.query!("SELECT to_regclass('curation_shelf_citations') IS NOT NULL")

      assert {:ok, plan} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION READ ONLY")
                 DiscoveryRetention.dry_run(1)
               end)

      assert [%{provider: "guardian", action: :delete_revision, count: 1}] =
               plan.total_by_provider

      assert [%{provider: "guardian", count: 1}] = plan.next_record_deletions
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM source_record_revisions")
    end)
  end
end
