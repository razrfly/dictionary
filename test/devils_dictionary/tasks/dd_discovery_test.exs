defmodule DevilsDictionary.Tasks.DdDiscoveryTest do
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query
  import ExUnit.CaptureIO

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, Run}
  alias DevilsDictionary.Discovery.Providers.CineGraph
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
    assert output =~ "Next selection checkpoint preview: --after #{second.object_id}"
    assert output =~ "Dry-run did not complete this batch"
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
    assert output =~ "Batch incomplete. Retry unfinished work with --resume #{word.object_id}"
    assert output =~ "Do not advance to --after #{word.object_id}"
    assert Repo.one!(Mapping).target_object_id == word.object_id
    assert Repo.aggregate(Run, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "a missing catalog is an explicit diagnostic", _ctx do
    assert_raise Mix.Error, ~r/is not registered/, fn ->
      run_task(~w(--definition-source missing --providers cinegraph --dry-run))
    end
  end

  test "resume retries exact unfinished identities and rejects stale ones", ctx do
    first = definition!(ctx, "first", "bierce")
    _second = definition!(ctx, "second", "bierce")

    output =
      run_task([
        "--definition-source",
        "bierce",
        "--providers",
        "cinegraph",
        "--resume",
        Integer.to_string(first.object_id),
        "--dry-run"
      ])

    assert output =~ "#{first.object_id}\tfirst\ten"
    refute output =~ "\tsecond\t"

    assert_raise Mix.Error, ~r/missing, retired or no longer defined/, fn ->
      run_task(~w(--definition-source bierce --providers cinegraph --resume 999999999 --dry-run))
    end
  end

  test "an early deferral is resumed before the selection checkpoint advances", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.merge(original, queue_cap: 1, refresh_cooldown_seconds: 0)
    )

    first = definition!(ctx, "resume-first", "bierce")
    second = definition!(ctx, "resume-second", "bierce")

    Req.Test.stub(CineGraph, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => %{"searchMovieKeywords" => []}}))
    end)

    initial =
      run_task(~w(--definition-source bierce --providers cinegraph --limit 2 --wait-ms 0))

    assert initial =~ "Batch incomplete"
    assert initial =~ "--resume #{first.object_id},#{second.object_id}"
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)

    resumed =
      run_task([
        "--definition-source",
        "bierce",
        "--providers",
        "cinegraph",
        "--resume",
        "#{first.object_id},#{second.object_id}",
        "--wait-ms",
        "0"
      ])

    assert resumed =~ "fresh_cache_empty: 1/2"
    assert resumed =~ "Batch incomplete"
    assert resumed =~ "--resume #{second.object_id}"

    second_run = Repo.one!(from r in Run, order_by: [desc: r.id], limit: 1)
    assert :ok = Discovery.execute_run(second_run.id)

    completed =
      run_task([
        "--definition-source",
        "bierce",
        "--providers",
        "cinegraph",
        "--resume",
        "#{first.object_id},#{second.object_id}",
        "--wait-ms",
        "0"
      ])

    assert completed =~ "fresh_cache_empty: 2/2"
    assert completed =~ "Batch complete"
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
