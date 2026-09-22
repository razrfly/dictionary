defmodule DevilsDictionary.Discovery.StatusTest do
  @moduledoc """
  The operator's two questions, and the one place that answers them (#144
  Phase 4).

  `mix dd.discovery.check`, `mix dd.discovery.status` and `/ops/discovery` hold
  no numbers of their own: they render `Status.preflight/0` and `Status.rows/0`.
  So this is where the numbers are checked, and the tasks' own suites check
  only that they print what they were given and never print a key.

  The rule under all of it is that neither function knows a provider by name.
  Every case here registers a **fake** provider and asserts it gets the same
  row the twelve shipped ones get — which is the thirteenth provider's day one,
  rehearsed.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Policy, RequestAttempt, Result, Run, Status}
  alias DevilsDictionary.FakeOffsetDiscoveryProvider, as: Provider
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @slug DevilsDictionary.FakeOffsetDiscoveryProvider.slug()

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)
    credentials = Application.get_env(:devils_dictionary, :provider_credentials, %{})

    Application.put_env(:devils_dictionary, :discovery_providers, [Provider])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Provider})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery, discovery)
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
      Application.put_env(:devils_dictionary, :provider_credentials, credentials)
    end)

    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes, registry: providers})
  end

  defp configure(overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    Application.put_env(:devils_dictionary, :discovery, Keyword.merge(config, overrides))
  end

  defp policy(slug, overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})
    configure(source_policies: Map.put(policies, slug, overrides))
  end

  defp row(slug), do: Enum.find(Status.rows(), &(&1.slug == slug))
  defp preflight(slug), do: Enum.find(Status.preflight(), &(&1.slug == slug))

  defp run!(ctx, lemma, keyword_id) do
    word = word!(ctx, lemma, ~w(wordnet))

    Req.Test.stub(Provider, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      limit = String.to_integer(conn.params["limit"])
      offset = String.to_integer(conn.params["offset"] || "0")

      rows =
        Enum.map(1..2//1, fn id ->
          %{
            "id" => keyword_id + id,
            "title" => "#{lemma} #{id}",
            "text" => "a line that uses #{lemma} plainly",
            "year" => "1751"
          }
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(Enum.slice(rows, offset, limit)))
    end)

    target = %{
      object_id: word.object_id,
      lexeme_ids: [word.object_id],
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }

    assert {:queued, run} = Discovery.request(target, @slug)
    assert :ok = Discovery.execute_run(run.id)

    %{word: word, target: target, run: Repo.get!(Run, run.id)}
  end

  # The same disabled-trigger move `retention_test.exs` documents: a completed
  # run is immutable in the database, so only a test may age one.
  defp age!(run, seconds) do
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    # Both clocks move with the run, each keeping its own offset: a run carries
    # the retention *and* the refresh that were in force when it published, and
    # conflating them would make an aged run stale and expired together, which
    # is the confusion this whole phase exists to end.
    held = DateTime.diff(run.expires_at, run.completed_at, :second)
    reusable = DateTime.diff(run.refresh_after, run.completed_at, :second)

    Repo.query!(
      "ALTER TABLE discovery_runs DISABLE TRIGGER discovery_runs_keep_completed_immutable"
    )

    Repo.query!(
      "UPDATE discovery_runs SET completed_at = $1, expires_at = $2, refresh_after = $3 WHERE id = $4",
      [
        then,
        DateTime.add(then, held, :second),
        DateTime.add(then, reusable, :second),
        run.id
      ]
    )

    Repo.query!(
      "ALTER TABLE discovery_runs ENABLE TRIGGER discovery_runs_keep_completed_immutable"
    )

    Repo.get!(Run, run.id)
  end

  describe "the registry is the row list" do
    test "every registered provider has a row in both, in registry order", ctx do
      Application.put_env(:devils_dictionary, :discovery_providers, ctx.registry)

      slugs = Enum.map(ctx.registry, & &1.slug())

      assert Enum.map(Status.rows(), & &1.slug) == slugs
      assert Enum.map(Status.preflight(), & &1.slug) == slugs
    end

    test "a provider registered today has a row in both, with no edit anywhere" do
      # The fake is the only registered provider in this test's registry, and
      # neither function was told anything about it.
      assert [%{slug: @slug, kind: :server}] = Status.rows()
      assert [%{slug: @slug, kind: :server}] = Status.preflight()
    end

    test "a provider that has never run is a row of zeroes, not an absence" do
      assert %{runs: 0, results: 0, roots: 0, stale: 0, retention_due: 0, last_success: nil} =
               row(@slug)
    end
  end

  describe "the ledger" do
    test "one run is counted, its results are held, and its root is fresh", ctx do
      %{run: run} = run!(ctx, "status-one", 7101)

      assert %{runs: 1, failed: 0, results: 2, roots: 1, stale: 0} = row(@slug)
      assert row(@slug).last_success == run.completed_at
      assert Repo.aggregate(from(r in Result, where: r.run_id == ^run.id), :count) == 2
    end

    test "a root past its refresh clock is counted stale, and nothing else is", ctx do
      %{run: fresh} = run!(ctx, "status-fresh", 7201)
      %{run: stale} = run!(ctx, "status-stale", 7202)

      age!(stale, Policy.refresh_seconds(@slug, 2) + 60)

      assert %{roots: 2, stale: 1} = row(@slug)
      assert Repo.get!(Run, fresh.id).status == :succeeded
    end

    test "a run past retention is counted due, and what the sweep takes stops being held", ctx do
      policy(@slug, retention_seconds: 60)
      %{run: run} = run!(ctx, "status-due", 7301)

      assert %{retention_due: 0, results: 2} = row(@slug)

      age!(run, 3_600)

      assert %{retention_due: 1, results: 2} = row(@slug)

      assert %{withdrawn: 1} = Discovery.cleanup()

      # The spend stays in the ledger; the content does not. That pair is the
      # one an operator reads as "retention has run here".
      assert %{runs: 1, results: 0, roots: 0, retention_due: 0} = row(@slug)
    end

    test "the budget column counts this source's attempts in its own window", ctx do
      run!(ctx, "status-budget", 7401)

      source = Sources.get_source_by_slug!(@slug)
      policy = Policy.for!(@slug)

      attempts =
        Repo.aggregate(from(a in RequestAttempt, where: a.source_id == ^source.id), :count)

      assert attempts > 0
      assert %{budget: %{used: ^attempts, limit: limit}} = row(@slug)
      assert limit == policy.request_budget_limit

      # An attempt older than the window is spent and forgotten, which is what
      # makes this a *rolling* budget rather than a total.
      Repo.update_all(from(a in RequestAttempt, where: a.source_id == ^source.id),
        set: [
          attempted_at:
            DateTime.add(DateTime.utc_now(), -policy.request_budget_window_seconds - 60, :second)
        ]
      )

      assert %{budget: %{used: 0}} = row(@slug)
    end

    test "a provider-wide Retry-After shows as backoff, and an expired one does not", ctx do
      %{run: run} = run!(ctx, "status-backoff", 7501)
      until = DateTime.add(DateTime.utc_now(), 90, :second)

      assert {:ok, _source} = Discovery.Budget.defer_provider(run.id, until, "429")

      assert %{backoff: %{reason: "429", seconds: seconds}} = row(@slug)
      assert seconds > 0 and seconds <= 90

      assert {:ok, _source} =
               Discovery.Budget.defer_provider(
                 run.id,
                 DateTime.add(DateTime.utc_now(), -1, :second),
                 "429"
               )

      # `defer_provider/3` keeps the later of the two, so the row is still
      # under the first one. Moving the clock past both is the only way out.
      assert %{backoff: %{}} = row(@slug)
      assert row(@slug) == Enum.find(Status.rows(now: DateTime.utc_now()), &(&1.slug == @slug))

      later = DateTime.add(until, 60, :second)
      assert [%{backoff: nil}] = Status.rows(now: later)
    end
  end

  describe "the preflight" do
    test "a provider's own enabled?/0 is the authority, and the switch is told apart from it" do
      assert %{enabled: true, switch: :unset, credentials: [], problems: []} = preflight(@slug)
    end

    test "an endpoint that is not an endpoint is a problem, and is not silently ignored" do
      stanza = Application.get_env(:devils_dictionary, :offset_fixture, [])
      on_exit(fn -> Application.put_env(:devils_dictionary, :offset_fixture, stanza) end)

      for bad <- ["ftp://example.com", "https://user:secret@example.com/api", "not a url"] do
        Application.put_env(:devils_dictionary, :offset_fixture, endpoint: bad)

        assert %{endpoints: [{:endpoint, ^bad, :invalid}], problems: [problem]} = preflight(@slug)
        assert problem =~ "is not an http(s) endpoint"
      end

      Application.put_env(:devils_dictionary, :offset_fixture,
        endpoint: "https://example.com/search"
      )

      assert %{endpoints: [{:endpoint, _url, :ok}], problems: []} = preflight(@slug)
    end

    test "a policy override the kit cannot read is a problem, not a crash" do
      policy(@slug, positive_refresh_seconds: :soon)

      assert %{policy: {:error, message}, problems: [problem]} = preflight(@slug)
      assert message =~ "invalid duration or limit"
      assert problem =~ @slug
    end

    test "credentials are claimed by environment prefix, and reported as present or missing" do
      Application.put_env(:devils_dictionary, :provider_credentials, %{
        "OFFSET_FIXTURE_API_KEY" => true,
        "OFFSET_FIXTURE_ENABLED" => false,
        "SOMEONE_ELSES_KEY" => true
      })

      assert %{credentials: credentials} = preflight(@slug)

      assert credentials == [
               {"OFFSET_FIXTURE_API_KEY", :present},
               {"OFFSET_FIXTURE_ENABLED", :missing}
             ]

      # A name no registered provider claims is reported, not dropped: Artsy's
      # two are exactly this, kept on the list after it left the registry.
      assert Status.unclaimed_credentials() == [{"SOMEONE_ELSES_KEY", :present}]
    end

    test "the prefix is the shell-safe one runtime.exs derives policy variables with" do
      assert Status.env_prefix("bing-news") == "BING_NEWS"
      assert Status.env_prefix("open-library") == "OPEN_LIBRARY"
      assert Status.env_prefix("spotify") == "SPOTIFY"
    end
  end
end
