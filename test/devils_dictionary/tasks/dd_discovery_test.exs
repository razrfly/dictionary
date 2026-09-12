defmodule DevilsDictionary.Tasks.DdDiscoveryTest do
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import ExUnit.CaptureIO

  alias DevilsDictionary.Discovery.{Mapping, Run}
  alias DevilsDictionary.Repo

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    %{sources: catalog.sources, animals: catalog.scopes["animals"]}
  end

  test "dry-run selects real source definitions deterministically and writes nothing", ctx do
    first = definition!(ctx, "alpha", "bierce")
    second = definition!(ctx, "beta", "bierce")
    _third = definition!(ctx, "gamma", "bierce")
    _other_source = definition!(ctx, "johnson-only", "johnson")

    output = run_task(~w(--definition-source bierce --providers cinegraph --limit 2 --dry-run))

    assert output =~ "Selected 2/2 targets defined by bierce"
    assert output =~ "#{first.object_id}\talpha\ten"
    assert output =~ "#{second.object_id}\tbeta\ten"
    assert output =~ "Dry run: no writes, jobs or external requests"
    assert Repo.aggregate(Mapping, :count) == 0
    assert Repo.aggregate(Run, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "resume checkpoint applies before the SQL limit", ctx do
    first = definition!(ctx, "alpha", "johnson")
    second = definition!(ctx, "beta", "johnson")
    third = definition!(ctx, "gamma", "johnson")

    output =
      run_task([
        "--definition-source",
        "johnson",
        "--providers",
        "all",
        "--limit",
        "1",
        "--after",
        Integer.to_string(first.object_id),
        "--dry-run"
      ])

    assert output =~ "#{second.object_id}\tbeta\ten"
    refute output =~ "#{third.object_id}\tgamma\ten"
    assert output =~ "Resume after this batch with --after #{second.object_id}"
  end

  test "unsupported providers are reported as skipped without writes", ctx do
    _word = definition!(ctx, "alpha", "bierce")

    output = run_task(~w(--definition-source bierce --providers future-provider --dry-run))

    assert output =~ "Skipped provider future-provider: unsupported"
    assert output =~ "0 eligible providers"
    assert Repo.aggregate(Mapping, :count) == 0
  end

  test "normal mode invokes the shared admission service and reports queued honestly", ctx do
    word = definition!(ctx, "alpha", "bierce")

    output =
      run_task(~w(--definition-source bierce --providers cinegraph --limit 1 --wait-ms 0))

    assert output =~ "queued: 1/1"
    assert output =~ "succeeded_nonempty: 0/1"
    assert Repo.one!(Mapping).target_object_id == word.object_id
    assert Repo.aggregate(Run, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "a missing catalog is an explicit diagnostic", _ctx do
    assert_raise Mix.Error, ~r/is not registered/, fn ->
      run_task(~w(--definition-source missing --providers cinegraph --dry-run))
    end
  end

  defp definition!(ctx, term, source) do
    word = word!(ctx, term, [source])
    entry!(ctx, word, source, body: "definition of #{term}")
    word
  end

  defp run_task(args) do
    capture_io(fn ->
      Mix.Task.reenable("dd.discovery")
      Mix.Tasks.Dd.Discovery.run(args)
    end)
  end
end
