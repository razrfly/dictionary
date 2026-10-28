defmodule DevilsDictionary.Installation.CitationBundleTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.Installation.{Bundle, Bootstrap, Manifest}
  alias DevilsDictionary.Curation.ShelfCitations
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery
  @moduletag :unboxed
  @moduletag timeout: 300_000

  test "dd.bundle/2 removes live provider text, preserves citation FKs and restores projected state" do
    world = editor_world!()
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    deleted = observation!(world, "guardian", external_id: "deleted-cited-payload")

    assert {:ok, deleted_citation} =
             ShelfCitations.cite(deleted.spec, %{
               composition_id: world.composition.id,
               actor_id: deleted.actor.id
             })

    Repo.query!("DELETE FROM source_record_revisions WHERE id=$1", [deleted.revision.id])

    unreferenced = observation!(world, "guardian", external_id: "uncited-cache-only")

    native =
      DevilsDictionary.Sources.ensure_revision(o.record, "native-fixture-revision", %{
        "native" => "durable native provenance"
      })

    native_entry = DevilsDictionary.Registry.current_content_revision(world.johnson.object_id)

    Repo.query!("UPDATE content_revisions SET source_record_revision_id=$1 WHERE id=$2", [
      native.id,
      native_entry.id
    ])

    name = Repo.config()[:database]
    target = name <> "_c270restore"
    config = Keyword.put(Repo.config(), :database, target)
    dir = Path.join(System.tmp_dir!(), "c270-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      for db <- [target, Bootstrap.staging_name(target)],
          do: Ecto.Adapters.Postgres.storage_down(Keyword.put(config, :database, db))

      File.rm_rf!(dir)
    end)

    probe = fn _ ->
      {:ok, %{mounted: true, external: true, device: "/dev/fixture", uuid: "C270-FIXTURE"}}
    end

    assert {:ok, %{manifest: manifest, digest: digest, path: bundle}} =
             Bundle.create(
               source: name,
               out: Path.join(dir, "bundle"),
               volume: dir,
               inputs: false,
               probe: probe,
               require_quiet: false
             )

    assert manifest["format"] == "dd.bundle/2"
    assert manifest["projection"]["row_counts"]["source_record_revisions"] > 0
    assert {:ok, _} = Bundle.verify(bundle)
    dump = Path.join(bundle, Manifest.file(manifest, "dump")["path"])

    {sql, 0} =
      System.cmd(System.find_executable("pg_restore"), ["--data-only", "--file=-", dump],
        stderr_to_stdout: true
      )

    copies =
      Enum.map_join(
        ~w(source_records source_record_revisions),
        &File.read!(Path.join(bundle, Manifest.file(manifest, "projected_" <> &1)["path"]))
      )

    refute sql <> copies =~ o.raw["preview_metadata"]["title"]
    refute sql <> copies =~ "A distinctive discovery snippet for this fixture."
    refute sql <> copies =~ deleted.record.url
    refute copies =~ deleted.record.external_id

    assert {:ok, %{outcome: :restored}} =
             Bootstrap.run(:init, bundle: bundle, target: target, expect_manifest_sha256: digest)

    Recovery.with_database(target, fn ->
      gone = Repo.get!(DevilsDictionary.Curation.ShelfCitation, deleted_citation.id)
      assert gone.source_record_revision_id == nil
      assert gone.cited_revision_id == deleted.revision.id
      record = Repo.get!(DevilsDictionary.Sources.SourceRecord, gone.source_record_id)
      assert record.url == nil and record.external_id == "redacted-discovery:" <> deleted.digest

      restored = Repo.get!(DevilsDictionary.Curation.ShelfCitation, c.id)
      assert restored.cited_revision_id == o.revision.id
      assert restored.source_record_revision_id == o.revision.id

      %{rows: [[payload]]} =
        Repo.query!("SELECT payload FROM source_record_revisions WHERE id=$1", [o.revision.id])

      refute payload["preview_metadata"]
      assert payload["_discovery_redaction"]
      assert Repo.aggregate(DevilsDictionary.Discovery.Result, :count) == 0
    end)

    Recovery.with_database(target, fn ->
      assert Repo.get(DevilsDictionary.Sources.SourceRecord, unreferenced.record.id) == nil

      assert Repo.get!(DevilsDictionary.Registry.ContentRevision, native_entry.id).source_record_revision_id ==
               native.id

      %{rows: [[payload]]} =
        Repo.query!("SELECT payload FROM source_record_revisions WHERE id=$1", [native.id])

      assert payload == %{"native" => "durable native provenance"}
    end)

    # A second verification recognizes precisely the projected state.
    assert {:ok, %{outcome: :already_restored}} =
             Bootstrap.run(:init, bundle: bundle, target: target, expect_manifest_sha256: digest)

    Recovery.with_database(target, fn ->
      source = Repo.get!(DevilsDictionary.Sources.Source, o.source.id)

      assert {:ok, refetched} =
               DevilsDictionary.Sources.upsert_record(source, %{
                 external_id: o.result.external_namespace <> ":" <> o.result.external_id,
                 url: o.record.url,
                 raw: o.raw
               })

      assert refetched.id == o.record.id
      assert refetched.current_revision.id != o.revision.id
      assert DevilsDictionary.Sources.raw(refetched) == o.raw

      assert ShelfCitations.check(Repo.get!(DevilsDictionary.Curation.ShelfCitation, c.id)) ==
               :payload_redacted
    end)
  end
end
