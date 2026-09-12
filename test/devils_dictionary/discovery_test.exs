defmodule DevilsDictionary.DiscoveryTest do
  use DevilsDictionary.DataCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

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
    state = Discovery.state(word.object_id)

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
    assert Repo.aggregate(Object, :count) == object_count

    assert {:cached, %Run{id: cached_id}} = Discovery.request(target(word), "cinegraph")
    assert cached_id == run.id
    assert Repo.aggregate(Run, :count) == 1
  end

  test "successful no-keyword and no-film responses are negative caches, not failures", ctx do
    unknown = word!(ctx, "unfindable", ~w(wordnet))
    stub_no_keyword()

    assert {:queued, run} = Discovery.request(target(unknown), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert %{status: :empty, empty_reason: :no_exact_keyword} = Discovery.state(unknown.object_id)
    assert {:cached, _} = Discovery.request(target(unknown), "cinegraph")
    assert Repo.get!(Run, run.id).request_count == 1

    barren = word!(ctx, "barren", ~w(wordnet))
    stub_success("barren", 99, [])

    assert {:queued, run} = Discovery.request(target(barren), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert %{status: :empty, empty_reason: :no_results} = Discovery.state(barren.object_id)
    assert Repo.get!(Run, run.id).request_count == 2
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
    assert Discovery.state(slow.object_id).status == :failed

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

    assert [%Result{external_id: "2"}] = Discovery.state(word.object_id).items
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
    state = Discovery.state(word.object_id)
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
    state = Discovery.state(word.object_id)
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

  test "refresh-due previews remain usable, hard expiry and withdrawal do not", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    refreshable = word!(ctx, "refreshable", ~w(wordnet))
    configure_discovery(refresh_seconds: 0, hard_expiry_seconds: 3_600)
    stub_success("refreshable", 8, [movie(8, "Still visible")])
    assert {:queued, run} = Discovery.request(target(refreshable), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert %{status: :ready, refresh_due: true} = Discovery.state(refreshable.object_id)
    assert {:queued, _refresh} = Discovery.request(target(refreshable), "cinegraph")
    assert Discovery.state(refreshable.object_id).status == :ready

    [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
    assert {1, _} = Discovery.withdraw_result(result.id)
    assert %{status: :empty, empty_reason: :withdrawn} = Discovery.state(refreshable.object_id)

    expired = word!(ctx, "expired", ~w(wordnet))
    configure_discovery(refresh_seconds: 0, hard_expiry_seconds: 0)
    stub_success("expired", 9, [movie(9, "Must not display")])
    assert {:queued, run} = Discovery.request(target(expired), "cinegraph")
    assert :ok = Discovery.execute_run(run.id)
    assert Discovery.state(expired.object_id).status == :expired
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

  test "queue and rolling request budgets defer work without creating unbounded attempts", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)

    configure_discovery(queue_cap: 1, request_budget_per_minute: 1)
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

    assert [%Result{external_id: "501"}] = Discovery.state(financial.object_id).items
    assert [%Result{external_id: "502"}] = Discovery.state(riverside.object_id).items
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
             Discovery.state(word.object_id).items

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

  test "retired, split and merged targets suspend discovery at domain and database boundaries",
       ctx do
    word = word!(ctx, "retired", ~w(wordnet))
    assert {:queued, run} = Discovery.request(target(word), "cinegraph")
    mapping = Repo.get!(Mapping, run.mapping_id)
    {:ok, _event} = Registry.retire(word.object_id, reason: "test")

    assert {:error, :invalid_target} = Discovery.request(target(word), "cinegraph")
    assert Discovery.state(word.object_id).status == :idle

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
    assert {:queued, _run} = Discovery.request(target(split_input), "cinegraph")

    assert {:ok, _event} =
             Registry.split(split_input.object_id, [split_a.object_id, split_b.object_id],
               reason: "test split"
             )

    assert {:error, :invalid_target} = Discovery.request(target(split_input), "cinegraph")
    assert Discovery.state(split_input.object_id).status == :idle

    merged_input = word!(ctx, "merged-input", ~w(wordnet))
    merged_output = word!(ctx, "merged-output", ~w(wordnet))
    assert {:queued, _run} = Discovery.request(target(merged_input), "cinegraph")

    assert {:ok, _event} =
             Registry.merge([merged_input.object_id], merged_output.object_id,
               reason: "test merge"
             )

    assert {:error, :invalid_target} = Discovery.request(target(merged_input), "cinegraph")
    assert Discovery.state(merged_input.object_id).status == :idle
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
