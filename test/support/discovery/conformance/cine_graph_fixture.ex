defmodule DevilsDictionary.Discovery.Conformance.CineGraphFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.CineGraph`.

  GraphQL over POST, cursor paging, films, and a two-stage retrieval: the first
  request turns the word into exact TMDb keyword ids and the second discovers
  films by them. The stub answers both from one function, told apart by the
  query text, which is what the provider's own tests do.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.CineGraph

  @term "war"
  @keyword_id 273_967

  @impl true
  def provider, do: CineGraph

  @impl true
  def covered_target(context) do
    word = word!(context, @term, ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # A word with no exact keyword is the provider's own negative answer, and it
    # costs one request rather than two.
    respond(%{0 => {[], nil}}, keywords: [])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    respond(%{0 => {[movie(10), movie(11)], nil}})
    %{pages: [~w(10 11)]}
  end

  def stub(:paged, _context) do
    respond(%{
      0 => {[movie(10), movie(11), movie(12)], "cursor-page-2"},
      1 => {[movie(13), movie(14)], nil}
    })

    %{pages: [~w(10 11 12), ~w(13 14)]}
  end

  # `pages` is keyed by page number, and the page is read off the `after`
  # cursor the previous page handed back — the same opaque string the pipeline
  # carried, so a stub that answered regardless of it would not be testing
  # pagination at all.
  defp respond(pages, opts \\ []) do
    keywords =
      Keyword.get(opts, :keywords, [
        %{"tmdbId" => @keyword_id, "name" => @term, "movieCount" => 3}
      ])

    Req.Test.stub(CineGraph, fn conn ->
      body = request_body(conn)

      if String.contains?(body["query"], "searchMovieKeywords") do
        json(conn, %{"data" => %{"searchMovieKeywords" => keywords}})
      else
        page = if body["variables"]["after"] == "cursor-page-2", do: 1, else: 0
        {movies, next_cursor} = Map.fetch!(pages, page)
        json(conn, discovery(movies, next_cursor))
      end
    end)
  end

  defp discovery(movies, next_cursor) do
    edges =
      Enum.map(movies, fn movie ->
        %{
          "cursor" => "cursor-#{movie["tmdbId"]}",
          "node" => %{
            "movie" => movie,
            "matchedKeywords" => [%{"tmdbId" => @keyword_id, "name" => @term}],
            "matchedGenres" => []
          }
        }
      end)

    %{
      "data" => %{
        "discoverMovies" => %{
          "edges" => edges,
          "pageInfo" => %{
            "endCursor" => next_cursor,
            "hasNextPage" => is_binary(next_cursor)
          }
        }
      }
    }
  end

  defp movie(id) do
    %{
      "tmdbId" => id,
      "imdbId" => nil,
      "title" => "Film #{id}",
      "releaseDate" => "2024-01-01",
      "posterPath" => "/poster-#{id}.jpg",
      "cinegraphUrl" => "https://cinegraph.org/movies/#{id}"
    }
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
