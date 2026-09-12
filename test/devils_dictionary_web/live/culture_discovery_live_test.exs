defmodule DevilsDictionaryWeb.CultureDiscoveryLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, Run}
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Repo

  setup %{conn: conn} do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Map.merge(catalog, %{conn: conn, animals: catalog.scopes["animals"]})
  end

  test "configured GIF shelf mounts automatically without initial search control", ctx do
    original = Application.fetch_env!(:devils_dictionary, :giphy)

    Application.put_env(:devils_dictionary, :giphy,
      enabled: true,
      api_key: "public-giphy-test-key"
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :giphy, original) end)
    word = word!(ctx, "mountain", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a large hill")
    {:ok, view, _} = live(ctx.conn, ~p"/define/mountain")
    assert has_element?(view, "[phx-hook=GiphyShelf][data-query=mountain]")
    assert has_element?(view, "[data-more][hidden]")
    refute has_element?(view, "button", "Find GIFs")
    refute has_element?(view, "[data-api-key='cinegraph-test-key']")
  end

  test "definitions render while discovery is queued, then cards arrive without a page reload",
       ctx do
    word = word!(ctx, "war", ~w(bierce))
    entry!(ctx, word, "bierce", body: "A public definition that must not wait.")
    stub_success("war", 273_967, [movie(301, "Title-independent match")])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

    assert has_element?(live, "#card-bierce")
    assert has_element?(live, "#culture-loading")
    refute has_element?(live, "#culture-results")

    run = Repo.one!(Run)
    assert :ok = Discovery.execute_run(run.id)
    _ = render(live)

    assert has_element?(live, "#culture-results")
    assert has_element?(live, "#culture-result-tmdb_movie-301")
    assert has_element?(live, "#culture-entry-image-301[href^='/entities/']")
    assert has_element?(live, "#culture-entry-title-301[href^='/entities/']")
    assert has_element?(live, "#culture-source-301[href^='https://cinegraph.org/']")
    assert has_element?(live, "#culture-about-cinegraph")
    refute has_element?(live, "#culture-failed")
  end

  test "missing posters use an intentional text treatment", ctx do
    word = word!(ctx, "grief", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "deep sorrow")
    stub_success("grief", 9_872, [movie(302, "Posterless", poster_path: nil)])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/grief")
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)
    _ = render(live)

    assert has_element?(live, "#culture-missing-poster-302")
    refute has_element?(live, "#culture-result-tmdb_movie-302 img")
  end

  test "successful empty and provider failure are visibly distinct", ctx do
    empty = word!(ctx, "empty", ~w(wordnet))
    sense!(ctx, empty, "wordnet", gloss: "having nothing")

    Req.Test.stub(CineGraph, fn conn ->
      json(conn, %{"data" => %{"searchMovieKeywords" => []}})
    end)

    {:ok, empty_live, _html} = live(ctx.conn, ~p"/define/empty")
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)
    _ = render(empty_live)
    assert has_element?(empty_live, "#culture-empty")
    refute has_element?(empty_live, "#culture-failed")

    failure = word!(ctx, "failure", ~w(wordnet))
    sense!(ctx, failure, "wordnet", gloss: "an unsuccessful attempt")
    Req.Test.stub(CineGraph, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    {:ok, failed_live, _html} = live(ctx.conn, ~p"/define/failure")
    run = Repo.one!(from r in Run, order_by: [desc: r.id], limit: 1)
    assert :ok = Discovery.execute_run(run.id)
    _ = render(failed_live)
    assert has_element?(failed_live, "#culture-failed")
    refute has_element?(failed_live, "#culture-empty")
    assert has_element?(failed_live, "#card-wordnet")
  end

  test "invalid routes and demo audit data never create discovery work", ctx do
    {:ok, missing, _html} = live(ctx.conn, ~p"/define/not-a-real-entry")
    assert has_element?(missing, "#no-such-word")
    refute has_element?(missing, "#in-culture")
    assert Repo.aggregate(Mapping, :count) == 0
    assert Repo.aggregate(Run, :count) == 0

    word!(ctx, "audit", ~w(wordnet))
    {:ok, demo, _html} = live(ctx.conn, ~p"/define/audit?demo=1")
    refute has_element?(demo, "#in-culture")
    assert Repo.aggregate(Mapping, :count) == 0
    assert Repo.aggregate(Run, :count) == 0
  end

  test "polysemous resolver pages label spelling-only relevance honestly", ctx do
    noun = word!(ctx, "bank", ~w(wordnet), pos: "noun")
    _verb = word!(ctx, "bank", ~w(wiktionary), pos: "verb")
    sense!(ctx, noun, "wordnet", gloss: "a financial institution")
    stub_success("bank", 77, [movie(303, "Ambiguous match")])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/bank")
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)
    _ = render(live)

    assert has_element?(
             live,
             "#culture-about-cinegraph",
             "Keyword relevance to this particular meaning is unverified."
           )
  end

  test "definition culture renders only film-capable server providers", ctx do
    original = Application.get_env(:devils_dictionary, :discovery_providers)
    fixture = DevilsDictionary.FakeTransientDiscoveryProvider
    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, fixture])

    on_exit(fn ->
      if original,
        do: Application.put_env(:devils_dictionary, :discovery_providers, original),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    word = word!(ctx, "fixture-failure-mixed", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a mixed-provider page")
    stub_success("fixture-failure-mixed", 700, [movie(700, "Still available")])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/fixture-failure-mixed")

    assert [run] = Repo.all(Run)
    assert :ok = Discovery.execute_run(run.id)
    _ = render(live)

    assert has_element?(live, "#culture-filter-film", "Films")
    refute has_element?(live, "#culture-filter-art")
    assert has_element?(live, "#culture-results #culture-result-tmdb_movie-700")
    refute has_element?(live, "#culture-failed-transient-fixture")
    assert has_element?(live, "#card-wordnet")
  end

  test "mounted pages remove cached previews when provider eligibility is revoked", ctx do
    word = word!(ctx, "deactivated-live", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "visible until policy changes")
    stub_success("deactivated-live", 701, [movie(701, "Policy preview")])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/deactivated-live")
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)
    _ = render(live)
    assert has_element?(live, "#culture-result-tmdb_movie-701")

    assert {:ok, %{active: false}} = Discovery.set_provider_active("cinegraph", false)
    _ = render(live)
    refute has_element?(live, "#in-culture")
    assert has_element?(live, "#card-wordnet")
  end

  test "mounted pages ignore updates from non-film providers", ctx do
    original = Application.get_env(:devils_dictionary, :discovery_providers)
    fixture = DevilsDictionary.FakeTransientDiscoveryProvider
    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, fixture])

    on_exit(fn ->
      if original,
        do: Application.put_env(:devils_dictionary, :discovery_providers, original),
        else: Application.delete_env(:devils_dictionary, :discovery_providers)
    end)

    word = word!(ctx, "stale-event", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a current definition")
    stub_success("stale-event", 702, [movie(702, "Current film")])
    {:ok, live, _html} = live(ctx.conn, ~p"/define/stale-event")

    stale_item = %{
      external_namespace: "fixture_art",
      external_id: "stale",
      match_details: %{},
      preview_metadata: %{"title" => "Stale", "content_type" => "art"}
    }

    send(
      live.pid,
      {:discovery_updated, word.object_id, -1, fixture.slug(), [stale_item]}
    )

    _ = render(live)
    refute has_element?(live, "#culture-result-fixture_art-stale")
    refute has_element?(live, "#culture-filter-art")
  end

  defp movie(id, title, opts \\ []) do
    %{
      "tmdbId" => id,
      "imdbId" => nil,
      "title" => title,
      "releaseDate" => "2024-01-01",
      "posterPath" => Keyword.get(opts, :poster_path, "/poster.jpg"),
      "cinegraphUrl" => "https://cinegraph.org/movies/#{id}"
    }
  end

  defp stub_success(term, keyword_id, movies) do
    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        json(conn, %{
          "data" => %{
            "searchMovieKeywords" => [
              %{"tmdbId" => keyword_id, "name" => term, "movieCount" => length(movies)}
            ]
          }
        })
      else
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
              "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
            }
          }
        })
      end
    end)
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
end
