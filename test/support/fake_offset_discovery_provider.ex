defmodule DevilsDictionary.FakeOffsetDiscoveryProvider do
  @moduledoc """
  A third provider shape: plain GET, offset paging, and a `:text` content type.

  CineGraph is GraphQL over POST, cursor-paged, and returns films. Everything
  the shared pipeline does was written against that one shape. This fixture is
  the counter-example that keeps the shared code honest — it exercises
  admission, budget, cache, pagination, persistence, cleanup and the reader
  without any of them being told which provider it is.

  Paging stays cursor-shaped on purpose: `next_cursor` is opaque to
  `DevilsDictionary.Discovery`, so an offset provider simply returns its next
  offset as that string and reads it back out of `request["after"]`.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  alias DevilsDictionary.Discovery.Transport

  @operation "text_search"
  @endpoint "https://fixture.invalid/texts"

  @impl true
  def slug, do: "offset-fixture"

  @impl true
  def adapter_version, do: "offset.fixture.v1"

  @impl true
  def enabled?, do: true

  @doc "The URL the fixture's Req.Test stub answers on."
  def endpoint, do: @endpoint

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Offset fixture",
      tier: :middle,
      kind: :corpus,
      access: :api,
      license: "Test fixture only",
      homepage: "https://fixture.invalid/",
      url_template: "https://fixture.invalid/texts/{external_id}",
      attribution: "Controlled fixture; not a live provider",
      active: true,
      config: %{}
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :persistent,
      pagination: :offset,
      operations: [@operation],
      content_types: [:text],
      # Met-shaped again: a provider that throttles has to be retried slower
      # than the shared 250 ms floor, or the retry collects the same refusal.
      min_retry_interval_ms: 40
    }
  end

  @impl true
  def shelf_detail, do: "public domain"

  # Met-shaped: a keyless API that answers a throttled request with 403 and no
  # Retry-After. Treating that as an authentication verdict would fail a run
  # that one more bounded attempt completes. The rest of the rule is delegated
  # rather than restated.
  @impl true
  def retryable_status?(403), do: true
  def retryable_status?(status), do: Transport.default_retryable_status?(status)

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "resolution_strategy" => "literal_search_v1",
       "relevance" => target.relevance
     }}
  end

  @impl true
  def validate_mapping(@operation, %{"term" => term}) when is_binary(term) and term != "", do: :ok
  def validate_mapping(_operation, _mapping), do: {:error, :invalid_mapping}

  @impl true
  def request_options(payload) do
    [
      method: :get,
      url: @endpoint,
      params: %{
        q: payload["term"],
        offset: payload["offset"],
        limit: payload["limit"]
      }
    ]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      offset = offset(request["after"])
      limit = request["first"] || 3

      payload = %{
        "term" => mapping["term"],
        "offset" => Integer.to_string(offset),
        "limit" => Integer.to_string(limit)
      }

      case request_fun.(@operation, payload) do
        # The provider returns a bare JSON array, so the shared transport has to
        # accept a list body as a well-formed answer.
        {:ok, rows} when is_list(rows) ->
          normalize(mapping, request, rows, offset, limit)

        {:ok, _body} ->
          {:error, "malformed_response"}

        {:error, code} ->
          {:error, code}

        {:deferred, code, seconds} ->
          {:deferred, code, seconds, request}
      end
    else
      {:error, _} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  defp normalize(mapping, request, rows, offset, limit) do
    items =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %{
          external_namespace: "fixture_text",
          external_id: to_string(row["id"]),
          position: index,
          match_details: %{"kind" => "text", "query" => mapping["term"]},
          preview_metadata: %{
            "title" => row["title"],
            "year" => row["year"],
            "source_url" => "#{@endpoint}/#{row["id"]}",
            "content_type" => "text",
            "provider" => "Offset fixture"
          },
          display_allowed: true
        }
      end)

    {:ok,
     %{
       request_parameters: Map.put(request, "offset", Integer.to_string(offset)),
       items: items,
       # A full page means there is at least one more; the next offset is the
       # whole of the cursor this provider understands.
       next_cursor: if(length(rows) == limit, do: Integer.to_string(offset + limit)),
       completion_reason: if(items == [], do: :no_results, else: :results)
     }}
  end

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end
end
