defmodule DevilsDictionary.Installation.SingleEditorCompatibilityTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.RefreshFixtures
  alias DevilsDictionary.{Repo, Fixtures}
  alias DevilsDictionary.Routing.Recovery
  alias DevilsDictionary.Curation.{Receipt, Published}
  @moduletag :unboxed
  @moduletag timeout: 300_000

  test "migration preserves old manual receipts and supports safe down/up before agent history" do
    name = Repo.config()[:database] <> "_authority_pre"
    config = Keyword.put(Repo.config(), :database, name)
    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

    Recovery.with_database(name, fn ->
      path = Ecto.Migrator.migrations_path(Repo)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_020_011,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      Fixtures.seed_catalog!()
      world = love_world!()
      composition = provision!(world)
      first = publish!(world, composition)
      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_142_135,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Published.current(composition.id)
      assert {:ok, receipt} = Receipt.read("love", first.version.version)
      assert receipt.publication.authority_kind == :operator
      assert receipt.review_actor
      second = publish!(world, composition, first.version.id, highlights: [])
      assert {:ok, _} = Receipt.read("love", second.version.version)

      Ecto.Migrator.run(Repo, path, :down,
        step: 1,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Published.current(composition.id)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_142_135,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM editorial_composition_publications WHERE authority_kind <> 'operator'"
               )
    end)
  end
end
