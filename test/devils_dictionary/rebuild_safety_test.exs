defmodule DevilsDictionary.RebuildSafetyTest do
  use DevilsDictionary.DataCase, async: false

  test "force cannot reset a different configured database" do
    configured = DevilsDictionary.Repo.config()[:database]
    other = configured <> "_not_selected"

    assert_raise Mix.Error, ~r/--force cannot override a database mismatch/, fn ->
      Mix.Tasks.Dd.Reset.run(["--database", other, "--force", other])
    end

    assert %{rows: [[1]]} = DevilsDictionary.Repo.query!("SELECT 1")
  end
end
