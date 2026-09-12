defmodule DevilsDictionary.Artsy.Client do
  @moduledoc """
  Bounded server-side client for the retiring Artsy public REST API.

  A client value owns one request budget and one in-memory XAPP token. Calls
  return the updated client so a Mix import cannot accidentally reset its
  counter. Redirects are followed only within `https://api.artsy.net/api/`,
  retries are capped, and failures contain stable operator-facing codes without
  response bodies, credentials, or tokens.
  """

  @base_url "https://api.artsy.net"
  @max_page_size 50
  @default_request_limit 100
  @default_timeout 10_000
  @default_retries 2
  @default_rate_limit_ms 340

  defstruct base_url: @base_url,
            client_id: nil,
            client_secret: nil,
            token: nil,
            token_expires_at: nil,
            request_count: 0,
            request_limit: @default_request_limit,
            retry_count: 0,
            max_retries: @default_retries,
            timeout_ms: @default_timeout,
            rate_limit_ms: @default_rate_limit_ms,
            request_fun: nil,
            sleep_fun: nil,
            now_fun: nil

  @type t :: %__MODULE__{}

  @doc "Creates a client. Missing credentials produce an explicit authentication failure on use."
  def new(opts \\ []) do
    config = Application.get_env(:devils_dictionary, :artsy, [])

    %__MODULE__{
      base_url: opts[:base_url] || config[:endpoint] || @base_url,
      client_id: opts[:client_id] || config[:client_id],
      client_secret: opts[:client_secret] || config[:client_secret],
      request_limit: positive!(opts[:request_limit] || @default_request_limit, :request_limit),
      max_retries: non_negative!(opts[:max_retries] || @default_retries, :max_retries),
      timeout_ms: positive!(opts[:timeout_ms] || @default_timeout, :timeout_ms),
      rate_limit_ms:
        non_negative!(
          opts[:rate_limit_ms] || config[:rate_limit_ms] || @default_rate_limit_ms,
          :rate_limit_ms
        ),
      request_fun: opts[:request_fun] || (&Req.request/1),
      sleep_fun: opts[:sleep_fun] || (&Process.sleep/1),
      now_fun: opts[:now_fun] || (&DateTime.utc_now/0)
    }
  end

  @doc "True when the server has both credentials. Values are never exposed."
  def configured?(%__MODULE__{} = client),
    do: present?(client.client_id) and present?(client.client_secret)

  @doc "Hydrates one artwork by opaque API ID or validated slug."
  def artwork(client, identifier) do
    with :ok <- valid_identifier(identifier) do
      authorized(client, :get, "/api/artworks/#{identifier}", [])
    else
      {:error, reason} -> {:error, failure(reason, nil, "/api/artworks"), client}
    end
  end

  @doc "Hydrates one artist by opaque API ID or validated slug."
  def artist(client, identifier) do
    with :ok <- valid_identifier(identifier) do
      authorized(client, :get, "/api/artists/#{identifier}", [])
    else
      {:error, reason} -> {:error, failure(reason, nil, "/api/artists"), client}
    end
  end

  @doc "Returns every creator on one hydrated artwork page, bounded by `size`."
  def artwork_artists(client, artwork_id, opts \\ []) do
    size = page_size(opts[:size] || @max_page_size)
    authorized(client, :get, "/api/artists", params: [artwork_id: artwork_id, size: size])
  end

  @doc "Returns direct gene assignments for one work. This is not gene traversal."
  def artwork_genes(client, artwork_id, opts \\ []) do
    size = page_size(opts[:size] || @max_page_size)
    authorized(client, :get, "/api/genes", params: [artwork_id: artwork_id, size: size])
  end

  @doc """
  Searches and hydrates artwork hits.

  Artsy's next link is advisory only. The returned offset is parsed after URL
  validation, while the caller's `q`, `type=artwork`, and bounded `size` are
  rebuilt on the next call. Mixed result types are reported and skipped.
  """
  def search_artworks(client, query, opts \\ []) do
    query = String.trim(query || "")
    size = page_size(opts[:size] || 10)
    offset = cursor_offset(opts[:cursor])

    cond do
      query == "" or byte_size(query) > 200 ->
        {:error, failure(:invalid_query, nil, "/api/search"), client}

      offset == :error ->
        {:error, failure(:invalid_cursor, nil, "/api/search"), client}

      true ->
        case authorized(client, :get, "/api/search",
               params: [q: query, type: "artwork", size: size, offset: offset]
             ) do
          {:ok, body, client, meta} ->
            hits = get_in(body, ["_embedded", "results"]) || []
            {items, client} = hydrate_hits(client, hits)
            next_url = get_in(body, ["_links", "next", "href"])

            {:ok,
             %{
               query: query,
               items: items,
               mixed_type_count: Enum.count(hits, &(&1["type"] != "artwork")),
               next_cursor: next_cursor(next_url, query, size),
               returned_next_preserved_filter: query_param(next_url, "type") == "artwork",
               request_meta: meta
             }, client}

          error ->
            error
        end
    end
  end

  @doc "Normalizes the source fields the application is allowed to reason about."
  def normalize_artwork(body) when is_map(body) do
    %{
      "id" => body["id"],
      "slug" => body["slug"],
      "title" => body["title"],
      "category" => body["category"],
      "medium" => body["medium"],
      "date" => body["date"],
      "collecting_institution" => body["collecting_institution"],
      "image_rights" => body["image_rights"],
      "thumbnail_url" => link(body, "thumbnail"),
      "permalink" => public_link(body, "permalink"),
      "artists_url" => api_link(body, "artists"),
      "genes_url" => api_link(body, "genes"),
      "updated_at" => body["updated_at"],
      "unique" => body["unique"]
    }
  end

  def normalize_artist(body) when is_map(body) do
    %{
      "id" => body["id"],
      "slug" => body["slug"],
      "name" => body["name"],
      "birthday" => body["birthday"],
      "deathday" => body["deathday"],
      "nationality" => body["nationality"],
      "permalink" => public_link(body, "permalink")
    }
  end

  def normalize_gene(body) when is_map(body) do
    %{"id" => body["id"], "name" => body["name"], "type" => body["type"]}
  end

  @doc "A safe Artsy API URL is HTTPS, on the configured host, under `/api/`."
  def safe_api_url?(%__MODULE__{} = client, url) when is_binary(url) do
    expected = URI.parse(client.base_url)
    uri = URI.parse(url)

    uri.scheme == "https" and uri.host == expected.host and uri.port == expected.port and
      String.starts_with?(uri.path || "", "/api/") and is_nil(uri.userinfo)
  end

  def safe_api_url?(_client, _url), do: false

  defp hydrate_hits(client, hits) do
    Enum.map_reduce(hits, client, fn hit, client ->
      cond do
        hit["type"] != "artwork" ->
          {%{status: :unsupported_type, search: search_summary(hit)}, client}

        not safe_api_url?(client, get_in(hit, ["_links", "self", "href"])) ->
          {%{status: :invalid_endpoint, search: search_summary(hit)}, client}

        true ->
          href = get_in(hit, ["_links", "self", "href"])

          case authorized_url(client, :get, href, []) do
            {:ok, body, client, meta} ->
              {%{
                 status: :available,
                 artwork: normalize_artwork(body),
                 search: search_summary(hit),
                 request_meta: meta
               }, client}

            {:error, %{status: 404}, client} ->
              {%{
                 status: :unavailable,
                 search: search_summary(hit),
                 failure: "artwork_not_retrievable"
               }, client}

            {:error, failure, client} ->
              {%{status: :failed, search: search_summary(hit), failure: failure.code}, client}
          end
      end
    end)
  end

  defp search_summary(hit) do
    %{
      "title" => hit["title"],
      "description" => hit["description"],
      "permalink" => public_link(hit, "permalink"),
      "thumbnail_url" => link(hit, "thumbnail")
    }
  end

  defp authorized(client, method, path, opts) do
    url = client.base_url <> path
    authorized_url(client, method, url, opts)
  end

  defp authorized_url(client, method, url, opts) do
    with {:ok, client} <- ensure_token(client) do
      do_authorized(client, method, url, opts, false)
    else
      {:error, failure, client} -> {:error, failure, client}
    end
  end

  defp do_authorized(client, method, url, opts, refreshed?) do
    headers = [{"x-xapp-token", client.token}, {"user-agent", user_agent()}]

    case request(client, method, url, Keyword.put(opts, :headers, headers), 0, 0) do
      {:ok, %Req.Response{status: status, body: body}, client, meta}
      when status in 200..299 and is_map(body) ->
        {:ok, body, client, meta}

      {:ok, %Req.Response{status: 401}, client, _meta} when not refreshed? ->
        case ensure_token(%{client | token: nil, token_expires_at: nil}) do
          {:ok, client} -> do_authorized(client, method, url, opts, true)
          {:error, failure, client} -> {:error, failure, client}
        end

      {:ok, %Req.Response{status: status}, client, meta} ->
        {:error, failure(http_code(status), status, URI.parse(url).path, meta), client}

      {:error, failure, client} ->
        {:error, failure, client}
    end
  end

  defp ensure_token(%__MODULE__{} = client) do
    cond do
      token_fresh?(client) ->
        {:ok, client}

      not configured?(client) ->
        {:error, failure(:credentials_missing, nil, "/api/tokens/xapp_token"), client}

      true ->
        opts = [
          json: %{client_id: client.client_id, client_secret: client.client_secret},
          headers: [{"user-agent", user_agent()}]
        ]

        case request(client, :post, client.base_url <> "/api/tokens/xapp_token", opts, 0, 0) do
          {:ok, %Req.Response{status: status, body: %{"token" => token} = body}, client, _meta}
          when status in [200, 201] and is_binary(token) ->
            {:ok,
             %{
               client
               | token: token,
                 token_expires_at: parse_datetime(body["expires_at"])
             }}

          {:ok, %Req.Response{status: status}, client, meta} ->
            {:error, failure(:authentication_failed, status, "/api/tokens/xapp_token", meta),
             client}

          {:error, failure, client} ->
            {:error, %{failure | code: "authentication_unavailable"}, client}
        end
    end
  end

  defp request(client, method, url, opts, retry_number, redirects) do
    if client.request_count >= client.request_limit do
      {:error, failure(:request_limit, nil, URI.parse(url).path), client}
    else
      client.sleep_fun.(client.rate_limit_ms)
      client = %{client | request_count: client.request_count + 1}

      request_opts =
        [
          method: method,
          url: url,
          redirect: false,
          retry: false,
          receive_timeout: client.timeout_ms,
          connect_options: [timeout: client.timeout_ms]
        ] ++ opts

      case client.request_fun.(request_opts) do
        {:ok, %Req.Response{status: status} = response}
        when status in [429, 500, 502, 503, 504] and retry_number < client.max_retries ->
          delay = retry_delay(response, retry_number)
          client.sleep_fun.(delay)

          request(
            %{client | retry_count: client.retry_count + 1},
            method,
            url,
            opts,
            retry_number + 1,
            redirects
          )

        {:ok, %Req.Response{status: status} = response}
        when status in 300..399 and redirects < 2 ->
          case redirect_url(response) do
            redirect when is_binary(redirect) ->
              if safe_api_url?(client, redirect) do
                request(
                  client,
                  :get,
                  redirect,
                  Keyword.delete(opts, :json),
                  retry_number,
                  redirects + 1
                )
              else
                {:error, failure(:unsafe_redirect, status, URI.parse(url).path), client}
              end

            _ ->
              {:ok, response, client, request_meta(retry_number, redirects)}
          end

        {:ok, response} ->
          {:ok, response, client, request_meta(retry_number, redirects)}

        {:error, _reason} when retry_number < client.max_retries ->
          client.sleep_fun.(retry_delay(nil, retry_number))

          request(
            %{client | retry_count: client.retry_count + 1},
            method,
            url,
            opts,
            retry_number + 1,
            redirects
          )

        {:error, reason} ->
          {:error,
           failure(
             transport_code(reason),
             nil,
             URI.parse(url).path,
             request_meta(retry_number, redirects)
           ), client}
      end
    end
  end

  defp token_fresh?(%{token: token, token_expires_at: nil}), do: present?(token)

  defp token_fresh?(%{token: token, token_expires_at: expires, now_fun: now_fun}) do
    present?(token) and DateTime.compare(expires, DateTime.add(now_fun.(), 60, :second)) == :gt
  end

  defp next_cursor(url, query, _size) do
    with true <- is_binary(url),
         uri <- URI.parse(url),
         true <-
           uri.scheme == "https" and uri.host == "api.artsy.net" and uri.path == "/api/search",
         params <- URI.decode_query(uri.query || ""),
         true <- params["q"] == query,
         {offset, ""} when offset >= 0 <- Integer.parse(params["offset"] || "") do
      Integer.to_string(offset)
    else
      _ -> nil
    end
  end

  defp cursor_offset(nil), do: 0
  defp cursor_offset(value) when is_integer(value) and value >= 0, do: value

  defp cursor_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 and integer <= 10_000 -> integer
      _ -> :error
    end
  end

  defp cursor_offset(_), do: :error
  defp page_size(size) when is_integer(size), do: size |> max(1) |> min(@max_page_size)
  defp page_size(_), do: 10

  defp valid_identifier(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,254}\z/, value),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp valid_identifier(_), do: {:error, :invalid_identifier}

  defp public_link(body, name) do
    case link(body, name) do
      url when is_binary(url) ->
        uri = URI.parse(url)
        if uri.scheme == "https" and uri.host in ["www.artsy.net", "artsy.net"], do: url

      _ ->
        nil
    end
  end

  defp api_link(body, name) do
    case link(body, name) do
      "https://api.artsy.net/api/" <> _ = url -> url
      _ -> nil
    end
  end

  defp link(body, name), do: get_in(body, ["_links", name, "href"])

  defp redirect_url(response) do
    case Req.Response.get_header(response, "location") do
      [url | _] -> url
      _ -> get_in(response.body, ["_links", "location", "href"])
    end
  end

  defp query_param(nil, _key), do: nil

  defp query_param(url, key),
    do: URI.parse(url).query |> then(&URI.decode_query(&1 || "")) |> Map.get(key)

  defp retry_delay(response, retry_number) do
    retry_after =
      if response, do: DevilsDictionary.Discovery.Transport.retry_after_seconds(response)

    min((retry_after || trunc(:math.pow(2, retry_number))) * 1_000, 10_000)
  end

  defp request_meta(retries, redirects), do: %{retries: retries, redirects: redirects}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp http_code(401), do: :authentication_failed
  defp http_code(403), do: :access_forbidden
  defp http_code(404), do: :not_found
  defp http_code(429), do: :quota_exhausted
  defp http_code(status) when status >= 500, do: :provider_unavailable
  defp http_code(_), do: :http_error

  defp transport_code(%Req.TransportError{reason: :timeout}), do: :timeout
  defp transport_code(_), do: :provider_unavailable

  defp failure(code, status, path, meta \\ %{}) do
    %{
      code: to_string(code),
      status: status,
      path: path,
      retries: meta[:retries] || 0,
      redirects: meta[:redirects] || 0
    }
  end

  defp user_agent, do: Application.fetch_env!(:devils_dictionary, :user_agent)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive!(_value, name), do: raise(ArgumentError, "#{name} must be positive")
  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value
  defp non_negative!(_value, name), do: raise(ArgumentError, "#{name} must be non-negative")
end
