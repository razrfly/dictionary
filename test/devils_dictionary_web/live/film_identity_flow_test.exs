defmodule DevilsDictionaryWeb.FilmIdentityFlowTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Result, Run}
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Repo

  setup %{conn: conn} do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Map.merge(catalog, %{conn: conn, animals: catalog.scopes["animals"]})
  end

  test "definition → film card → local film → connected definition is a reversible flow", ctx do
    mountain = word!(ctx, "mountain", ~w(wordnet))
    mountain_sense = sense!(ctx, mountain, "wordnet", gloss: "a very high natural elevation")
    grief = word!(ctx, "grief", ~w(wiktionary))
    grief_sense = sense!(ctx, grief, "wiktionary", gloss: "deep and lasting sorrow")
    rejected = word!(ctx, "ship", ~w(wordnet))
    ship_sense = sense!(ctx, rejected, "wordnet", gloss: "a large seagoing vessel")

    stub_titanic("mountain")
    {:ok, definition_live, _html} = live(ctx.conn, ~p"/define/mountain")
    assert :ok = Discovery.execute_run(Repo.one!(Run).id)
    _ = render(definition_live)

    result = Repo.one!(Result)
    assert result.resolution_state == :newly_created
    assert result.object_id
    assert Registry.by_external_id("tmdb_movie", "597") == result.object_id
    assert Registry.by_external_id("imdb_title", "tt0120338") == result.object_id

    assert {:error, {:live_redirect, %{to: stable_path}}} =
             live(ctx.conn, "/entities/#{result.object_id}/an-old-title")

    assert stable_path == "/entities/#{result.object_id}/titanic"

    accepted = illustrates!(result.object_id, mountain_sense, "Its scale evokes this meaning.")
    accepted_revision = Claims.current_revision(accepted.id)

    {:ok, review_context} =
      Claims.open_review_context(
        accepted_revision.id,
        Claims.current_context_items(accepted_revision)
      )

    {:ok, _review} =
      Claims.review(accepted_revision.id, :accepted, review_context_id: review_context.id)

    pending = illustrates!(result.object_id, grief_sense, "A proposed thematic connection.")
    hidden = illustrates!(result.object_id, ship_sense, "A rejected title-only reading.")
    {:ok, _review} = Claims.review(Claims.current_revision(hidden.id).id, :rejected)

    local_path =
      "/entities/#{result.object_id}/titanic?from=%2Fwords%2F#{mountain.object_id}%2Fmountain"

    assert has_element?(
             definition_live,
             "#culture-entry-image-597[href='#{local_path}']"
           )

    assert has_element?(
             definition_live,
             "#culture-entry-title-597[href='#{local_path}']",
             "Titanic"
           )

    assert has_element?(
             definition_live,
             "#culture-source-597[href='https://cinegraph.org/movies/597']"
           )

    {:ok, film_live, film_html} =
      definition_live
      |> element("#culture-entry-title-597")
      |> render_click()
      |> follow_redirect(ctx.conn)

    assert film_html =~ "Titanic"
    assert has_element?(film_live, "#entity-header")
    assert has_element?(film_live, "#entity-artwork img")

    assert has_element?(
             film_live,
             "#entity-back-link[href='/words/#{mountain.object_id}/mountain']"
           )

    assert has_element?(film_live, "#entity-source-cinegraph")
    assert has_element?(film_live, "#entity-discovery-appearances", "Automatic match")
    assert has_element?(film_live, "#entity-meaning-connections", "2 total")
    assert has_element?(film_live, "#connection-out-#{accepted.id}", "Reviewed connection")
    assert has_element?(film_live, "#connection-out-#{accepted.id}", mountain_sense_gloss())
    assert has_element?(film_live, "#connection-out-#{pending.id}", "Awaiting review")
    assert has_element?(film_live, "#connection-out-#{pending.id}", "deep and lasting sorrow")
    refute has_element?(film_live, "#connection-out-#{hidden.id}")

    {:ok, returned_live, _html} =
      film_live
      |> element("#connection-out-#{accepted.id} a[href^='/words/']")
      |> render_click()
      |> follow_redirect(ctx.conn)

    assert has_element?(returned_live, "#headword", "mountain")

    assert {:ok, _withdrawn} = Claims.withdraw(pending.id, reason: "connection removed")
    {:ok, refreshed, _html} = live(ctx.conn, "/entities/#{result.object_id}/titanic")
    assert has_element?(refreshed, "#connection-out-#{accepted.id}")
    refute has_element?(refreshed, "#connection-out-#{pending.id}")
    assert Repo.get!(Registry.Entity, result.object_id).preferred_label == "Titanic"

    assert {:ok, %{active: false}} = Discovery.set_provider_active("cinegraph", false)
    {:ok, withdrawn_source, _html} = live(ctx.conn, "/entities/#{result.object_id}/titanic")
    assert has_element?(withdrawn_source, "#connection-out-#{accepted.id}")
    refute has_element?(withdrawn_source, "#entity-source-cinegraph")
    refute has_element?(withdrawn_source, "#entity-discovery-appearances")
    assert Repo.get!(Registry.Entity, result.object_id).preferred_label == "Titanic"
  end

  defp mountain_sense_gloss, do: "a very high natural elevation"

  defp illustrates!(film_id, sense, rationale) do
    {:ok, assertion} =
      Claims.assert(film_id, "illustrates", sense.object_id, %{
        method: "curated",
        rationale: rationale
      })

    assertion
  end

  defp stub_titanic(term) do
    movie =
      DevilsDictionary.Fixtures.raw("cinegraph", "films")
      |> Enum.find(&(&1["tmdbId"] == 597))

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        json(conn, %{
          "data" => %{
            "searchMovieKeywords" => [%{"tmdbId" => 1, "name" => term, "movieCount" => 1}]
          }
        })
      else
        json(conn, %{
          "data" => %{
            "discoverMovies" => %{
              "edges" => [
                %{
                  "cursor" => "titanic",
                  "node" => %{
                    "movie" => movie,
                    "matchedKeywords" => [%{"tmdbId" => 1, "name" => term}],
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
