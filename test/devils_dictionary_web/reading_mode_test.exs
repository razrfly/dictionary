defmodule DevilsDictionaryWeb.ReadingModeTest do
  @moduledoc """
  Where internal reading comes from (#219 B1, and the 28 September
  re-audit's first correction): trusted configuration, or an authenticated
  internal contributor or reviewer read from the database — never a request.
  The configuration that turns it on for every reader is development's and
  test's alone; production must not carry it.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures, only: [reading: 2]

  alias DevilsDictionary.CurationFixtures
  alias DevilsDictionaryWeb.ReadingMode

  @root Path.expand("../../config", __DIR__)

  test "production configuration never turns internal reading on" do
    for file <- ~w(config.exs prod.exs runtime.exs) do
      refute @root |> Path.join(file) |> File.read!() =~ "internal_reading",
             "#{file} must not configure internal reading"
    end

    # Development and test do, deliberately.
    for file <- ~w(dev.exs test.exs) do
      assert @root |> Path.join(file) |> File.read!() =~
               "config :devils_dictionary, :internal_reading, true"
    end
  end

  test "configuration decides for everyone; without it, only an internal contributor reads internally" do
    reading(true, fn ->
      assert ReadingMode.mode(nil) == :internal
    end)

    reading(false, fn ->
      assert ReadingMode.mode(nil) == :public
      assert ReadingMode.mode(CurationFixtures.account([])) == :public
      assert ReadingMode.mode(CurationFixtures.account([:contributor])) == :internal
      assert ReadingMode.mode(CurationFixtures.account([:reviewer])) == :internal
    end)
  end

  test "a revoked role is read from the database, not from the session's copy" do
    reading(false, fn ->
      scope = CurationFixtures.account([:contributor])
      assert ReadingMode.mode(scope) == :internal

      scope.user |> Ecto.Changeset.change(internal_contributor: false) |> Repo.update!()
      assert ReadingMode.mode(scope) == :public
    end)
  end
end
