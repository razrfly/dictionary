defmodule DevilsDictionary.Discovery.Providers.Pexels do
  @moduledoc """
  Pexels, the fourth source on the Images shelf — a search with a key, and the
  one of the four that never says *nothing*.

  #116 Phase 3, built beside `DevilsDictionary.Discovery.Providers.Unsplash`
  and to the same rules. The reason is a `:query` reason (M6), the `:image`
  row is the only one whose `evidence` admits that class, and the renderer
  describes it as *Search result for “war”, ranked by the provider and not
  matched on an identifier.* There is no `identity_record/1`, so every result
  persists as `:insufficient_evidence`; D1 seeds the source `tier: :plebs` so
  that identity-bearing items lead the rail.

  ## What the licence asks for

  The Pexels License is free for commercial use and asks that photographers
  be credited where possible and that the link back be to Pexels. Both are
  data this module writes: `attribution` is *Photo by {name} on Pexels*,
  `creator_url` is the photographer's Pexels page, `license_url` is the
  licence itself, and `source_url` is the photo's page. D3's renderer turns
  the first two names in that line into links. No UTM: Pexels asks for none,
  and inventing parameters a provider did not ask for is not a courtesy.

  ## Three things the 2026-09-19 probe found (`docs/integrations/pexels.md`)

    * **Pexels has no empty.** Every one of the six words answered thousands
      of results, including *nepotism* — 4,125 of them, led by stock
      illustrations of a handshake and a rejected helping hand. The search
      falls back to something semantic rather than returning nothing, so
      `total_results` is not a measure of relevance and there is no count at
      which this provider says *no*. The shelf's honesty is the labelled
      reason, and nothing else.

    * **There is no title and no date.** A photo carries `alt`, one generated
      sentence describing the picture, and that is every word Pexels
      publishes about it. `alt` was present on all 120 results measured, and
      it is the card's title. There is no creation date anywhere in the
      response, so the card prints no year at all — D5 of #126 made the
      `year · badge` line `badge` alone when there is no year, where it used
      to print *Year unknown* on every one of these cards.

    * **`next_page` is malformed, and a short page is not the last page.**
      Pexels answers `next_page` as
      `https://api.pexels.com/v1/v1/search?page=2&…` — the path segment
      doubled — which 404s, so the cursor is computed from the offset
      instead. And page 2 of `war` returned **19** photos for
      `per_page=20` against 7,737 results: Pexels drops an item from a page
      without ending anything, so the walk ends on an empty page or on
      `total_results`, never on a short one.

  Image bytes are never fetched (D14). `thumbnail_url` is the 350 px rung and
  `image_url` the original on the same CDN, which is also the join key of
  last resort when no identifier is shared.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  @adapter_version "pexels.search.v1"
  @operation "photo_search"

  # The page window when the pipeline names no `first`. Pexels caps
  # `per_page` at 80.
  @default_limit 12
  @max_limit 80

  # `x-ratelimit-limit: 25000` with a reset about a month out on this
  # project's key, so the documented 200/hour is not the limit that binds.
  # 3 s is the same courtesy pace the other providers here keep.
  @request_interval_ms 3_000

  # Pexels sends no `Retry-After`. A floor, not a measurement: no `429` was
  # drawn in the probe.
  @min_retry_interval_ms 60_000

  @license "Pexels"
  @license_url "https://www.pexels.com/license/"

  import DevilsDictionary.Discovery.Provider.Helpers,
    only: [
      clamp_label: 1,
      headers: 0,
      interval: 3,
      limit: 3,
      media_url: 1,
      offset: 1,
      page: 5,
      presence: 1,
      sparse: 1
    ]

  @doc "The identity namespace one Pexels photo is registered under: its numeric id."
  def namespace, do: "pexels_photo"

  @impl true
  def slug, do: "pexels"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Pexels",
      # D1 of #116 Phase 3: a search-only source is a plebs-tier source.
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Pexels License; free to use, credit requested",
      license_url: @license_url,
      homepage: "https://www.pexels.com/",
      logo: "/images/sources/pexels.png",
      url_template: "https://www.pexels.com/photo/{external_id}/",
      attribution: "Photos from Pexels; each carries its photographer's name and a link",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "a text search for the page's term; no identifier is matched",
        "licence_gate" => "none per item: every photo is under the one Pexels License",
        "preview_storage" => "thumbnail and original URL, photographer and licence only",
        "image_delivery" => "images.pexels.com references; images are not rehosted"
      }
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
      content_types: [:image],
      min_retry_interval_ms: interval(config(), :min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(config(), :request_interval_ms, @request_interval_ms)
    }
  end

  @impl true
  def shelf_detail, do: "search: Pexels License"

  @impl true
  def enabled? do
    config = config()

    config[:enabled] != false and is_binary(config[:endpoint]) and
      is_binary(config[:api_key]) and config[:api_key] != ""
  end

  # A keyword provider declines nothing (M6), and this one more literally than
  # the others: it has no empty at all.
  @impl true
  def covers?(_target), do: true

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "photo_search_v1"
     }}
  end

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "resolution_strategy" => "photo_search_v1"
      })
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100,
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def request_options(%{"term" => term, "page" => page, "page_size" => page_size}) do
    [
      method: :get,
      url: config()[:endpoint],
      params: %{
        "query" => term,
        "page" => page,
        "per_page" => page_size
      },
      headers: auth_headers()
    ]
  end

  # The key is Pexels'; the user-agent line is the kit's.
  defp auth_headers do
    [{"authorization", config()[:api_key]} | headers()]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      limit = limit(request["first"], @default_limit, @max_limit)
      offset = offset(request["after"])

      payload = %{
        "term" => mapping["term"],
        "page" => Integer.to_string(div(offset, limit) + 1),
        "page_size" => Integer.to_string(limit)
      }

      case request_fun.(@operation, payload) do
        {:ok, %{"photos" => rows} = body} when is_list(rows) ->
          {:ok, page(mapping, request, rows, offset, limit, body)}

        {:ok, %{"error" => _error}} ->
          {:error, "provider_api_error"}

        {:ok, _body} ->
          {:error, "malformed_response"}

        {:error, code} ->
          {:error, code}

        {:deferred, code, seconds} ->
          {:deferred, code, seconds, request}
      end
    else
      {:error, _reason} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  defp page(mapping, request, rows, offset, limit, body) do
    page(request, rows, offset, next_cursor(rows, offset, limit, body), &item(mapping, &1))
  end

  # One card per upload, the same rule Openverse and Unsplash keep. Measured
  # on six words 2026-09-19 it never fires here: Pexels generates `alt` per
  # photo, so one photographer's eight frames carry eight different sentences.
  # It stays because the rule belongs to the shelf's promise and not to the
  # provider that happens to need it.
  # The walk ends on an empty page, or where `total_results` says it does.
  #
  # Not on a *short* page, which is the rule every other provider here keeps:
  # measured 2026-09-19, `query=war&per_page=20&page=2` answered **19**
  # photos against a `total_results` of 7,737, so Pexels drops an item from a
  # page without ending anything, and "short means last" would have stopped
  # the walk on its second click. `next_page` is in the response and is not
  # used either: Pexels doubles the path segment in it (`/v1/v1/search`), so
  # following it 404s.
  defp next_cursor(rows, offset, limit, body) do
    next = offset + limit

    cond do
      rows == [] -> nil
      is_integer(body["total_results"]) and next >= body["total_results"] -> nil
      true -> Integer.to_string(next)
    end
  end

  # One search hit reduced to what a card and a credit need, or nil when the
  # item may not be shown: no id, no usable URL, or nothing a card could print.
  defp item(mapping, %{"id" => id} = row) when is_integer(id) or (is_binary(id) and id != "") do
    src = row["src"] || %{}

    with title when is_binary(title) <- title(row),
         thumbnail when is_binary(thumbnail) <-
           media_url(src["medium"]) || media_url(src["small"]),
         full when is_binary(full) <-
           media_url(src["original"]) || media_url(src["large2x"]) || thumbnail do
      %{
        external_namespace: namespace(),
        external_id: to_string(id),
        identifiers: [
          %{namespace: namespace(), external_id: to_string(id), metadata: %{"field" => "id"}}
        ],
        position: 0,
        # No identifier was matched, and saying so is the whole of M6.
        match_details: %{
          "kind" => "query",
          "evidence" => "query",
          "query" => mapping["term"],
          "source" => "pexels"
        },
        preview_metadata: preview(row, title, thumbnail, full),
        display_allowed: true
      }
    else
      _ -> nil
    end
  end

  defp item(_mapping, _row), do: nil

  # M4's six fixed names, plus the title and the ladder the `:image` row reads.
  # No `year`: Pexels publishes no date for a photo, and an invented one would
  # be worse than the card saying nothing. Since D5 of #126 the card does say
  # nothing — the badge stands alone — rather than printing *Year unknown*.
  defp preview(row, title, thumbnail, full) do
    creator = presence(row["photographer"])

    %{
      "title" => title,
      "thumbnail_url" => thumbnail,
      # The original file, not the 350 px rung: `Shelf.canonical_media_url/1`
      # compares this and never the derivative.
      "image_url" => full,
      "source_url" => presence(row["url"]),
      "license" => @license,
      "license_url" => @license_url,
      "creator" => creator,
      "creator_url" => presence(row["photographer_url"]),
      "attribution" => attribution(creator),
      "author" => creator,
      "content_type" => "image",
      "provider" => "Pexels"
    }
    |> sparse()
  end

  # The line Pexels asks for. The renderer links the photographer's name to
  # `creator_url` and *Pexels* to `license_url` (D3).
  defp attribution(nil), do: "Photo on Pexels"
  defp attribution(creator), do: "Photo by #{creator} on Pexels"

  @doc """
  What a card can print for a Pexels photo, or `nil`.

  `alt` is the only text Pexels publishes about a photo — one generated
  sentence, present on all 120 results measured across six words on
  2026-09-19. There is no title and no description to prefer over it.
  """
  def title(row) when is_map(row), do: row |> Map.get("alt") |> presence() |> clamp()
  def title(_row), do: nil

  defp clamp(nil), do: nil

  defp clamp(title),
    do: title |> String.replace(~r/\s+/u, " ") |> String.trim() |> clamp_label()

  # An absolute `http(s)` URL or nothing. A relative or malformed one is not a
  # picture we can hotlink, and a scheme we did not ask for is not one we
  # follow.
  # This provider's own stanza; the read is the kit's.
  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:pexels)
end
