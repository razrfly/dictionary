defmodule DevilsDictionary.Artsy.ClientTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Artsy.{Client, RequestCoordinator}

  test "reports stale search hits and rebuilds pagination with the artwork filter" do
    responses = [
      response(201, %{"token" => "fixture-token"}),
      response(200, %{
        "_embedded" => %{
          "results" => [
            %{
              "type" => "artwork",
              "title" => "Missing work",
              "_links" => %{
                "self" => %{"href" => "https://api.artsy.net/api/artworks/missing-work"},
                "permalink" => %{"href" => "https://www.artsy.net/artwork/missing-work"}
              }
            }
          ]
        },
        "_links" => %{
          "next" => %{"href" => "https://api.artsy.net/api/search?q=war&size=1&offset=1"}
        }
      }),
      response(404, %{}),
      response(200, %{"_embedded" => %{"results" => []}, "_links" => %{}})
    ]

    {client, calls} = client(responses)
    assert {:ok, first, client} = Client.search_artworks(client, "war", size: 1)
    assert [%{status: :unavailable}] = first.items
    assert first.next_cursor == "1"
    refute first.returned_next_preserved_filter

    assert {:ok, _second, _client} =
             Client.search_artworks(client, "war", size: 1, cursor: first.next_cursor)

    requests = Agent.get(calls, &Enum.reverse/1)
    second_search = Enum.at(requests, 3)
    assert second_search[:params][:q] == "war"
    assert second_search[:params][:type] == "artwork"
    assert second_search[:params][:offset] == 1
  end

  test "caps 429 retries and counts every request" do
    responses = [
      response(201, %{"token" => "fixture-token"}),
      response(429, %{}) |> Req.Response.put_header("retry-after", "0"),
      artwork_response("work-one")
    ]

    {client, _calls} = client(responses, max_retries: 1)
    assert {:ok, body, client, %{retries: 1}} = Client.artwork(client, "work-one")
    assert body["slug"] == "work-one"
    assert client.request_count == 3
    assert client.retry_count == 1
  end

  test "terminal 429 remains a quota failure after the bounded retry" do
    responses = [
      response(201, %{"token" => "fixture-token"}),
      response(429, %{}) |> Req.Response.put_header("retry-after", "0"),
      response(429, %{}) |> Req.Response.put_header("retry-after", "0")
    ]

    {client, _calls} = client(responses, max_retries: 1)
    assert {:error, %{code: "quota_exhausted"}, client} = Client.artwork(client, "work-one")
    assert client.request_count == 3
    assert client.retry_count == 1
  end

  test "refreshes an expired token once after 401" do
    responses = [
      response(201, %{"token" => "first"}),
      response(401, %{}),
      response(201, %{"token" => "second"}),
      artwork_response("work-one")
    ]

    {client, _calls} = client(responses)
    assert {:ok, _body, client, _meta} = Client.artwork(client, "work-one")
    assert client.token == "second"
    assert client.request_count == 4
  end

  test "rejects cross-host redirects without sending credentials there" do
    redirect =
      response(302, %{}) |> Req.Response.put_header("location", "https://example.test/api/stolen")

    {client, calls} = client([response(201, %{"token" => "fixture-token"}), redirect])

    assert {:error, %{code: "unsafe_redirect"}, client} = Client.artwork(client, "work-one")
    assert client.request_count == 2
    assert length(Agent.get(calls, & &1)) == 2
  end

  test "a redirect with a non-map body and no location fails without crashing" do
    {client, _calls} =
      client([response(201, %{"token" => "fixture-token"}), response(302, "moved")])

    assert {:error, %{code: "http_error", status: 302}, _client} =
             Client.artwork(client, "work-one")
  end

  test "fails closed when the request budget is consumed by authentication" do
    {client, _calls} = client([response(201, %{"token" => "fixture-token"})], request_limit: 1)
    assert {:error, %{code: "request_limit"}, client} = Client.artwork(client, "work-one")
    assert client.request_count == 1
  end

  test "normalization keeps opaque ids and slugs separate" do
    normalized = Client.normalize_artwork(response_body("work-one"))
    assert normalized["id"] == "opaque-1"
    assert normalized["slug"] == "work-one"
    refute normalized["id"] == normalized["slug"]
  end

  test "Retry-After is retained in full and shared with every client" do
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil, interval_ms: 0, now_fun: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    response = response(429, %{}) |> Req.Response.put_header("retry-after", "120")

    {client, _calls} =
      client([response(201, %{"token" => "fixture-token"}), response],
        coordinator: coordinator
      )

    assert {:error, %{code: "quota_exhausted"}, _client} = Client.artwork(client, "work-one")
    assert RequestCoordinator.stats(coordinator).next_at == 120_000
  end

  test "shared coordinator serializes attempts across otherwise independent clients" do
    # System.monotonic_time/1 may be negative; initialization must use the same
    # clock rather than assuming a zero epoch and sleeping for years.
    clock = start_supervised!({Agent, fn -> -1_000 end}, id: make_ref())

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil, interval_ms: 250, now_fun: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    assert {:ok, generation, 0} = RequestCoordinator.acquire(coordinator, 250)
    assert {:ok, ^generation, 250} = RequestCoordinator.acquire(coordinator, 250)
    assert RequestCoordinator.stats(coordinator).attempts == 2

    assert {:ok, _new_generation} = RequestCoordinator.disable(coordinator)
    refute RequestCoordinator.current?(generation, coordinator)
    assert {:error, :provider_disabled} = RequestCoordinator.acquire(coordinator, 250)

    assert :ok = RequestCoordinator.enable(coordinator)
    assert {:ok, _generation, 0} = RequestCoordinator.acquire(coordinator, 250)
  end

  test "shared coordinator enforces one allowance across independent clients" do
    coordinator =
      start_supervised!({RequestCoordinator, name: nil, interval_ms: 0}, id: make_ref())

    shared = [coordinator: coordinator, shared_scope: :interactive, shared_request_limit: 2]

    {first, _first_calls} =
      client([response(201, %{"token" => "fixture-token"}), artwork_response("work-one")], shared)

    assert {:ok, _body, first, _meta} = Client.artwork(first, "work-one")
    assert first.request_count == 2

    {second, second_calls} = client([response(201, %{"token" => "unused"})], shared)

    assert {:error, %{code: "shared_request_limit"}, second} =
             Client.artwork(second, "work-two")

    assert second.request_count == 0
    assert Agent.get(second_calls, & &1) == []
    assert RequestCoordinator.stats(coordinator).scope_attempts == %{interactive: 2}
  end

  test "shared allowances renew independently from finite client import ceilings" do
    clock = start_supervised!({Agent, fn -> 5_000 end}, id: make_ref())

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil, interval_ms: 0, now_fun: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    opts = [scope: :interactive, limit: 2, window_ms: 1_000]
    assert {:ok, generation, 0} = RequestCoordinator.acquire(coordinator, 0, opts)
    assert {:ok, ^generation, 0} = RequestCoordinator.acquire(coordinator, 0, opts)
    assert {:error, :shared_request_limit} = RequestCoordinator.acquire(coordinator, 0, opts)

    Agent.update(clock, &(&1 + 1_000))
    assert {:ok, ^generation, 0} = RequestCoordinator.acquire(coordinator, 0, opts)
    assert RequestCoordinator.stats(coordinator).scope_attempts == %{interactive: 1}
  end

  test "concurrent clients cannot race past a shared allowance" do
    coordinator =
      start_supervised!({RequestCoordinator, name: nil, interval_ms: 0}, id: make_ref())

    {client, calls} =
      client([artwork_response("work-one")],
        coordinator: coordinator,
        shared_scope: :interactive,
        shared_request_limit: 1
      )

    client = %{
      client
      | token: "fixture-token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    results =
      1..8
      |> Task.async_stream(
        fn index -> Client.artwork(client, "work-#{index}") end,
        max_concurrency: 8,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _, _, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{code: "shared_request_limit"}, _}, &1)
           ) == 7

    assert length(Agent.get(calls, & &1)) == 1
  end

  test "a missing coordinator fails closed before authentication leaves the server" do
    {client, calls} =
      client([response(201, %{"token" => "unused"})], coordinator: :missing_artsy_coordinator)

    # An absent coordinator is refused at the availability boundary, which is
    # earlier than the reservation. `Availability` reports an unreachable
    # coordinator as a withdrawn source whether or not the database is
    # readable; what matters here is that nothing leaves the server.
    assert {:error, %{code: "source_withdrawn"}, client} =
             Client.artwork(client, "work-one")

    assert client.request_count == 0
    assert Agent.get(calls, & &1) == []
  end

  test "a queued request is cancelled before transmission when the provider is disabled" do
    coordinator =
      start_supervised!({RequestCoordinator, name: nil, interval_ms: 50}, id: make_ref())

    assert {:ok, _generation, 0} = RequestCoordinator.acquire(coordinator, 50)

    sleep_fun = fn wait_ms ->
      if wait_ms > 0, do: RequestCoordinator.disable(coordinator)
      :ok
    end

    {client, calls} =
      client([response(201, %{"token" => "unused"})],
        coordinator: coordinator,
        sleep_fun: sleep_fun
      )

    assert {:error, %{code: "provider_disabled"}, client} =
             Client.artwork(client, "work-one")

    assert client.request_count == 0
    assert Agent.get(calls, & &1) == []
  end

  test "Retry-After deferrals delay clients that already share the coordinator" do
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil, interval_ms: 0, now_fun: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    quota = response(429, %{}) |> Req.Response.put_header("retry-after", "2")

    {first, _calls} =
      client([response(201, %{"token" => "fixture-token"}), quota], coordinator: coordinator)

    assert {:error, %{code: "quota_exhausted"}, _client} = Client.artwork(first, "work-one")

    sleep_fun = fn milliseconds ->
      Agent.update(sleeps, &[milliseconds | &1])
      Agent.update(clock, &(&1 + milliseconds))
    end

    {second, _calls} =
      client([response(201, %{"token" => "second-token"}), artwork_response("work-two")],
        coordinator: coordinator,
        sleep_fun: sleep_fun
      )

    assert {:ok, _body, _client, _meta} = Client.artwork(second, "work-two")
    assert 2_000 in Agent.get(sleeps, & &1)
  end

  defp client(responses, opts \\ []) do
    calls = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    queue = start_supervised!({Agent, fn -> responses end}, id: make_ref())

    request_fun = fn options ->
      Agent.update(calls, &[options | &1])

      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, %Req.TransportError{reason: :timeout}}, []}
      end)
    end

    client =
      Client.new(
        Keyword.merge(
          [
            client_id: "fixture-id",
            client_secret: "fixture-secret",
            request_fun: request_fun,
            sleep_fun: fn _ -> :ok end,
            rate_limit_ms: 0
          ],
          opts
        )
      )

    {client, calls}
  end

  defp artwork_response(slug), do: response(200, response_body(slug))

  defp response_body(slug) do
    %{
      "id" => "opaque-1",
      "slug" => slug,
      "title" => "Fixture Work",
      "category" => "Painting",
      "_links" => %{"permalink" => %{"href" => "https://www.artsy.net/artwork/#{slug}"}}
    }
  end

  defp response(status, body), do: %Req.Response{status: status, body: body}

  test "inspecting a client never prints the credential or the token" do
    client =
      Client.new(
        client_id: "fixture-id",
        client_secret: "fixture-secret-value",
        coordinator: nil
      )

    client = %{client | token: "fixture-xapp-token-value"}
    printed = inspect(client)

    assert printed =~ "fixture-id"
    refute printed =~ "fixture-secret-value"
    refute printed =~ "fixture-xapp-token-value"
  end

  test "search hits of another type or on a foreign endpoint are labeled, never fetched" do
    responses = [
      response(201, %{"token" => "fixture-token"}),
      response(200, %{
        "_embedded" => %{
          "results" => [
            %{
              "type" => "artist",
              "title" => "Some Artist",
              "_links" => %{
                "self" => %{"href" => "https://api.artsy.net/api/artists/some-artist"}
              }
            },
            %{
              "type" => "artwork",
              "title" => "Elsewhere",
              "_links" => %{"self" => %{"href" => "https://evil.example.test/api/artworks/x"}}
            },
            %{
              "type" => "artwork",
              "title" => "Downgraded",
              "_links" => %{"self" => %{"href" => "http://api.artsy.net/api/artworks/y"}}
            }
          ]
        },
        "_links" => %{}
      })
    ]

    {client, calls} = client(responses)
    assert {:ok, result, _client} = Client.search_artworks(client, "war", size: 3)

    assert Enum.map(result.items, & &1.status) ==
             [:unsupported_type, :invalid_endpoint, :invalid_endpoint]

    # Token and search only: none of the three hits was fetched.
    assert length(Agent.get(calls, & &1)) == 2
  end

  test "only https URLs on the configured host under /api/ without userinfo are safe" do
    client = Client.new(client_id: "id", client_secret: "secret", coordinator: nil)

    assert Client.safe_api_url?(client, "https://api.artsy.net/api/artworks/x")
    refute Client.safe_api_url?(client, "http://api.artsy.net/api/artworks/x")
    refute Client.safe_api_url?(client, "https://api.artsy.net:8443/api/artworks/x")
    refute Client.safe_api_url?(client, "https://api.artsy.net/artworks/x")
    refute Client.safe_api_url?(client, "https://user:pw@api.artsy.net/api/artworks/x")
    refute Client.safe_api_url?(client, "https://www.artsy.net/api/artworks/x")
    refute Client.safe_api_url?(client, nil)
  end

  test "a response that arrives after withdrawal is discarded, never published" do
    coordinator =
      start_supervised!({RequestCoordinator, name: nil, interval_ms: 0}, id: make_ref())

    queue =
      start_supervised!(
        {Agent,
         fn -> [response(201, %{"token" => "fixture-token"}), artwork_response("work-one")] end},
        id: make_ref()
      )

    transmitted = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    request_fun = fn options ->
      Agent.update(transmitted, &(&1 + 1))
      reply = Agent.get_and_update(queue, fn [r | rest] -> {{:ok, r}, rest} end)
      # Withdrawal lands while the artwork request is in flight.
      if String.contains?(options[:url], "/api/artworks/"),
        do: RequestCoordinator.disable(coordinator)

      reply
    end

    {client, _calls} = client([], coordinator: coordinator, request_fun: request_fun)

    assert {:error, %{code: "provider_disabled"}, _client} = Client.artwork(client, "work-one")
    assert Agent.get(transmitted, & &1) == 2
  end
end
