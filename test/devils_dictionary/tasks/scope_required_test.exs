defmodule Mix.Tasks.ScopeRequiredTest do
  @moduledoc """
  #77 §2: *"Missing selection must not accidentally initiate an unbounded
  network import."*

  Four tasks defaulted `--scope` to `animals`. Three of them are read-only, so a
  forgotten flag only produced the wrong numbers quietly. The fourth is
  `dd.rebuild`, a sixteen-stage pipeline whose Wikidata and Wikipedia stages go
  to the API for hours when `--live` is passed or the replay archives are
  missing. A forgotten flag is not consent to that.

  All four now refuse. The refusal names the populations that exist, because the
  point is to make choosing easy, not to punish.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Sources.ImportRun

  setup do
    Fixtures.seed_catalog!()
    :ok
  end

  @tasks [
    {Mix.Tasks.Dd.Health, "dd.health"},
    {Mix.Tasks.Dd.Link, "dd.link"},
    {Mix.Tasks.Dd.Score, "dd.score"},
    {Mix.Tasks.Dd.Rebuild, "dd.rebuild"}
  ]

  test "every one of them refuses, and says what it could have been given" do
    for {task, name} <- @tasks do
      error = assert_raise Mix.Error, fn -> task.run([]) end

      assert error.message =~ "mix #{name} requires --scope"
      assert error.message =~ "animals, culture, emotions"
    end
  end

  test "and an unknown population is a lookup failure, not a fallback" do
    for {task, _name} <- @tasks -- [{Mix.Tasks.Dd.Rebuild, "dd.rebuild"}] do
      assert_raise Ecto.NoResultsError, fn -> task.run(["--scope", "nosuch"]) end
    end
  end

  # The refusal happens before `plan/1`, so a bare `mix dd.rebuild` builds no
  # plan, opens no run and writes nothing — rather than starting stage 1 and
  # discovering the problem at stage 8.
  test "dd.rebuild refuses before it has run anything" do
    assert Repo.aggregate(ImportRun, :count) == 0

    assert_raise Mix.Error, fn -> Mix.Tasks.Dd.Rebuild.run([]) end

    assert Repo.aggregate(ImportRun, :count) == 0
  end

  # The one that already did the right thing, kept honest: `nil` means unscoped
  # there, deliberately, and that is not the same defect.
  test "dd.absorb still treats a missing scope as unscoped, not as animals" do
    source = File.read!("lib/mix/tasks/dd.absorb.ex")

    assert source =~ ~S{scope = opts[:scope] && Lexicon.get_scope_by_slug!(opts[:scope])}
    refute source =~ ~S{opts[:scope] || "animals"}
  end
end
