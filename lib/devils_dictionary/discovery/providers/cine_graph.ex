defmodule DevilsDictionary.Discovery.Providers.CineGraph do
  @moduledoc "CineGraph keyword discovery normalized into provider-neutral culture cards."

  @behaviour DevilsDictionary.Discovery.Provider

  @adapter_version "cinegraph.graphql.v1"
  @operation "keyword_discovery"

  @keyword_query """
  query FindKeywords($query: String!) {
    searchMovieKeywords(query: $query, limit: 10) { tmdbId name movieCount }
  }
  """

  @impl true
  def slug, do: "cinegraph"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "CineGraph",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "TMDb API terms; metadata served by CineGraph",
      license_url: "https://developer.themoviedb.org/docs/faq",
      homepage: "https://cinegraph.org/",
      url_template: "https://cinegraph.org/",
      attribution: "Film metadata and keywords: TMDb; discovery served by CineGraph",
      config: %{
        "operation" => @operation,
        "keyword_source" => "TMDb",
        "preview_storage" => "normalized permitted fields only",
        "poster_delivery" => "TMDb image CDN reference; images are not rehosted"
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :persistent,
      pagination: :cursor,
      operations: [@operation],
      content_types: [:film]
    }
  end

  @impl true
  def enabled? do
    config = config()
    config[:enabled] != false and present?(config[:endpoint]) and present?(config[:api_key])
  end

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "resolution_strategy" => "exact_keyword_v1",
       "relevance" => target.relevance
     }}
  end

  @impl true
  def request_options(payload) do
    config = config()

    [
      url: config[:endpoint],
      json: payload,
      headers: [
        {"authorization", "Bearer #{config[:api_key]}"},
        {"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}
      ]
    ]
  end

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "language" => language,
        "resolution_strategy" => "exact_keyword_v1"
      })
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100 and
             is_binary(language),
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def retrieve(operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(operation, mapping) do
      case request["resolved_keyword_ids"] do
        ids when is_list(ids) and ids != [] -> discover(mapping, request, ids, request_fun)
        _ -> resolve(mapping, request, request_fun)
      end
    else
      {:error, _} -> {:error, "invalid_mapping"}
    end
  end

  defp resolve(mapping, request, request_fun) do
    payload = %{query: @keyword_query, variables: %{query: mapping["term"]}}

    case request_fun.("keyword_lookup", payload) do
      {:ok, %{"errors" => _errors}} ->
        {:error, "provider_graphql_error"}

      {:ok, %{"data" => %{"searchMovieKeywords" => keywords}}} when is_list(keywords) ->
        exact = exact_keywords(keywords, mapping["term"])

        resolved_request =
          request
          |> Map.put("lookup_query", mapping["term"])
          |> Map.put("resolved_keyword_ids", Enum.map(exact, & &1["tmdbId"]))
          |> Map.put("resolved_keywords", exact)
          |> Map.put("keyword_match", if(length(exact) > 1, do: "ANY", else: "ALL"))

        if exact == [] do
          {:ok,
           %{
             request_parameters: resolved_request,
             items: [],
             next_cursor: nil,
             completion_reason: :no_exact_keyword
           }}
        else
          discover(
            mapping,
            resolved_request,
            resolved_request["resolved_keyword_ids"],
            request_fun
          )
        end

      {:ok, _body} ->
        {:error, "malformed_response"}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  defp discover(mapping, request, ids, request_fun) do
    match = if length(ids) > 1, do: "ANY", else: "ALL"
    after_cursor = request["after"]
    first = request["first"]

    query = """
    query Discover($keywords: [Int!], $first: Int!, $after: String) {
      discoverMovies(keywordTmdbIds: $keywords, keywordMatch: #{match}, first: $first, after: $after) {
        edges {
          cursor
          node {
            movie { tmdbId imdbId title releaseDate posterPath cinegraphUrl }
            matchedKeywords { tmdbId name }
            matchedGenres { tmdbId name }
          }
        }
        pageInfo { endCursor hasNextPage }
      }
    }
    """

    payload = %{
      query: query,
      variables: %{keywords: ids, first: first, after: after_cursor}
    }

    case request_fun.("movie_discovery", payload) do
      {:ok, %{"errors" => _errors}} ->
        {:error, "provider_graphql_error"}

      {:ok, %{"data" => %{"discoverMovies" => response}}} when is_map(response) ->
        normalize_discovery(mapping, request, response)

      {:ok, _body} ->
        {:error, "malformed_response"}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  defp normalize_discovery(mapping, request, %{
         "edges" => edges,
         "pageInfo" => page_info
       })
       when is_list(edges) and is_map(page_info) do
    with {:ok, items} <- normalize_edges(edges, mapping) do
      next_cursor = next_cursor(page_info)

      {:ok,
       %{
         request_parameters: request,
         items: items,
         next_cursor: next_cursor,
         completion_reason: if(items == [], do: :no_results, else: :results)
       }}
    end
  end

  defp normalize_discovery(_mapping, _request, _response), do: {:error, "malformed_response"}

  defp normalize_edges(edges, mapping) do
    edges
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edge, position}, {:ok, items} ->
      case normalize_edge(edge, mapping, position) do
        {:ok, item} -> {:cont, {:ok, [item | items]}}
        {:error, code} -> {:halt, {:error, code}}
      end
    end)
    |> case do
      {:ok, items} ->
        items = items |> Enum.reverse() |> Enum.uniq_by(&{&1.external_namespace, &1.external_id})
        {:ok, Enum.with_index(items, &Map.put(&1, :position, &2))}

      error ->
        error
    end
  end

  defp normalize_edge(
         %{
           "node" => %{
             "movie" => %{"tmdbId" => tmdb_id, "title" => title} = movie,
             "matchedKeywords" => keywords,
             "matchedGenres" => genres
           }
         },
         mapping,
         position
       )
       when is_integer(tmdb_id) and tmdb_id > 0 and is_binary(title) and byte_size(title) <= 300 and
              is_list(keywords) and
              is_list(genres) do
    with {:ok, keywords} <- normalize_tags(keywords),
         {:ok, genres} <- normalize_tags(genres) do
      {:ok,
       %{
         external_namespace: "tmdb_movie",
         external_id: Integer.to_string(tmdb_id),
         position: position,
         match_details: %{
           "kind" => "keyword",
           "query" => mapping["term"],
           "keywords" => keywords,
           "genres" => genres
         },
         preview_metadata: %{
           "title" => title,
           "year" => year(movie["releaseDate"]),
           "source_url" => source_url(movie["cinegraphUrl"]),
           "poster_url" => poster_url(movie["posterPath"]),
           "content_type" => "film",
           "provider" => "CineGraph",
           "keyword_source" => "TMDb"
         },
         display_allowed: true
       }}
    end
  end

  defp normalize_edge(_edge, _mapping, _position), do: {:error, "malformed_response"}

  defp exact_keywords(keywords, term) do
    normalized = normalize(term)

    keywords
    |> Enum.filter(fn
      %{"tmdbId" => id, "name" => name} when is_integer(id) and id > 0 and is_binary(name) ->
        normalize(name) == normalized

      _ ->
        false
    end)
    |> Enum.map(&Map.take(&1, ["tmdbId", "name", "movieCount"]))
    |> Enum.uniq_by(& &1["tmdbId"])
    |> Enum.sort_by(& &1["tmdbId"])
  end

  defp normalize_tags(tags) do
    if Enum.all?(tags, fn
         %{"tmdbId" => id, "name" => name}
         when is_integer(id) and id > 0 and is_binary(name) and byte_size(name) <= 200 ->
           true

         _ ->
           false
       end) do
      {:ok, Enum.map(tags, &%{"id" => &1["tmdbId"], "name" => &1["name"]})}
    else
      {:error, "malformed_response"}
    end
  end

  defp next_cursor(%{"hasNextPage" => true, "endCursor" => cursor})
       when is_binary(cursor) and byte_size(cursor) <= 2_048,
       do: cursor

  defp next_cursor(_page_info), do: nil

  defp year(<<year::binary-size(4), _rest::binary>>), do: year
  defp year(_), do: nil

  defp poster_url(path) when is_binary(path) and path != "" do
    case config()[:image_base_url] do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/" <> String.trim_leading(path, "/")

      _ ->
        nil
    end
  end

  defp poster_url(_path), do: nil

  defp source_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in ["cinegraph.org", "cinegraph.app"] -> url
      _ -> nil
    end
  end

  defp source_url(_url), do: nil

  defp normalize(value), do: value |> String.trim() |> String.downcase()
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: Application.fetch_env!(:devils_dictionary, :cinegraph)
end
