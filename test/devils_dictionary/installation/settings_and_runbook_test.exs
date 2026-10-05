defmodule DevilsDictionary.Installation.SettingsAndRunbookTest do
  @moduledoc """
  Two things that must agree with what they describe:

    * a stored list setting splits as PostgreSQL's `SplitGUCList` splits it,
      so `Database.apply_properties!/3` gives it back element by element, as
      pg_dump does — and an ordinary setting stays one literal;
    * the runbook states the restore's last two steps in the order the code
      takes them: renamed into place first, commented after (a run
      interrupted between them is finished by the next one).
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Installation.Database

  describe "list settings" do
    test "elements, quoted elements and doubled quotes" do
      assert Database.list_elements(~s|"$user", public|) == {:ok, ["$user", "public"]}
      assert Database.list_elements(~s|a,b ,  c|) == {:ok, ["a", "b", "c"]}
      assert Database.list_elements(~s|"Odd ""Schema""", x|) == {:ok, [~s|Odd "Schema"|, "x"]}
      assert Database.list_elements(~s|""|) == {:ok, [""]}
    end

    test "what it cannot parse is refused, not guessed" do
      assert Database.list_elements(~s|"unterminated|) == :error
      assert Database.list_elements(~s|a b|) == :error
      assert Database.list_elements("") == :error
      assert_raise ArgumentError, fn -> Database.setting_values("search_path", ~s|"x|) end
    end

    test "only the quoted-list settings are split" do
      assert Database.setting_values("search_path", ~s|"$user", public|) == ["$user", "public"]
      assert Database.setting_values("Search_Path", "a, b") == ["a", "b"]
      assert Database.setting_values("DateStyle", "ISO, MDY") == ["ISO, MDY"]
      assert Database.setting_values("TimeZone", "Etc/UTC") == ["Etc/UTC"]
    end
  end

  test "the runbook renames before it comments, as the code does" do
    runbook = File.read!("docs/operations/installation.md")

    [_, section] = String.split(runbook, "## How a restore runs, and how it resumes", parts: 2)
    [steps | _] = String.split(section, "\n## ", parts: 2)

    renamed = :binary.match(steps, "**renamed** to the target")
    commented = :binary.match(steps, "given the recorded comment")

    assert renamed != :nomatch and commented != :nomatch
    assert elem(renamed, 0) < elem(commented, 0)
    refute steps =~ "is the comment set and the staging database"

    # In the restore itself (the resume branch only comments).
    [_, restore] =
      "lib/devils_dictionary/installation/bootstrap.ex"
      |> File.read!()
      |> String.split("  defp restore(", parts: 2)

    [restore | _] = String.split(restore, "\n  defp ", parts: 2)
    rename = :binary.match(restore, "Database.rename!(config, staging, config[:database])")

    comment =
      :binary.match(
        restore,
        ~s|Database.set_comment!(config, config[:database], manifest["database"]["comment"])|
      )

    assert rename != :nomatch and comment != :nomatch
    assert elem(rename, 0) < elem(comment, 0)
  end
end
