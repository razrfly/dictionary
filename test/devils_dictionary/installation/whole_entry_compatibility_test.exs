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
      # New instruction admission is additive to the already-deployed v35 schema.
      latest = 20_261_029_192_744

      Ecto.Migrator.run(Repo, path, :up,
        to: latest,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :down,
        step: 1,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :up,
        to: latest,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v2",
          output_contract_version: "selection-output-v3"
        })

      assert_raise Postgrex.Error, ~r/revised instruction history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, config.id).instruction_version ==
               "voltaire-whole-entry-v2"

      section_version = 20_261_029_194_235

      Ecto.Migrator.run(Repo, path, :up,
        to: section_version,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :down,
        step: 1,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :up,
        to: section_version,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      new_config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v3",
          output_contract_version: "selection-output-v4"
        })

      assert_raise Postgrex.Error, ~r/section contract history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, new_config.id).instruction_version ==
               "voltaire-whole-entry-v3"

      relevance_version = 20_261_029_203_115

      Ecto.Migrator.run(Repo, path, :up,
        to: relevance_version,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :down,
        step: 1,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      assert {:ok, _} = Receipt.read("love", first.version.version)

      Ecto.Migrator.run(Repo, path, :up,
        to: relevance_version,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )

      relevance_config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v4",
          output_contract_version: "selection-output-v4"
        })

      assert_raise Postgrex.Error, ~r/relevance instruction history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, relevance_config.id).instruction_version ==
               "voltaire-whole-entry-v4"

      selection_version = 20_261_029_211_308

      for direction <- [:up, :down, :up] do
        opts = if direction == :up, do: [to: selection_version], else: [step: 1]

        Ecto.Migrator.run(
          Repo,
          path,
          direction,
          opts ++ [dynamic_repo: Repo.get_dynamic_repo(), log: false]
        )

        assert {:ok, _} = Receipt.read("love", first.version.version)
        assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, relevance_config.id)
      end

      selection_config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v5",
          output_contract_version: "selection-output-v4"
        })

      assert_raise Postgrex.Error, ~r/selection instruction history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, selection_config.id)
      sense_lead_version = 20_261_101_000_313

      for direction <- [:up, :down, :up] do
        opts = if direction == :up, do: [to: sense_lead_version], else: [step: 1]

        Ecto.Migrator.run(
          Repo,
          path,
          direction,
          opts ++ [dynamic_repo: Repo.get_dynamic_repo(), log: false]
        )

        assert {:ok, _} = Receipt.read("love", first.version.version)
        assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, selection_config.id)
      end

      sense_config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v6",
          output_contract_version: "selection-output-v4"
        })

      assert_raise Postgrex.Error, ~r/sense-lead instruction history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, sense_config.id)
      grounded_version = 20_261_101_170_541

      for direction <- [:up, :down, :up] do
        opts = if direction == :up, do: [to: grounded_version], else: [step: 1]

        Ecto.Migrator.run(
          Repo,
          path,
          direction,
          opts ++ [dynamic_repo: Repo.get_dynamic_repo(), log: false]
        )

        assert {:ok, _} = Receipt.read("love", first.version.version)
        assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, sense_config.id)
      end

      grounded_config =
        DevilsDictionary.RuntimeFixtures.model_config!(%{
          instruction_version: "voltaire-whole-entry-v7",
          output_contract_version: "selection-output-v4"
        })

      assert_raise Postgrex.Error, ~r/grounded instruction history exists/, fn ->
        Ecto.Migrator.run(Repo, path, :down,
          step: 1,
          dynamic_repo: Repo.get_dynamic_repo(),
          log: false
        )
      end

      assert Repo.get!(DevilsDictionary.Curation.Runtime.ModelConfig, grounded_config.id)
    end)
  end
end
