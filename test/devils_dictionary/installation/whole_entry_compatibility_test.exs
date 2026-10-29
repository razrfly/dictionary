defmodule DevilsDictionary.Installation.WholeEntryCompatibilityTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.RefreshFixtures
  alias DevilsDictionary.{Repo, Fixtures}
  alias DevilsDictionary.Routing.Recovery
  alias DevilsDictionary.Curation.{Receipt, Published}
  @moduletag :unboxed
  @moduletag timeout: 300_000
  test "v34 manual records survive whole-entry up/down/up before activation" do
    name = Repo.config()[:database] <> "_whole_pre"
    config = Keyword.put(Repo.config(), :database, name)
    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

    Recovery.with_database(name, fn ->
      path = Ecto.Migrator.migrations_path(Repo)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_142_135,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      Fixtures.seed_catalog!()
      w = love_world!()
      c = provision!(w)
      first = publish!(w, c)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_180_802,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Published.current(c.id)
      assert {:ok, receipt} = Receipt.read("love", first.version.version)
      assert receipt.publication.authority_kind == :operator
      second = publish!(w, c, first.version.id, highlights: [])
      assert {:ok, _} = Receipt.read("love", second.version.version)

      Ecto.Migrator.run(Repo, path, :down,
        step: 1,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Published.current(c.id)

      Ecto.Migrator.run(Repo, path, :up,
        to: 20_261_029_180_802,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)
    end)
  end
end
