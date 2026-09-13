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

  # A crash report or a stray `inspect/1` must never print the credential or
  # the bearer token this struct carries.
  @derive {Inspect, except: [:client_secret, :token]}
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
            now_fun: nil,
            availability_fun: nil,
            shared_scope: nil,
            shared_request_limit: nil,
            shared_request_window_ms: nil,
            coordinator: DevilsDictionary.Artsy.RequestCoordinator

  @type t :: %__MODULE__{}

  @doc "Creates a client. Missing credentials produce an explicit authentication failure on use."
  def new(opts \\ []) do
    config = Application.get_env(:devils_dictionary, :artsy, [])
    client_id = opts[:client_id] || config[:client_id]
    client_secret = opts[:client_secret] || config[:client_secret]

    coordinator =
      Keyword.get(
        opts,
        :coordinator,
        Keyword.get(config, :coordinator, DevilsDictionary.Artsy.RequestCoordinator)
      )

    %__MODULE__{
      base_url: opts[:base_url] || config[:endpoint] || @base_url,
      client_id: client_id,
      client_secret: client_secret,
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
      now_fun: opts[:now_fun] || (&DateTime.utc_now/0),
      availability_fun:
        opts[:availability_fun] ||
          fn ->
            DevilsDictionary.Artsy.Availability.status_with_credentials(
              client_id,
              client_secret,
              coordinator
            )
          end,
      shared_scope: opts[:shared_scope],
      shared_request_limit:
        optional_positive!(opts[:shared_request_limit], :shared_request_limit),
      shared_request_window_ms:
        optional_positive!(opts[:shared_request_window_ms], :shared_request_window_ms),
      coordinator: coordinator
    }
  end

  @doc "True when the server has both credentials. Values are never exposed."
  def configured?(%__MODULE__{} = client),
    do: present?(client.client_id) and present?(client.client_secret)

  @doc "True only while configuration and the persisted source lifecycle permit requests."
  def available?(%__MODULE__{} = client),
    do: configured?(client) and client.availability_fun.() == :ok

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
    offset = cursor_offset(opts[:cursor])

    with :ok <- valid_identifier(artwork_id),
         true <- offset != :error do
      collection_page(client, :artists, artwork_id, size, offset)
    else
      _ -> {:error, failure(:invalid_cursor, nil, "/api/artists"), client}
    end
  end

  @doc "Returns direct gene assignments for one work. This is not gene traversal."
  def artwork_genes(client, artwork_id, opts \\ []) do
    size = page_size(opts[:size] || @max_page_size)
    offset = cursor_offset(opts[:cursor])

    with :ok <- valid_identifier(artwork_id),
         true <- offset != :error do
      collection_page(client, :genes, artwork_id, size, offset)
    else
      _ -> {:error, failure(:invalid_cursor, nil, "/api/genes"), client}
    end
  end

  @doc "Fetches one gene by opaque ID or slug for bounded feasibility verification."
  def gene(client, identifier) do
    with :ok <- valid_identifier(identifier) do
      authorized(client, :get, "/api/genes/#{identifier}", [])
    else
      {:error, reason} -> {:error, failure(reason, nil, "/api/genes"), client}
    end
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
               next_cursor: next_cursor(client, next_url, query, size),
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
      "description" => body["blurb"] || body["description"],
      "thumbnail_url" => link(body, "thumbnail"),
      "permalink" => public_link(body, "permalink"),
      "artists_url" => api_link(body, "artists"),
      "genes_url" => api_link(body, "genes"),
      "updated_at" => body["updated_at"],
      "unique" => body["unique"]
    }
  end

  @doc "Normalizes retained artist fields while keeping opaque ID and slug distinct."
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

  @doc "Normalizes the direct gene identity fields used by versioned meaning mappings."
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
    with :ok <- provider_available(client),
         {:ok, client} <- ensure_token(client) do
      do_authorized(client, method, url, opts, false)
    else
      {:error, failure} -> {:error, failure, client}
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
            code =
              if failure.code in [
                   "request_limit",
                   "shared_request_limit",
                   "provider_disabled",
                   "coordinator_unavailable"
                 ],
                 do: failure.code,
                 else: "authentication_unavailable"

            {:error, %{failure | code: code}, client}
        end
    end
  end

  defp request(client, method, url, opts, retry_number, redirects) do
    cond do
      client.request_count >= client.request_limit ->
        {:error, failure(:request_limit, nil, URI.parse(url).path), client}

      provider_available(client) != :ok ->
        {:error, failure(:provider_disabled, nil, URI.parse(url).path), client}

      true ->
        with {:ok, generation, wait_ms} <- acquire(client) do
          client.sleep_fun.(wait_ms)

          with :ok <- await_ready(client, generation),
               :ok <- provider_available(client),
               true <- generation_current?(client, generation) do
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

            response = client.request_fun.(request_opts)

            if generation_current?(client, generation) and provider_available(client) == :ok do
              handle_response(
                response,
                client,
                method,
                url,
                opts,
                retry_number,
                redirects
              )
            else
              {:error, failure(:provider_disabled, nil, URI.parse(url).path), client}
            end
          else
            _ -> {:error, failure(:provider_disabled, nil, URI.parse(url).path), client}
          end
        else
          {:error, :provider_disabled} ->
            {:error, failure(:provider_disabled, nil, URI.parse(url).path), client}

          {:error, :shared_request_limit} ->
            {:error, failure(:shared_request_limit, nil, URI.parse(url).path), client}

          {:error, :coordinator_unavailable} ->
            {:error, failure(:coordinator_unavailable, nil, URI.parse(url).path), client}
        end
    end
  end

  defp handle_response(
         {:ok, %Req.Response{status: 429} = response},
         client,
         method,
         url,
         opts,
         retry_number,
         redirects
       ) do
    case DevilsDictionary.Discovery.Transport.retry_after_seconds(response) do
      seconds when is_integer(seconds) and seconds > 0 ->
        defer(client, seconds * 1_000)

        {:ok, response, client,
         request_meta(retry_number, redirects) |> Map.put(:retry_after_seconds, seconds)}

      _ ->
        retry_response(response, client, method, url, opts, retry_number, redirects)
    end
  end

  defp handle_response(
         {:ok, %Req.Response{status: status} = response},
         client,
         method,
         url,
         opts,
         retry_number,
         redirects
       )
       when status in [500, 502, 503, 504] do
    retry_response(response, client, method, url, opts, retry_number, redirects)
  end

  defp handle_response(
         {:ok, %Req.Response{status: status} = response},
         client,
         _method,
         url,
         opts,
         retry_number,
         redirects
       )
       when status in 300..399 and redirects < 2 do
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
  end

  defp handle_response({:ok, response}, client, _method, _url, _opts, retry_number, redirects),
    do: {:ok, response, client, request_meta(retry_number, redirects)}

  defp handle_response({:error, reason}, client, method, url, opts, retry_number, redirects) do
    if retry_number < client.max_retries do
      client.sleep_fun.(retry_delay(nil, retry_number))

      request(
        %{client | retry_count: client.retry_count + 1},
        method,
        url,
        opts,
        retry_number + 1,
        redirects
      )
    else
      {:error,
       failure(
         transport_code(reason),
         nil,
         URI.parse(url).path,
         request_meta(retry_number, redirects)
       ), client}
    end
  end

  defp retry_response(response, client, method, url, opts, retry_number, redirects) do
    if retry_number < client.max_retries do
      client.sleep_fun.(retry_delay(response, retry_number))

      request(
        %{client | retry_count: client.retry_count + 1},
        method,
        url,
        opts,
        retry_number + 1,
        redirects
      )
    else
      {:ok, response, client, request_meta(retry_number, redirects)}
    end
  end

  defp collection_page(client, kind, artwork_id, size, offset) do
    path = if kind == :artists, do: "/api/artists", else: "/api/genes"

    case authorized(client, :get, path,
           params: [artwork_id: artwork_id, size: size, offset: offset]
         ) do
      {:ok, body, client, meta} ->
        next_url = get_in(body, ["_links", "next", "href"])

        {:ok, body, client,
         Map.merge(meta, %{
           next_cursor: collection_cursor(client, next_url, path, artwork_id),
           returned_next_preserved_filter: query_param(next_url, "artwork_id") == artwork_id
         })}

      error ->
        error
    end
  end

  defp token_fresh?(%{token: token, token_expires_at: nil}), do: present?(token)

  defp token_fresh?(%{token: token, token_expires_at: expires, now_fun: now_fun}) do
    present?(token) and DateTime.compare(expires, DateTime.add(now_fun.(), 60, :second)) == :gt
  end

  defp next_cursor(client, url, query, _size) do
    with true <- is_binary(url),
         uri <- URI.parse(url),
         expected <- URI.parse(client.base_url),
         true <-
           uri.scheme == "https" and uri.host == expected.host and uri.port == expected.port and
             uri.path == "/api/search",
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
      _ when is_map(response.body) -> get_in(response.body, ["_links", "location", "href"])
      _ -> nil
    end
  end

  defp query_param(nil, _key), do: nil

  defp query_param(url, key),
    do: URI.parse(url).query |> then(&URI.decode_query(&1 || "")) |> Map.get(key)

  defp retry_delay(_response, retry_number),
    do: min(trunc(:math.pow(2, retry_number)) * 1_000, 10_000)

  defp request_meta(retries, redirects), do: %{retries: retries, redirects: redirects}

  defp collection_cursor(client, url, path, artwork_id) do
    with true <- is_binary(url),
         uri <- URI.parse(url),
         expected <- URI.parse(client.base_url),
         true <- uri.scheme == "https" and uri.host == expected.host and uri.path == path,
         params <- URI.decode_query(uri.query || ""),
         true <- params["artwork_id"] in [nil, artwork_id],
         {offset, ""} when offset >= 0 <- Integer.parse(params["offset"] || "") do
      Integer.to_string(offset)
    else
      _ -> nil
    end
  end

  defp provider_available(client) do
    case client.availability_fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, failure(reason, nil, "/api")}
      _ -> {:error, failure(:provider_disabled, nil, "/api")}
    end
  end

  defp acquire(%{coordinator: nil}), do: {:ok, 0, 0}

  defp acquire(client) do
    DevilsDictionary.Artsy.RequestCoordinator.acquire(client.coordinator, client.rate_limit_ms,
      scope: client.shared_scope,
      limit: client.shared_request_limit,
      window_ms: client.shared_request_window_ms
    )
  catch
    :exit, _ -> {:error, :coordinator_unavailable}
  end

  defp await_ready(%{coordinator: nil}, _generation), do: :ok

  defp await_ready(client, generation) do
    case DevilsDictionary.Artsy.RequestCoordinator.revalidate(generation, client.coordinator) do
      {:ok, 0} ->
        :ok

      {:ok, wait_ms} ->
        client.sleep_fun.(wait_ms)
        await_ready(client, generation)

      {:error, :provider_disabled} ->
        {:error, :provider_disabled}
    end
  catch
    :exit, _ -> {:error, :provider_disabled}
  end

  defp generation_current?(%{coordinator: nil}, _generation), do: true

  defp generation_current?(client, generation) do
    DevilsDictionary.Artsy.RequestCoordinator.current?(generation, client.coordinator)
  catch
    :exit, _ -> false
  end

  defp defer(%{coordinator: nil}, _milliseconds), do: :ok

  defp defer(client, milliseconds) do
    DevilsDictionary.Artsy.RequestCoordinator.defer(milliseconds, client.coordinator)
  catch
    :exit, _ -> :ok
  end

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
    failure = %{
      code: to_string(code),
      status: status,
      path: path,
      retries: meta[:retries] || 0,
      redirects: meta[:redirects] || 0
    }

    if meta[:retry_after_seconds],
      do: Map.put(failure, :retry_after_seconds, meta[:retry_after_seconds]),
      else: failure
  end

  defp user_agent, do: Application.fetch_env!(:devils_dictionary, :user_agent)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp positive!(value, _name) when is_integer(value) and value > 0, do: value
  defp positive!(_value, name), do: raise(ArgumentError, "#{name} must be positive")
  defp non_negative!(value, _name) when is_integer(value) and value >= 0, do: value
  defp non_negative!(_value, name), do: raise(ArgumentError, "#{name} must be non-negative")
  defp optional_positive!(nil, _name), do: nil
  defp optional_positive!(value, name), do: positive!(value, name)
end
