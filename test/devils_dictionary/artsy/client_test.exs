defmodule DevilsDictionary.Artsy.ClientTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Artsy.Client

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

  defp client(responses, opts \\ []) do
    calls = start_supervised!({Agent, fn -> [] end})
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
        [
          client_id: "fixture-id",
          client_secret: "fixture-secret",
          request_fun: request_fun,
          sleep_fun: fn _ -> :ok end,
          rate_limit_ms: 0
        ] ++ opts
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
end
