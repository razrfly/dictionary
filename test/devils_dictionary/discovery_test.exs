defmodule DevilsDictionary.DiscoveryTest do
  use DevilsDictionary.DataCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery

  alias DevilsDictionary.Discovery.{
    Budget,
    Mapping,
    Policy,
    RequestAttempt,
    Result,
    Run,
    Transport
  }

  alias DevilsDictionary.Discovery.Providers.{CineGraph, Giphy}
  alias DevilsDictionary.FakeOffsetDiscoveryProvider
  alias DevilsDictionary.FakePartialDiscoveryProvider
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, SourceRecord}

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    %{sources: catalog.sources, animals: catalog.scopes["animals"]}
  end

  test "an unprepared target resolves, discovers, deduplicates and then reuses its cache", ctx do
    word = word!(ctx, "war", ~w(wordnet))
    object_count = Repo.aggregate(Object, :count)
    stub_success("war", 273_967, [movie(10, "A title without the query"), movie(10, "duplicate")])

    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    mapping = Repo.get!(Mapping, run.mapping_id)
    actor = Repo.get!(Actor, mapping.configured_by_actor_id)
    completed = Repo.get!(Run, run.id)
    state = Discovery.state(word.object_id, "cinegraph")

    assert mapping.target_object_id == word.object_id
    assert mapping.source_id == ctx.sources["cinegraph"].id
    assert mapping.parameters["term"] == "war"
    assert actor.actor_kind == :import
    assert actor.label == "Wordhoard automatic discovery"
    assert completed.request_parameters["resolved_keyword_ids"] == [273_967]
    assert completed.request_count == 2
    assert completed.status == :succeeded
    assert completed.result_count == 1
    assert state.status == :ready
    assert [%Result{external_id: "10"} = item] = state.items
    assert item.match_details["keywords"] == [%{"id" => 273_967, "name" => "war"}]
    assert item.preview_metadata["title"] == "A title without the query"
    assert item.object_id
    assert item.resolution_state == :newly_created
    assert Repo.aggregate(Object, :count) == object_count + 1

    assert {:cached, %Run{id: cached_id}} = Discovery.request(target(word), "cinegraph")
    assert cached_id == run.id
    assert Repo.aggregate(Run, :count) == 1
  end

  test "successful no-keyword and no-film responses are negative caches, not failures", ctx do
    unknown = word!(ctx, "unfindable", ~w(wordnet))
    stub_no_keyword()

    assert {:queued, run} = Discovery.request(target(unknown), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    assert %{status: :empty, empty_reason: :no_exact_keyword} =
             Discovery.state(unknown.object_id, "cinegraph")

    assert {:cached, _} = Discovery.request(target(unknown), "cinegraph")
    assert Repo.get!(Run, run.id).request_count == 1

    barren = word!(ctx, "barren", ~w(wordnet))
    stub_success("barren", 99, [])

    assert {:queued, run} = Discovery.request(target(barren), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    assert %{status: :empty, empty_reason: :no_results} =
             Discovery.state(barren.object_id, "cinegraph")

    assert Repo.get!(Run, run.id).request_count == 2
  end

  test "positive and empty successes use distinct configurable source freshness", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    positive = word!(ctx, "fresh-positive", ~w(wordnet))
    stub_success("fresh-positive", 31, [movie(31, "Positive")])
    assert {:queued, positive_run} = Discovery.request(target(positive), "cinegraph")
    assert :ok = Discovery.execute_run(positive_run.id)

    empty = word!(ctx, "fresh-empty", ~w(wordnet))
    stub_success("fresh-empty", 32, [])
    assert {:queued, empty_run} = Discovery.request(target(empty), "cinegraph")
    assert :ok = Discovery.execute_run(empty_run.id)

    positive_run = Repo.get!(Run, positive_run.id)
    empty_run = Repo.get!(Run, empty_run.id)

    assert DateTime.diff(positive_run.refresh_after, positive_run.completed_at) == 3_600
    assert DateTime.diff(empty_run.refresh_after, empty_run.completed_at) == 1_800

    assert %{request_budget_limit: 100, request_budget_window_seconds: 3_600} =
             Policy.for!("giphy")

    configure_discovery(
      source_policies: %{
        "cinegraph" => [empty_refresh_seconds: 7 * 24 * 60 * 60]
      }
    )

    assert Policy.refresh_seconds("cinegraph", 0) == 7 * 24 * 60 * 60
    assert Policy.refresh_seconds("cinegraph", 1) == 3_600
  end

  test "GIPHY remains browser-only and cannot enter server ingestion", ctx do
    assert Giphy.enabled?() == false

    assert Giphy.capabilities() == %{
             background: false,
             transport: :browser,
             persistence: :transient,
             pagination: :offset,
             operations: ["gif_search"],
             content_types: [:gif]
           }

    assert Giphy in DevilsDictionary.Discovery.Providers.all()
    refute Giphy in DevilsDictionary.Discovery.Providers.server_providers()

    word = word!(ctx, "no-giphy-ingestion", ~w(wordnet))
    assert {:error, :provider_disabled} = Discovery.request(target(word), "giphy")
    assert Repo.aggregate(Mapping, :count) == 0
    assert Repo.aggregate(Run, :count) == 0
  end

  test "discovery policy rejects missing, unknown and invalid values" do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    configure_discovery(source_policies: %{"cinegraph" => [invented_setting: 1]})

    assert_raise ArgumentError, ~r/unknown discovery policy overrides/, fn ->
      Policy.for!("cinegraph")
    end

    Application.put_env(:devils_dictionary, :discovery, original)
    configure_discovery(source_policies: %{"cinegraph" => [request_budget_limit: 0]})
    assert_raise ArgumentError, ~r/invalid duration or limit/, fn -> Policy.for!("cinegraph") end

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.delete(original, :empty_refresh_seconds)
    )

    assert_raise ArgumentError, ~r/missing discovery policy defaults/, fn ->
      Policy.for!("cinegraph")
    end
  end

  test "a successful empty refresh replaces the old visible set", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    configure_discovery(positive_refresh_seconds: 0, refresh_cooldown_seconds: 0)

    word = word!(ctx, "now-empty", ~w(wordnet))
    stub_success("now-empty", 41, [movie(41, "Old visible result")])
    assert {:queued, old_run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(old_run.id)
    assert [%Result{external_id: "41"}] = Discovery.state(word.object_id, "cinegraph").items

    stub_success("now-empty", 41, [])
    assert {:queued, empty_run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(empty_run.id)

    assert %{status: :empty, empty_reason: :no_results, items: []} =
             Discovery.state(word.object_id, "cinegraph")

    assert Repo.get!(Run, old_run.id).result_count == 1
    assert Repo.get!(Run, empty_run.id).result_count == 0
  end

  test "failed and quota-deferred refreshes retain stale results", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    configure_discovery(positive_refresh_seconds: 0, refresh_cooldown_seconds: 0)

    failed_word = word!(ctx, "stale-failure", ~w(wordnet))
    stub_success("stale-failure", 51, [movie(51, "Retained through failure")])
    assert {:queued, first} = Discovery.request(target(failed_word), "cinegraph")
    assert :ok = Discovery.execute_run(first.id)

    Req.Test.stub(CineGraph, fn conn -> json(conn, %{"data" => %{"unexpected" => []}}) end)
    assert {:queued, failed_refresh} = Discovery.request(target(failed_word), "cinegraph")
    assert :ok = Discovery.execute_run(failed_refresh.id)
    assert Repo.get!(Run, failed_refresh.id).status == :failed

    assert [%Result{external_id: "51"}] =
             Discovery.state(failed_word.object_id, "cinegraph").items

    quota_word = word!(ctx, "stale-quota", ~w(wordnet))
    stub_success("stale-quota", 52, [movie(52, "Retained through quota")])
    assert {:queued, first} = Discovery.request(target(quota_word), "cinegraph")
    assert :ok = Discovery.execute_run(first.id)

    configure_discovery(request_budget_limit: 1)
    assert {:queued, deferred_refresh} = Discovery.request(target(quota_word), "cinegraph")
    assert {:snooze, seconds} = Discovery.execute_run(deferred_refresh.id)
    assert seconds in 1..60
    assert [%Result{external_id: "52"}] = Discovery.state(quota_word.object_id, "cinegraph").items
  end

  test "missing image configuration degrades to a posterless result", ctx do
    original = Application.fetch_env!(:devils_dictionary, :cinegraph)
    on_exit(fn -> Application.put_env(:devils_dictionary, :cinegraph, original) end)

    Application.put_env(
      :devils_dictionary,
      :cinegraph,
      Keyword.put(original, :image_base_url, nil)
    )

    word = word!(ctx, "poster-config", ~w(wordnet))
    stub_success("poster-config", 808, [movie(808, "Posterless by configuration")])

    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    assert [%Result{preview_metadata: %{"poster_url" => nil}}] =
             Discovery.state(word.object_id, "cinegraph").items
  end

  test "timeouts retry within the request budget and malformed responses fail safely", ctx do
    slow = word!(ctx, "slow", ~w(wordnet))
    Req.Test.stub(CineGraph, &Req.Test.transport_error(&1, :timeout))

    assert {:queued, run} = Discovery.request(target(slow), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    failed = Repo.get!(Run, run.id)
    assert failed.status == :failed
    assert failed.error_code == "timeout"
    assert failed.request_count == 3
    assert Discovery.state(slow.object_id, "cinegraph").status == :failed

    malformed = word!(ctx, "malformed", ~w(wordnet))
    Req.Test.stub(CineGraph, fn conn -> json(conn, %{"data" => %{"unexpected" => []}}) end)

    assert {:queued, run} = Discovery.request(target(malformed), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert %{status: :failed, error_code: "malformed_response"} = Repo.get!(Run, run.id)
  end

  test "concurrent visits share one mapping, run and Oban job", ctx do
    word = word!(ctx, "burst", ~w(wordnet))

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Discovery.request(target(word), "cinegraph") end,
        max_concurrency: 8,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:queued, %Run{}}, &1))
    assert Repo.aggregate(Mapping, :count) == 1
    assert Repo.aggregate(Run, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  @tag :unboxed
  test "concurrent reversed film batches acquire one global identifier lock order", ctx do
    first_word = word!(ctx, "lock-order-a", ~w(wordnet))
    second_word = word!(ctx, "lock-order-b", ~w(wordnet))
    first_movie = movie(840, "First lock film") |> Map.put("imdbId", "tt0000840")
    second_movie = movie(841, "Second lock film") |> Map.put("imdbId", "tt0000841")
    parent = self()
    gate = make_ref()

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        term = body["variables"]["query"]
        keyword_response(conn, term, if(term == first_word.lemma, do: 840, else: 841))
      else
        [keyword_id] = body["variables"]["keywords"]
        send(parent, {:discovery_ready, self()})

        receive do
          {:publish, ^gate} ->
            movies =
              if keyword_id == 840,
                do: [first_movie, second_movie],
                else: [second_movie, first_movie]

            discovery_response(conn, movies, nil, "lock-order", keyword_id)
        end
      end
    end)

    assert {:queued, first_run} = Discovery.request(target(first_word), "cinegraph")
    assert {:queued, second_run} = Discovery.request(target(second_word), "cinegraph")

    tasks =
      Enum.map([first_run, second_run], fn run ->
        Task.async(fn -> Discovery.execute_run(run.id) end)
      end)

    publishers =
      for _task <- tasks do
        assert_receive {:discovery_ready, publisher}, 5_000
        publisher
      end

    Enum.each(publishers, &send(&1, {:publish, gate}))
    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [:ok, :ok]
    assert Enum.all?([first_run, second_run], &(Repo.get!(Run, &1.id).status == :succeeded))

    assert Registry.by_external_id("tmdb_movie", "840") ==
             Registry.by_external_id("imdb_title", "tt0000840")

    assert Registry.by_external_id("tmdb_movie", "841") ==
             Registry.by_external_id("imdb_title", "tt0000841")
  end

  test "mapping versions isolate old work and a slow old response cannot replace the new one",
       ctx do
    word = word!(ctx, "changeable", ~w(wordnet))
    stub_success("changeable", 1, [movie(1, "Old result")])
    assert {:queued, old_run} = Discovery.request(target(word), "cinegraph")
    old_mapping = Repo.get!(Mapping, old_run.mapping_id)

    attrs = %{
      target_object_id: word.object_id,
      source_id: old_mapping.source_id,
      operation: old_mapping.operation,
      parameters: Map.put(old_mapping.parameters, "term", "new meaning"),
      configured_by_actor_id: old_mapping.configured_by_actor_id,
      enabled: true
    }

    assert {:ok, new_mapping} = Discovery.create_mapping_version(old_mapping.mapping_key, attrs)
    assert new_mapping.version == old_mapping.version + 1
    refute Repo.get!(Mapping, old_mapping.id).enabled

    stub_success("new meaning", 2, [movie(2, "New result")])
    assert {:queued, new_run} = Discovery.request_mapping(new_mapping)
    assert :ok = Discovery.execute_run(new_run.id)
    assert :ok = Discovery.execute_run(old_run.id)

    assert [%Result{external_id: "2"}] = Discovery.state(word.object_id, "cinegraph").items
    assert Repo.get!(Run, old_run.id).error_code == "mapping_disabled"

    assert Repo.aggregate(
             from(m in Mapping, where: m.mapping_key == ^old_mapping.mapping_key and m.enabled),
             :count
           ) == 1
  end

  test "pagination stays in one mapping context and deduplicates the visible feed", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    configure_discovery(max_pages_per_context: 2)

    word = word!(ctx, "paged", ~w(wordnet))
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      cond do
        String.contains?(body["query"], "searchMovieKeywords") ->
          keyword_response(conn, "paged", 42)

        true ->
          call = Agent.get_and_update(counter, &{&1, &1 + 1})

          if call == 0 do
            discovery_response(conn, [movie(1, "First")], "cursor-1")
          else
            assert body["variables"]["after"] == "cursor-1"
            discovery_response(conn, [movie(1, "First repeated"), movie(2, "Second")], "cursor-2")
          end
      end
    end)

    assert {:queued, first} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(first.id)
    state = Discovery.state(word.object_id, "cinegraph")
    assert state.next_cursor == "cursor-1"

    assert {:queued, second} =
             Discovery.request_next(
               word.object_id,
               "cinegraph",
               state.page_context,
               state.page,
               state.next_cursor
             )

    assert :ok = Discovery.execute_run(second.id)
    state = Discovery.state(word.object_id, "cinegraph")
    assert Enum.map(state.items, & &1.external_id) == ["1", "2"]
    assert state.next_cursor == nil

    mapping = first |> Repo.preload(:mapping) |> Map.fetch!(:mapping)

    assert {:error, :invalid_pagination} =
             Discovery.request_mapping(mapping,
               after: "cursor-2",
               page_context: state.page_context,
               page: 2
             )
  end

  test "each cursor page gets its own transport retry allowance", ctx do
    word = word!(ctx, "paged", ~w(wordnet))
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        keyword_response(conn, "paged", 42)
      else
        call = Agent.get_and_update(counter, &{&1, &1 + 1})

        cond do
          call in [0, 1, 3, 4] -> Req.Test.transport_error(conn, :timeout)
          call == 2 -> discovery_response(conn, [movie(1, "First")], "cursor-1")
          true -> discovery_response(conn, [movie(2, "Second")], nil)
        end
      end
    end)

    assert {:queued, first} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(first.id)
    state = Discovery.state(word.object_id, "cinegraph")

    assert {:queued, second} =
             Discovery.request_next(
               word.object_id,
               "cinegraph",
               state.page_context,
               state.page,
               state.next_cursor
             )

    assert :ok = Discovery.execute_run(second.id)
    assert Repo.get!(Run, second.id).status == :succeeded
    assert Repo.get!(Run, second.id).request_count == 3

    assert Enum.map(Discovery.state(word.object_id, "cinegraph").items, & &1.external_id) == [
             "1",
             "2"
           ]
  end

  for late_outcome <- [:success, :failure, :exception] do
    @late_outcome late_outcome
    test "a recovered worker ignores the old #{@late_outcome} response", ctx do
      word = word!(ctx, "paged", ~w(wordnet))
      assert {:queued, run} = Discovery.request(target(word), "cinegraph")
      counter = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(CineGraph, fn conn ->
        body = request_body(conn)

        if String.contains?(body["query"], "searchMovieKeywords") do
          keyword_response(conn, "paged", 42)
        else
          call = Agent.get_and_update(counter, &{&1, &1 + 1})

          if call == 0 do
            past = DateTime.add(DateTime.utc_now(), -1, :second)

            Repo.update_all(from(r in Run, where: r.id == ^run.id),
              set: [execution_lease_expires_at: past]
            )

            assert %{recovered: 1} = Discovery.cleanup()
            assert :ok = Discovery.execute_run(run.id)

            case @late_outcome do
              :success -> discovery_response(conn, [movie(1, "Late old result")], nil)
              :failure -> json(conn, %{"data" => %{"unexpected" => []}})
              :exception -> raise "old worker crashed"
            end
          else
            discovery_response(conn, [movie(2, "Recovered result")], nil)
          end
        end
      end)

      if @late_outcome == :exception do
        assert_raise RuntimeError, "old worker crashed", fn -> Discovery.execute_run(run.id) end
      else
        assert :ok = Discovery.execute_run(run.id)
      end

      assert Repo.get!(Run, run.id).status == :succeeded
      assert [%Result{external_id: "2"}] = Discovery.state(word.object_id, "cinegraph").items
    end
  end

  test "durable discovery identity does not archive disposable previews or keyword matches",
       ctx do
    for {term, keyword_id, title} <- [{"war", 42, "First title"}, {"peace", 43, "Updated title"}] do
      word = word!(ctx, term, ~w(wordnet))
      stub_success(term, keyword_id, [movie(10, title)])
      assert {:queued, run} = Discovery.request(target(word), "cinegraph")
      assert :ok = Discovery.execute_run(run.id)
    end

    results = Repo.all(Result)
    assert length(results) == 2
    assert [record_id] = results |> Enum.map(& &1.source_record_id) |> Enum.uniq()

    payloads =
      Repo.all(
        from revision in DevilsDictionary.Corpus.SourceRecordRevision,
          where: revision.source_record_id == ^record_id,
          select: revision.payload
      )

    assert Enum.map(payloads, & &1["external_id"]) == ["10", "10"]

    assert Enum.map(payloads, &get_in(&1, ["preview_metadata", "title"])) |> Enum.sort() ==
             ["First title", "Updated title"]

    [object_id] = results |> Enum.map(& &1.object_id) |> Enum.uniq()

    assert Repo.aggregate(
             from(c in DevilsDictionary.Claims.AssertionRevision,
               where: c.subject_object_id == ^object_id
             ),
             :count
           ) == 0
  end

  test "refresh-due and legacy-expired previews remain usable while withdrawal does not", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    refreshable = word!(ctx, "refreshable", ~w(wordnet))
    configure_discovery(positive_refresh_seconds: 0)
    stub_success("refreshable", 8, [movie(8, "Still visible")])
    assert {:queued, run} = Discovery.request(target(refreshable), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    assert %{status: :ready, refresh_due: true} =
             Discovery.state(refreshable.object_id, "cinegraph")

    assert {:queued, _refresh} = Discovery.request(target(refreshable), "cinegraph")
    assert Discovery.state(refreshable.object_id, "cinegraph").status == :ready

    [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
    assert {1, _} = Discovery.withdraw_result(result.id)

    assert %{status: :empty, empty_reason: :withdrawn} =
             Discovery.state(refreshable.object_id, "cinegraph")

    expired = word!(ctx, "expired", ~w(wordnet))
    configure_discovery(positive_refresh_seconds: 0)
    stub_success("expired", 9, [movie(9, "Still displayable")])
    assert {:queued, run} = Discovery.request(target(expired), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert DateTime.compare(Repo.get!(Run, run.id).expires_at, DateTime.utc_now()) == :lt
    assert Discovery.state(expired.object_id, "cinegraph").status == :ready
    configure_discovery(retention_seconds: 0)
    _summary = Discovery.cleanup()
    assert Repo.get(Run, run.id)
    assert Discovery.state(expired.object_id, "cinegraph").status == :ready
  end

  test "explicit refresh honors the per-mapping cooldown", ctx do
    word = word!(ctx, "cooldown", ~w(wordnet))
    stub_success("cooldown", 88, [movie(88, "One response")])

    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert {:cached, cached} = Discovery.request(target(word), "cinegraph", refresh: true)
    assert cached.id == run.id
    assert Repo.aggregate(Run, :count) == 1
  end

  test "withdrawal survives refresh and cleanup until an accountable reinstatement", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    configure_discovery(refresh_cooldown_seconds: 0, retained_attempts_per_position: 1)

    word = word!(ctx, "durable-withdrawal", ~w(wordnet))
    stub_success("durable-withdrawal", 501, [movie(501, "Policy-bound")])
    assert {:queued, first} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(first.id)
    [first_result] = Discovery.state(word.object_id, "cinegraph").items

    assert {1, %SourceRecord{display_allowed: false}} =
             Discovery.withdraw_result(first_result.id, "provider requested withdrawal")

    assert {:queued, refreshed} =
             Discovery.request(target(word), "cinegraph", refresh: true)

    assert :ok = Discovery.execute_run(refreshed.id)
    assert Discovery.state(word.object_id, "cinegraph").items == []
    assert %{deleted: 1} = Discovery.cleanup()
    assert Repo.get(SourceRecord, first_result.source_record_id).display_allowed == false

    actor = Repo.get!(Actor, Repo.get!(Mapping, refreshed.mapping_id).configured_by_actor_id)
    [latest_result] = Repo.all(from r in Result, where: r.run_id == ^refreshed.id)

    assert {1, %SourceRecord{display_allowed: true, display_policy_actor_id: actor_id}} =
             Discovery.reinstate_result(latest_result.id, actor.id, "provider restored listing")

    assert actor_id == actor.id
    assert [%Result{external_id: "501"}] = Discovery.state(word.object_id, "cinegraph").items
  end

  test "Retry-After accepts delta seconds and HTTP dates without a five-second cap" do
    numeric = Req.Response.new() |> Req.Response.put_header("retry-after", "120")
    assert Transport.retry_after_seconds(numeric) == 120

    now = ~U[2026-09-12 10:00:00Z]

    dated =
      Req.Response.new()
      |> Req.Response.put_header("retry-after", "Sat, 12 Sep 2026 10:02:00 GMT")

    assert Transport.retry_after_seconds(dated, now) == 120

    negative = Req.Response.new() |> Req.Response.put_header("retry-after", "-1")
    assert Transport.retry_after_seconds(negative, now) == nil
  end

  test "Retry-After defers the existing run and blocks fresh visits provider-wide", ctx do
    first = word!(ctx, "throttled-first", ~w(wordnet))
    second = word!(ctx, "throttled-second", ~w(wordnet))

    Req.Test.stub(CineGraph, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "120")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    assert {:queued, run} = Discovery.request(target(first), "cinegraph")
    assert {:snooze, 120} = Discovery.execute_run(run.id)

    assert %{status: :pending, request_count: 1, error_code: "provider_retry_after"} =
             Repo.get!(Run, run.id)

    assert {:deferred, :provider_backoff} =
             Discovery.request(target(second), "cinegraph", refresh: true)

    assert Repo.aggregate(Run, :count) == 1
  end

  test "provider-wide execution leases cap independent targets and scheduled cleanup recovers",
       ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    providers = Application.get_env(:devils_dictionary, :discovery_providers)
    fixture = DevilsDictionary.FakeTransientDiscoveryProvider

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery, original)

      if providers,
        do: Application.put_env(:devils_dictionary, :discovery_providers, providers),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    Application.put_env(:devils_dictionary, :discovery_providers, [fixture])
    configure_discovery(provider_concurrency: 2, execution_lease_seconds: 60)

    runs =
      for index <- 1..3 do
        word = word!(ctx, "lease-#{index}", ~w(wordnet))
        assert {:queued, run} = Discovery.request(target(word), fixture.slug())
        run
      end

    lease = DateTime.add(DateTime.utc_now(), 60, :second)

    for run <- Enum.take(runs, 2) do
      run
      |> Run.lifecycle_changeset(%{
        status: :running,
        started_at: DateTime.utc_now(),
        execution_lease_expires_at: lease
      })
      |> Repo.update!()
    end

    assert {:snooze, 5} = Discovery.execute_run(List.last(runs).id)

    first = hd(runs)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(r in Run, where: r.id == ^first.id),
      set: [execution_lease_expires_at: past]
    )

    assert %{recovered: 1} = Discovery.cleanup()
    assert Repo.get!(Run, first.id).status == :pending
  end

  test "transient empty is successful and a later visit fetches again", ctx do
    providers = Application.get_env(:devils_dictionary, :discovery_providers)
    fixture = DevilsDictionary.FakeTransientDiscoveryProvider

    on_exit(fn ->
      if providers,
        do: Application.put_env(:devils_dictionary, :discovery_providers, providers),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    Application.put_env(:devils_dictionary, :discovery_providers, [fixture])
    word = word!(ctx, "fixture-empty-result", ~w(wordnet))
    assert {:queued, first} = Discovery.request(target(word), fixture.slug())
    assert :ok = Discovery.execute_run(first.id)

    assert %{status: :empty, empty_reason: :transient_results} =
             Discovery.state(word.object_id, fixture.slug())

    assert {:queued, second} = Discovery.request(target(word), fixture.slug())
    refute second.id == first.id
  end

  test "queue and rolling request budgets defer work without creating unbounded attempts", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    configure_discovery(queue_cap: 1, request_budget_limit: 1)
    first = word!(ctx, "budget-one", ~w(wordnet))
    second = word!(ctx, "budget-two", ~w(wordnet))
    stub_success("budget-one", 71, [movie(71, "Budgeted")])

    assert {:queued, run} = Discovery.request(target(first), "cinegraph")
    assert {:deferred, :queue_full} = Discovery.request(target(second), "cinegraph")
    assert Repo.aggregate(Run, :count) == 1

    assert {:snooze, 60} = Discovery.execute_run(run.id)
    pending = Repo.get!(Run, run.id)
    assert pending.status == :pending
    assert pending.error_code == "request_budget"
    assert pending.request_count == 1
    assert pending.request_parameters["resolved_keyword_ids"] == [71]

    Repo.update_all(RequestAttempt,
      set: [attempted_at: DateTime.add(DateTime.utc_now(), -61, :second)]
    )

    assert :ok = Budget.claim(run.id, "movie_discovery")
  end

  test "concurrent mapping changes serialize and leave exactly one enabled version", ctx do
    word = word!(ctx, "versioned", ~w(wordnet))
    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    mapping = Repo.get!(Mapping, run.mapping_id)

    results =
      1..5
      |> Task.async_stream(
        fn version ->
          Discovery.create_mapping_version(mapping.mapping_key, %{
            target_object_id: word.object_id,
            source_id: mapping.source_id,
            operation: mapping.operation,
            parameters: Map.put(mapping.parameters, "term", "version #{version}"),
            configured_by_actor_id: mapping.configured_by_actor_id,
            enabled: true
          })
        end,
        max_concurrency: 5,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Mapping{}}, &1))

    assert Repo.aggregate(
             from(m in Mapping, where: m.mapping_key == ^mapping.mapping_key and m.enabled),
             :count
           ) == 1

    assert Repo.aggregate(
             from(m in Mapping, where: m.mapping_key == ^mapping.mapping_key),
             :count
           ) == 6

    assert_raise Postgrex.Error, ~r/discovery mapping versions are immutable/, fn ->
      mapping |> Ecto.Changeset.change(parameters: %{"term" => "rewritten"}) |> Repo.update!()
    end
  end

  test "one verified film identity can support several targets and independent reasons", ctx do
    grief = word!(ctx, "grief", ~w(wordnet))
    war = word!(ctx, "war", ~w(wordnet))
    {:ok, film} = Registry.create_work(%{preferred_label: "Shared film", work_kind: "film"})
    {:ok, _identifier} = Registry.add_external_id(film.object_id, "tmdb_movie", "88")
    object_count = Repo.aggregate(Object, :count)

    for word <- [grief, war] do
      stub_success(word.lemma, if(word.lemma == "grief", do: 9_872, else: 273_967), [
        movie(88, "Shared film")
      ])

      assert {:queued, run} = Discovery.request(target(word), "cinegraph")
      assert :ok = Discovery.execute_run(run.id)
    end

    results = Repo.all(from r in Result, where: r.external_id == "88", order_by: r.id)
    assert Enum.map(results, & &1.object_id) == [film.object_id, film.object_id]
    assert results |> Enum.map(& &1.match_details["query"]) |> Enum.sort() == ["grief", "war"]
    assert Repo.aggregate(Object, :count) == object_count
  end

  test "explicit sense mappings remain separate and never leak across meanings", ctx do
    word = word!(ctx, "bank", ~w(wordnet wiktionary))
    financial = sense!(ctx, word, "wordnet", gloss: "a financial institution")
    riverside = sense!(ctx, word, "wiktionary", gloss: "land beside a river")

    assert {:queued, seed_run} = Discovery.request(target(word), "cinegraph")
    seed = Repo.get!(Mapping, seed_run.mapping_id)

    mappings =
      for {sense, term} <- [{financial, "finance bank"}, {riverside, "river bank"}] do
        assert {:ok, mapping} =
                 Discovery.create_mapping_version("sense/#{sense.object_id}/cinegraph", %{
                   target_object_id: sense.object_id,
                   source_id: seed.source_id,
                   operation: seed.operation,
                   parameters:
                     Map.merge(seed.parameters, %{"term" => term, "relevance" => "sense"}),
                   configured_by_actor_id: seed.configured_by_actor_id,
                   enabled: true
                 })

        {sense, term, mapping}
      end

    for {sense, term, mapping} <- mappings do
      id = if sense.object_id == financial.object_id, do: 501, else: 502
      stub_success(term, id, [movie(id, term)])
      assert {:queued, run} = Discovery.request_mapping(mapping)
      assert :ok = Discovery.execute_run(run.id)
    end

    assert [%Result{external_id: "501"}] = Discovery.state(financial.object_id, "cinegraph").items
    assert [%Result{external_id: "502"}] = Discovery.state(riverside.object_id, "cinegraph").items
  end

  test "several exact keyword identities use explicit ANY and retain several match reasons",
       ctx do
    word = word!(ctx, "echo", ~w(wordnet))

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        json(conn, %{
          "data" => %{
            "searchMovieKeywords" => [
              %{"tmdbId" => 10, "name" => "echo", "movieCount" => 2},
              %{"tmdbId" => 11, "name" => "ECHO", "movieCount" => 3}
            ]
          }
        })
      else
        assert String.contains?(body["query"], "keywordMatch: ANY")
        assert body["variables"]["keywords"] == [10, 11]

        json(conn, %{
          "data" => %{
            "discoverMovies" => %{
              "edges" => [
                %{
                  "cursor" => "one",
                  "node" => %{
                    "movie" => movie(90, "Several reasons"),
                    "matchedKeywords" => [
                      %{"tmdbId" => 10, "name" => "echo"},
                      %{"tmdbId" => 11, "name" => "ECHO"}
                    ],
                    "matchedGenres" => []
                  }
                }
              ],
              "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
            }
          }
        })
      end
    end)

    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    assert [%Result{match_details: %{"keywords" => reasons}}] =
             Discovery.state(word.object_id, "cinegraph").items

    assert Enum.map(reasons, & &1["id"]) == [10, 11]
  end

  test "cleanup cannot delete a linked object or its independent illustrates claim", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    configure_discovery(refresh_cooldown_seconds: 0)

    word = word!(ctx, "grief", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet", gloss: "deep sorrow")
    {:ok, film} = Registry.create_work(%{preferred_label: "A durable film", work_kind: "film"})
    {:ok, _identifier} = Registry.add_external_id(film.object_id, "tmdb_movie", "50")

    {:ok, claim} =
      Claims.assert(film.object_id, "illustrates", sense.object_id, %{method: "curated"})

    object_count = Repo.aggregate(Object, :count)
    stub_success("grief", 9_872, [movie(50, "A durable film")])

    runs =
      Enum.map(1..4, fn _ ->
        assert {:queued, run} = Discovery.request(target(word), "cinegraph", refresh: true)
        assert :ok = Discovery.execute_run(run.id)
        run
      end)

    first = hd(runs)
    assert %{deleted: 1} = Discovery.cleanup()
    assert Repo.get(Run, first.id) == nil
    assert Repo.get(Object, film.object_id)
    assert Claims.current_revision(claim.id).object_object_id == sense.object_id
    assert Repo.aggregate(Object, :count) == object_count
  end

  test "a second provider can return transient non-film cards without persistence", ctx do
    original = Application.get_env(:devils_dictionary, :discovery_providers)
    provider = DevilsDictionary.FakeTransientDiscoveryProvider
    Application.put_env(:devils_dictionary, :discovery_providers, [provider])

    on_exit(fn ->
      if original,
        do: Application.put_env(:devils_dictionary, :discovery_providers, original),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    word = word!(ctx, "artful", ~w(wordnet))
    :ok = Discovery.subscribe(word.object_id)
    assert {:queued, run} = Discovery.request(target(word), provider.slug())
    assert :ok = Discovery.execute_run(run.id)

    assert_receive {:discovery_updated, _, _, "transient-fixture", [item]}
    assert item.preview_metadata["content_type"] == "art"
    assert Repo.aggregate(Result, :count) == 0
    assert %{completion_reason: :transient_results, result_count: 1} = Repo.get!(Run, run.id)
  end

  test "retired, split and merged targets suspend queued work at domain and database boundaries",
       ctx do
    word = word!(ctx, "retired", ~w(wordnet))
    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    mapping = Repo.get!(Mapping, run.mapping_id)
    {:ok, _event} = Registry.retire(word.object_id, reason: "test")

    assert {:error, :invalid_target} = Discovery.request(target(word), "cinegraph")
    assert Discovery.state(word.object_id, "cinegraph").status == :idle
    assert :ok = Discovery.execute_run(run.id)

    assert %{status: :failed, error_code: "mapping_ineligible", request_count: 0} =
             Repo.get!(Run, run.id)

    assert_raise Postgrex.Error, ~r/discovery target must be an active lexeme or sense/, fn ->
      %Mapping{}
      |> Mapping.create_changeset(%{
        mapping_key: "invalid/direct",
        version: 1,
        target_object_id: word.object_id,
        source_id: mapping.source_id,
        operation: mapping.operation,
        parameters: mapping.parameters,
        configured_by_actor_id: mapping.configured_by_actor_id,
        enabled: true
      })
      |> Repo.insert!()
    end

    split_input = word!(ctx, "split-input", ~w(wordnet))
    split_a = word!(ctx, "split-a", ~w(wordnet))
    split_b = word!(ctx, "split-b", ~w(wordnet))
    assert {:queued, split_run} = Discovery.request(target(split_input), "cinegraph")

    assert {:ok, _event} =
             Registry.split(split_input.object_id, [split_a.object_id, split_b.object_id],
               reason: "test split"
             )

    assert {:error, :invalid_target} = Discovery.request(target(split_input), "cinegraph")
    assert Discovery.state(split_input.object_id, "cinegraph").status == :idle
    assert :ok = Discovery.execute_run(split_run.id)

    assert %{status: :failed, error_code: "mapping_ineligible", request_count: 0} =
             Repo.get!(Run, split_run.id)

    merged_input = word!(ctx, "merged-input", ~w(wordnet))
    merged_output = word!(ctx, "merged-output", ~w(wordnet))
    assert {:queued, merged_run} = Discovery.request(target(merged_input), "cinegraph")

    assert {:ok, _event} =
             Registry.merge([merged_input.object_id], merged_output.object_id,
               reason: "test merge"
             )

    assert {:error, :invalid_target} = Discovery.request(target(merged_input), "cinegraph")
    assert Discovery.state(merged_input.object_id, "cinegraph").status == :idle
    assert :ok = Discovery.execute_run(merged_run.id)

    assert %{status: :failed, error_code: "mapping_ineligible", request_count: 0} =
             Repo.get!(Run, merged_run.id)
  end

  test "automatic mappings supersede stale adapter versions and configured catalogs", ctx do
    original = Application.get_env(:devils_dictionary, :discovery_providers)
    fixture = DevilsDictionary.FakeTransientDiscoveryProvider

    on_exit(fn ->
      if original,
        do: Application.put_env(:devils_dictionary, :discovery_providers, original),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    Application.put_env(:devils_dictionary, :discovery_providers, [fixture])

    assert Enum.map(DevilsDictionary.Discovery.Providers.source_catalog(), & &1.slug) == [
             fixture.slug()
           ]

    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph])
    word = word!(ctx, "adapter-version", ~w(wordnet))
    target = target(word)
    actor = Repo.insert!(%Actor{actor_kind: :import, label: "stale adapter fixture"})
    {operation, parameters} = CineGraph.automatic_mapping(target)

    stale =
      %Mapping{}
      |> Mapping.create_changeset(%{
        mapping_key: "automatic/cinegraph/#{word.object_id}/cinegraph.old",
        version: 1,
        target_object_id: word.object_id,
        source_id: ctx.sources["cinegraph"].id,
        operation: operation,
        parameters: parameters,
        configured_by_actor_id: actor.id,
        enabled: true
      })
      |> Repo.insert!()

    assert {:queued, run} = Discovery.request(target, "cinegraph")
    refute Repo.get!(Mapping, stale.id).enabled
    assert Repo.get!(Mapping, run.mapping_id).mapping_key =~ CineGraph.adapter_version()
    assert Discovery.state(word.object_id, "cinegraph").mapping_id == run.mapping_id
  end

  test "a 403 stays a terminal authentication verdict for a provider that says nothing", ctx do
    word = word!(ctx, "forbidden", ~w(wordnet))
    calls = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(CineGraph, fn conn ->
      Agent.update(calls, &(&1 + 1))
      Plug.Conn.send_resp(conn, 403, "forbidden")
    end)

    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)

    completed = Repo.get!(Run, run.id)
    assert completed.status == :failed
    assert completed.error_code == "authentication_failed"
    # The point of the default: no retry is spent arguing with a refusal.
    assert Agent.get(calls, & &1) == 1
    assert Discovery.state(word.object_id, "cinegraph").status == :failed
  end

  test "a provider that cannot be driven is refused at the gate, not inside a run", ctx do
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [FakePartialDiscoveryProvider])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, providers) end)

    word = word!(ctx, "partial", ~w(wordnet))
    slug = FakePartialDiscoveryProvider.slug()

    # It is registered and enabled, and it claims the pipeline.
    assert Discovery.Providers.get(slug) == FakePartialDiscoveryProvider

    # `request/3` resolves from the registry rather than `server_providers/1`,
    # so the eligibility check is the only thing standing between a half-built
    # provider and a queued run that raises where nothing can recover it.
    assert {:error, :provider_not_retrievable} = Discovery.request(target(word), slug)
    assert {:error, :provider_not_retrievable} = Discovery.provider_eligibility(slug)
    assert Repo.aggregate(Run, :count) == 0
    assert Discovery.state(word.object_id, slug).status == :idle
  end

  describe "a GET, offset-paged, text provider on the same pipeline" do
    setup do
      providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
      req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)
      discovery = Application.fetch_env!(:devils_dictionary, :discovery)

      Application.put_env(:devils_dictionary, :discovery_providers, [
        FakeOffsetDiscoveryProvider
      ])

      Application.put_env(:devils_dictionary, :discovery_req_options,
        plug: {Req.Test, FakeOffsetDiscoveryProvider}
      )

      on_exit(fn ->
        Application.put_env(:devils_dictionary, :discovery_providers, providers)
        Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
        Application.put_env(:devils_dictionary, :discovery, discovery)
      end)

      %{slug: FakeOffsetDiscoveryProvider.slug()}
    end

    test "completes a run over GET and pages to page 2 by offset", ctx do
      word = word!(ctx, "elegy", ~w(wordnet))
      requests = start_supervised!({Agent, fn -> [] end})
      stub_texts(text_rows(5), requests)

      assert {:queued, first} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(first.id)

      state = Discovery.state(word.object_id, ctx.slug)
      assert state.status == :ready
      assert state.pagination == :offset
      assert state.provider_name == "Offset fixture"
      assert state.provider_detail == "public domain"
      assert Enum.map(state.items, & &1.external_id) == ["1", "2", "3"]
      assert state.next_cursor == "3"

      assert {:queued, second} =
               Discovery.request_next(
                 word.object_id,
                 ctx.slug,
                 state.page_context,
                 state.page,
                 state.next_cursor
               )

      assert :ok = Discovery.execute_run(second.id)

      state = Discovery.state(word.object_id, ctx.slug)
      assert Enum.map(state.items, & &1.external_id) == ~w(1 2 3 4 5)
      assert state.page == 1
      assert state.next_cursor == nil

      # The second page asked the provider for the offset the first one handed
      # back, and it travelled as a query parameter on a GET.
      assert Agent.get(requests, &Enum.reverse/1) == [
               {"GET", "0", "3"},
               {"GET", "3", "3"}
             ]

      assert Repo.get!(Run, second.id).request_parameters["after"] == "3"

      [%Result{preview_metadata: preview}] =
        Repo.all(from r in Result, where: r.run_id == ^second.id, order_by: r.position, limit: 1)

      assert preview["content_type"] == "text"
    end

    test "an empty page is negatively cached and not fetched again", ctx do
      word = word!(ctx, "unsung", ~w(wordnet))
      requests = start_supervised!({Agent, fn -> [] end})
      stub_texts([], requests)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert %{status: :empty, empty_reason: :no_results} =
               Discovery.state(word.object_id, ctx.slug)

      assert {:cached, cached} = Discovery.request(target(word), ctx.slug)
      assert cached.id == run.id
      assert Repo.aggregate(Run, :count) == 1
      assert length(Agent.get(requests, & &1)) == 1
    end

    test "a provider may declare 403 retryable, and the run recovers", ctx do
      word = word!(ctx, "throttled", ~w(wordnet))
      calls = start_supervised!({Agent, fn -> 0 end})
      rows = text_rows(5)

      # The Met's shape: the first request is refused with a bare 403 and no
      # Retry-After, the next one succeeds.
      Req.Test.stub(FakeOffsetDiscoveryProvider, fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            Plug.Conn.send_resp(conn, 403, "forbidden")

          _ ->
            conn = Plug.Conn.fetch_query_params(conn)
            page = Enum.slice(rows, String.to_integer(conn.params["offset"]), 3)
            json(conn, page)
        end
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      completed = Repo.get!(Run, run.id)
      assert completed.status == :succeeded
      assert completed.result_count == 3
      assert Agent.get(calls, & &1) == 2
      assert Discovery.state(word.object_id, ctx.slug).status == :ready
    end

    test "declaring one status retryable does not drop the default ones", _ctx do
      assert FakeOffsetDiscoveryProvider.retryable_status?(403)
      assert FakeOffsetDiscoveryProvider.retryable_status?(429)
      assert FakeOffsetDiscoveryProvider.retryable_status?(503)
      refute FakeOffsetDiscoveryProvider.retryable_status?(404)
      refute FakeOffsetDiscoveryProvider.retryable_status?(401)
    end

    test "an abandoned run is recovered by the shared cleanup", ctx do
      word = word!(ctx, "threnody", ~w(wordnet))
      requests = start_supervised!({Agent, fn -> [] end})
      stub_texts(text_rows(5), requests)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)

      run
      |> Run.lifecycle_changeset(%{
        status: :running,
        started_at: DateTime.utc_now(),
        execution_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> Repo.update!()

      assert %{recovered: 1} = Discovery.cleanup()
      assert Repo.get!(Run, run.id).status == :pending

      assert :ok = Discovery.execute_run(run.id)
      assert Discovery.state(word.object_id, ctx.slug).status == :ready
    end
  end

  defp text_rows(count) do
    Enum.map(1..count, fn id ->
      %{"id" => id, "title" => "Elegy #{id}", "year" => "1751"}
    end)
  end

  defp stub_texts(rows, requests) do
    Req.Test.stub(FakeOffsetDiscoveryProvider, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      offset = conn.params["offset"]
      limit = conn.params["limit"]
      Agent.update(requests, &[{conn.method, offset, limit} | &1])

      page = Enum.slice(rows, String.to_integer(offset), String.to_integer(limit))

      # A bare JSON array, which is what a REST text provider returns.
      json(conn, page)
    end)
  end

  defp target(word) do
    %{object_id: word.object_id, term: word.lemma, language: word.language_tag, relevance: "term"}
  end

  defp movie(id, title, opts \\ []) do
    %{
      "tmdbId" => id,
      "imdbId" => nil,
      "title" => title,
      "releaseDate" => Keyword.get(opts, :release_date, "2024-01-01"),
      "posterPath" => Keyword.get(opts, :poster_path, "/poster.jpg"),
      "cinegraphUrl" => "https://cinegraph.org/movies/#{id}"
    }
  end

  defp stub_success(term, keyword_id, movies) do
    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer cinegraph-test-key"]

      if String.contains?(body["query"], "searchMovieKeywords") do
        assert body["variables"]["query"] == term
        keyword_response(conn, term, keyword_id)
      else
        assert body["variables"]["keywords"] == [keyword_id]
        discovery_response(conn, movies, nil, term, keyword_id)
      end
    end)
  end

  defp stub_no_keyword do
    Req.Test.stub(CineGraph, fn conn ->
      json(conn, %{"data" => %{"searchMovieKeywords" => []}})
    end)
  end

  defp keyword_response(conn, term, keyword_id) do
    json(conn, %{
      "data" => %{
        "searchMovieKeywords" => [
          %{"tmdbId" => keyword_id, "name" => term, "movieCount" => 1}
        ]
      }
    })
  end

  defp discovery_response(conn, movies, next_cursor, term \\ "paged", keyword_id \\ 42) do
    edges =
      Enum.map(movies, fn movie ->
        %{
          "cursor" => "cursor-#{movie["tmdbId"]}",
          "node" => %{
            "movie" => movie,
            "matchedKeywords" => [%{"tmdbId" => keyword_id, "name" => term}],
            "matchedGenres" => []
          }
        }
      end)

    json(conn, %{
      "data" => %{
        "discoverMovies" => %{
          "edges" => edges,
          "pageInfo" => %{
            "endCursor" => next_cursor,
            "hasNextPage" => is_binary(next_cursor)
          }
        }
      }
    })
  end

  defp request_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp configure_discovery(overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    Application.put_env(:devils_dictionary, :discovery, Keyword.merge(config, overrides))
  end
end
