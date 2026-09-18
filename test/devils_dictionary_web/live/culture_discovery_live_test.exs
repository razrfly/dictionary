defmodule DevilsDictionaryWeb.CultureDiscoveryLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, Run}
  alias DevilsDictionary.Discovery.Providers.{CineGraph, Met}
  alias DevilsDictionary.FakeOffsetDiscoveryProvider
  alias DevilsDictionary.Repo

  setup %{conn: conn} do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Map.merge(catalog, %{conn: conn, animals: catalog.scopes["animals"]})
  end

  # A test about one provider's shelf registers one provider. The registry is
  # config, and since PoetryDB joined it a page that names no provider admits
  # three runs rather than one — so `Repo.one!(Run)` would be asserting how many
  # providers ship, which is `ProvidersTest`'s job and not this file's.
  defp only(providers) do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, providers)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)
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
    only([CineGraph])
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
    only([CineGraph])
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
    only([CineGraph])
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
    only([CineGraph])
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
             "Relevance to this particular meaning is unverified."
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
    only([CineGraph])
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

  test "a text provider gets its own shelf while the film shelf is unchanged", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    fixture = FakeOffsetDiscoveryProvider

    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, fixture])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    word = word!(ctx, "elegy", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a lament for the dead")
    stub_films_and_texts("elegy", 900, [movie(900, "A filmed lament")])

    {:ok, live, _html} = live(ctx.conn, ~p"/define/elegy")

    for run <- Repo.all(Run), do: assert(:ok = Discovery.execute_run(run.id))
    _ = render(live)

    # The film shelf reads exactly as it did before the content-type table.
    assert has_element?(live, "#culture-filter-film", "Films")
    assert has_element?(live, "#culture-provider-cinegraph", "CineGraph · keywords: TMDb")
    assert has_element?(live, "#culture-result-tmdb_movie-900")
    assert has_element?(live, "#culture-entry-image-900[href^='/entities/']")
    assert has_element?(live, "#culture-result-tmdb_movie-900 .aspect-\\[2\\/3\\]")
    assert has_element?(live, "#culture-result-tmdb_movie-900 img")
    assert has_element?(live, "#culture-about-cinegraph")

    # The text shelf is a second heading with its own label and no image slot.
    assert has_element?(live, "#culture-filter-text", "Texts")

    assert has_element?(
             live,
             "#culture-provider-offset-fixture",
             "Offset fixture · public domain"
           )

    assert has_element?(live, "#culture-result-fixture_text-1", "Elegy 1")
    assert has_element?(live, "#culture-about-offset-fixture")
    refute has_element?(live, "#culture-result-fixture_text-1 img")
    refute has_element?(live, "#culture-missing-poster-1")
    refute has_element?(live, "#culture-entry-image-1")
    assert has_element?(live, "#culture-source-1[href^='https://fixture.invalid/texts/']")
  end

  test "an artwork shelf renders beside the film shelf, matched by tag identity", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, Met])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    word = word!(ctx, "soldier", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet", gloss: "one who serves in an army")
    entity = concept!("Q4991371", "soldier")

    {:ok, _} =
      DevilsDictionary.Claims.assert(sense.object_id, "refers_to", entity.object_id, %{
        confidence: 0.9
      })

    stub_films_and_artworks("soldier", 901, [movie(901, "A filmed enlistment")])

    # The rejected candidate's tag is not the sense's QID, so the broader walk
    # asks Wikidata about it and is told there is no path.
    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        conn.params["ids"]
        |> String.split("|")
        |> Map.new(&{&1, %{"id" => &1, "claims" => %{}}})

      json(conn, %{"entities" => entities})
    end)

    {:ok, live, _html} = live(ctx.conn, ~p"/define/soldier")

    for run <- Repo.all(Run), do: assert(:ok = Discovery.execute_run(run.id))
    _ = render(live)

    # The film shelf is untouched by the Met arriving beside it.
    assert has_element?(live, "#culture-filter-film", "Films")
    assert has_element?(live, "#culture-provider-cinegraph", "CineGraph · keywords: TMDb")
    assert has_element?(live, "#culture-result-tmdb_movie-901")
    assert has_element?(live, "#culture-result-tmdb_movie-901 .aspect-\\[2\\/3\\]")

    # The artwork shelf: its own heading, the Met's own qualifier, and the
    # square aspect the `:artwork` row of the content-type table declares.
    assert has_element?(live, "#culture-filter-artwork", "Artworks")
    assert has_element?(live, "#culture-provider-met", "The Met · tags: Wikidata")
    assert has_element?(live, "#culture-result-met_object-194038", "Watch")
    assert has_element?(live, "#culture-result-met_object-194038 .aspect-square")
    assert has_element?(live, "#culture-result-met_object-194038 img")
    assert has_element?(live, "#culture-source-194038[href^='https://www.metmuseum.org/']")

    # The reason names the tag that actually matched, and its QID — never a
    # phrase composed for the reader.
    assert has_element?(
             live,
             "#culture-about-met",
             "Tagged “Soldiers” (Q4991371), the concept this meaning refers to."
           )

    # The candidate the Met's text search returned and identity rejected.
    refute has_element?(live, "#culture-result-met_object-999")
  end

  test "the live shelf and the committed catalog are one artwork shelf, live first", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, Met])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    word = word!(ctx, "soldier", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet", gloss: "one who serves in an army")
    entity = concept!("Q4991371", "soldier")

    {:ok, _} =
      DevilsDictionary.Claims.assert(sense.object_id, "refers_to", entity.object_id, %{
        confidence: 0.9
      })

    # A committed corpus work depicting the same QID. It is not searched for on
    # this visit; it is already local, and before K2 of #109 it rendered as a
    # tall card in its own section beside the Met's shelf.
    {:ok, %{newly_created: 1}} =
      Manifest.new("wikidata-famous", [
        %{
          "qid" => "Q12418",
          "title" => "Mona Lisa",
          "sitelinks" => 146,
          "image_url" => "https://upload.wikimedia.org/wikipedia/commons/x/Mona.jpg",
          "commons_file" => "Mona Lisa.jpg",
          "credit_line" => "Mona Lisa.jpg · Wikimedia Commons",
          "creators" => [%{"qid" => "Q762", "term" => "Leonardo da Vinci"}],
          "depicts" => [%{"term" => "soldier", "qid" => "Q4991371"}]
        }
      ])
      |> Seeder.run()

    stub_films_and_artworks("soldier", 903, [movie(903, "A filmed enlistment")])

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        conn.params["ids"] |> String.split("|") |> Map.new(&{&1, %{"id" => &1, "claims" => %{}}})

      json(conn, %{"entities" => entities})
    end)

    {:ok, live, _html} = live(ctx.conn, ~p"/define/soldier")
    for run <- Repo.all(Run), do: assert(:ok = Discovery.execute_run(run.id))
    html = render(live)

    catalog_id = DevilsDictionary.Registry.by_external_id("wikidata", "Q12418")

    # Exactly one Artworks shelf, and no tall candidate section anywhere.
    assert html |> String.split(~s(id="culture-filter-artwork")) |> length() == 2
    refute has_element?(live, "#artwork-candidates")

    # Both items are in the same list, and both providers are in its byline.
    assert has_element?(live, "#culture-results-artwork #culture-result-met_object-194038")

    assert has_element?(
             live,
             "#culture-results-artwork #culture-result-catalog_artwork-c#{catalog_id}"
           )

    assert has_element?(live, "#culture-provider-met", "The Met · tags: Wikidata")
    assert has_element?(live, "#culture-provider-catalog", "Saved catalog · Wikidata")

    # And the rail does not scroll-snap: snapping re-snaps a container to its
    # previously snapped box after a layout change, so prepending the live
    # results to the already-painted corpus items opened the shelf past them.
    refute html =~ "snap-x"

    # The live result the page went and got comes before the catalog's.
    {live_at, _} = :binary.match(html, "culture-result-met_object-194038")
    {corpus_at, _} = :binary.match(html, "culture-result-catalog_artwork-c#{catalog_id}")
    assert live_at < corpus_at

    # Each names its own reason, in its own words about its own evidence.
    assert has_element?(
             live,
             "#culture-about-met",
             "Tagged “Soldiers” (Q4991371), the concept this meaning refers to."
           )

    assert has_element?(
             live,
             "#culture-about-catalog",
             "Direct depiction of “soldier” (Q4991371) tagged “soldier”."
           )

    assert has_element?(live, "#culture-about-catalog", "held locally rather than searched for")

    # And the film shelf is still the first shelf on the page.
    {film_at, _} = :binary.match(html, ~s(id="culture-filter-film"))
    {artwork_at, _} = :binary.match(html, ~s(id="culture-filter-artwork"))
    assert film_at < artwork_at
  end

  test "a word the Met cannot match never gets an artwork shelf, even while loading", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph, Met])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    # No `refers_to`, so the Met has no match key and never will for this word.
    word = word!(ctx, "nepotism", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "favouritism to relatives")
    stub_success("nepotism", 902, [movie(902, "A filmed favour")])

    # The very first, disconnected render is where a promise gets made: a
    # "Looking for matching artwork…" that resolves to nothing is worse than no
    # shelf, so the reader asks the same question the admission gate asks.
    html = ctx.conn |> get(~p"/define/nepotism") |> html_response(200)
    refute html =~ "In artwork"
    assert html =~ "In film"

    {:ok, live, _html} = live(ctx.conn, ~p"/define/nepotism")
    for run <- Repo.all(Run), do: assert(:ok = Discovery.execute_run(run.id))
    _ = render(live)

    refute has_element?(live, "#culture-provider-met")
    refute has_element?(live, "#culture-filter-artwork")
    assert has_element?(live, "#culture-filter-film", "Films")
    assert has_element?(live, "#culture-result-tmdb_movie-902")

    # And no run, mapping or request was spent finding that out.
    assert Repo.all(Run) |> Enum.map(& &1.mapping_id) |> Enum.uniq() |> length() == 1
  end

  test "a broader tag says which narrower thing carried it", ctx do
    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [Met])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    word = word!(ctx, "war", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet", gloss: "armed conflict between states")
    entity = concept!("Q198", "War")

    {:ok, _} =
      DevilsDictionary.Claims.assert(sense.object_id, "refers_to", entity.object_id, %{
        confidence: 0.95
      })

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      parents = %{"Q361" => "Q103495", "Q103495" => "Q198"}

      entities =
        conn.params["ids"]
        |> String.split("|")
        |> Map.new(fn qid ->
          claims =
            case parents[qid] do
              nil -> []
              parent -> [%{"mainsnak" => %{"datavalue" => %{"value" => %{"id" => parent}}}}]
            end

          {qid, %{"id" => qid, "claims" => %{"P279" => claims}}}
        end)

      json(conn, %{"entities" => entities})
    end)

    Req.Test.stub(CineGraph, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.params["q"] do
        json(conn, %{"total" => 1, "objectIDs" => [261_944]})
      else
        json(conn, met_object(261_944, "Battlefield at Vaux", [{"World War I", "Q361"}]))
      end
    end)

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")
    for run <- Repo.all(Run), do: assert(:ok = Discovery.execute_run(run.id))
    _ = render(live)

    assert has_element?(live, "#culture-filter-artwork", "Artworks")

    assert has_element?(
             live,
             "#culture-about-met",
             "Related to “War” through the tag “World War I” (Q361)."
           )
  end

  defp stub_films_and_artworks(term, keyword_id, movies) do
    Req.Test.stub(CineGraph, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      cond do
        conn.params["q"] ->
          json(conn, %{"total" => 2, "objectIDs" => [194_038, 999]})

        conn.method == "GET" ->
          case conn.request_path |> Path.basename() |> String.to_integer() do
            194_038 -> json(conn, met_object(194_038, "Watch", [{"Soldiers", "Q4991371"}]))
            999 -> json(conn, met_object(999, "Unrelated teapot", [{"Flowers", "Q506"}]))
          end

        true ->
          graphql_response(conn, term, keyword_id, movies)
      end
    end)
  end

  defp met_object(id, title, tags) do
    %{
      "objectID" => id,
      "title" => title,
      "objectDate" => "ca. 1780",
      "isPublicDomain" => true,
      "primaryImageSmall" => "https://images.metmuseum.org/CRDImages/#{id}.jpg",
      "objectURL" => "https://www.metmuseum.org/art/collection/search/#{id}",
      "creditLine" => "Gift of J. Pierpont Morgan, 1917",
      "artistDisplayName" => "Anonymous",
      "objectWikidata_URL" => "",
      "tags" =>
        Enum.map(tags, fn {term, qid} ->
          %{"term" => term, "Wikidata_URL" => "https://www.wikidata.org/wiki/#{qid}"}
        end)
    }
  end

  defp stub_films_and_texts(term, keyword_id, movies) do
    Req.Test.stub(CineGraph, fn conn ->
      if conn.method == "GET" do
        conn = Plug.Conn.fetch_query_params(conn)
        offset = String.to_integer(conn.params["offset"])
        limit = String.to_integer(conn.params["limit"])

        rows =
          Enum.map(1..5, fn id -> %{"id" => id, "title" => "Elegy #{id}", "year" => "1751"} end)

        json(conn, Enum.slice(rows, offset, limit))
      else
        graphql_response(conn, term, keyword_id, movies)
      end
    end)
  end

  defp stub_success(term, keyword_id, movies) do
    Req.Test.stub(CineGraph, fn conn ->
      graphql_response(conn, term, keyword_id, movies)
    end)
  end

  defp graphql_response(conn, term, keyword_id, movies) do
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
