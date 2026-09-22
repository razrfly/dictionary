defmodule DevilsDictionary.Discovery.Providers.Unsplash do
  @moduledoc """
  Unsplash, the third source on the Images shelf — a search with a key, and a
  licence whose one condition is a **linked** credit.

  #116 Phase 3. Commons reaches a page by identity (`P180` depicts a QID a
  sense refers to); Openverse and this provider reach one by text, and M6 is
  the rule that lets them: the reason is a `:query` reason, the `:image` row
  is the only one whose `evidence` admits that class, and the renderer
  describes it as *Search result for “war”, ranked by the provider and not
  matched on an identifier.* Nothing here proposes an encyclopedia identity —
  there is no `identity_record/1`, so every result persists as
  `:insufficient_evidence`, which is what a text match deserves. D1 seeds the
  source `tier: :plebs` for the same reason: an identity-bearing item leads
  the rail wherever one exists, and search results follow.

  ## What the licence asks for, and where each part of it is

  The Unsplash License lets us show the photo; the API Guidelines set the
  conditions, and all three are met by data this module writes rather than by
  a component:

    * **A credit naming the photographer and Unsplash.** `attribution` is
      *Photo by {name} on Unsplash*, shown verbatim beneath the thumbnail and
      never on hover (M4).
    * **Both names are links, with UTM.** `creator_url` is the photographer's
      profile and `license_url` is Unsplash's own page, each carrying
      `?utm_source=devils_dictionary&utm_medium=referral`; `source_url` is the
      photo's page with the same parameters. D3 made the linked credit the
      rule for every provider on the row rather than an Unsplash special
      case, so the renderer links `creator` and `license` wherever an item
      carries the URLs and shows plain text where it does not.
    * **The download endpoint is triggered when a reader carries the photo
      somewhere — and never on display.** `download_location` is persisted on
      the item and `track_download/2` is the only thing that fires it, guarded
      to `https://api.unsplash.com/photos/` so a URL out of a response can
      never point the request somewhere else. **Nothing calls it yet**, which
      is correct: showing a search result is not a download, and the reader
      has no path that carries an Unsplash photo anywhere. See the moduledoc
      note below.

  ## Four things the 2026-09-19 probe found (`docs/integrations/unsplash.md`)

    * **There is no title.** An Unsplash photo has a `description` the
      photographer may have written (null on 3 to 10 of every 20 results) and
      an `alt_description` generated for accessibility, and nothing else a
      card can print. `title/1` prefers the human one and falls back to the
      generated one; over 120 results across six words, **no item had
      neither**.

    * **The key is a production key, not a demo one.** Every response carries
      `x-ratelimit-limit: 5000`, so the 50/hour the issue sized this provider
      to is not the limit that binds. `request_interval_ms` is still 3,000 ms
      — the pace is a courtesy, and a reader-driven site behind a 30-day
      positive cache never approaches 5,000/hour anyway (M8).

    * **A photographer's set arrives as several items**, the same defect
      Openverse showed: *soldier* returned two ids by HIZIR KAYA under one
      identical description. `Shelf.dedup/2` cannot fold them — they are not
      the same file — so the provider keeps one card per `{creator, title}`
      inside its own page. Not perceptual dedup (M3 rules that out): an exact
      match on two fields it already carries.

    * **The search degrades rather than empties.** *nepotism* answers 69
      results, of which the top three are a purple gradient, the letter *n*
      and a Notion icon. Unsplash will not say *nothing*, so a low count is
      the only signal there is, and the shelf's honesty comes from the
      labelled reason rather than from the provider declining.

  Image bytes are never fetched (D14). `thumbnail_url` is Unsplash's 400 px
  rung and `image_url` the full-size file on the same CDN, which is also the
  join key of last resort when no identifier is shared.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  require Logger

  @adapter_version "unsplash.search.v1"
  @operation "photo_search"

  # The page window when the pipeline names no `first`. Unsplash caps
  # `per_page` at 30.
  @default_limit 12
  @max_limit 30

  # `x-ratelimit-limit: 5000` on this project's key. 3 s is the same courtesy
  # pace every other keyless provider here keeps; see the moduledoc.
  @request_interval_ms 3_000

  # Unsplash's window is the hour and it sends no `Retry-After`, so a refusal
  # is worth waiting a minute on before trying again. A floor, not a
  # measurement: no `403 Rate Limit Exceeded` was drawn in the probe.
  @min_retry_interval_ms 60_000

  # Every link back to Unsplash carries these, as the API Guidelines require.
  @utm %{"utm_source" => "devils_dictionary", "utm_medium" => "referral"}

  # The Unsplash License, the same for every photo: there is no per-item
  # licence field to gate on, unlike Commons and Openverse.
  @license "Unsplash"
  @license_page "https://unsplash.com/license"

  # The one host `track_download/2` may ever be pointed at.
  @download_prefix "https://api.unsplash.com/photos/"

  import DevilsDictionary.Discovery.Provider.Helpers,
    only: [
      headers: 0,
      interval: 3,
      iso_year: 1,
      limit: 3,
      media_url: 1,
      offset: 1,
      page: 5,
      presence: 1,
      sparse: 1,
      clamp_label: 1
    ]

  @doc "The identity namespace one Unsplash photo is registered under: its id."
  def namespace, do: "unsplash_photo"

  @doc "The Unsplash License page, with the UTM parameters every link back carries."
  def license_url, do: utm(@license_page)

  @impl true
  def slug, do: "unsplash"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Unsplash",
      # D1 of #116 Phase 3: a search-only source is a plebs-tier source, so an
      # identity-bearing item leads the rail wherever one exists.
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Unsplash License; free to use, credit required",
      license_url: @license_page,
      homepage: "https://unsplash.com/",
      logo: "/images/sources/unsplash.png",
      url_template: "https://unsplash.com/photos/{external_id}",
      attribution: "Photos from Unsplash; each carries its photographer's name and a link",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "a text search for the page's term; no identifier is matched",
        "licence_gate" => "none per item: every photo is under the one Unsplash License",
        "preview_storage" =>
          "thumbnail and full-size URL, photographer, licence and the download trigger only",
        "image_delivery" => "images.unsplash.com references; images are not rehosted"
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
  def shelf_detail, do: "search: Unsplash License"

  @impl true
  def enabled? do
    config = config()

    config[:enabled] != false and is_binary(config[:endpoint]) and
      is_binary(config[:access_key]) and config[:access_key] != ""
  end

  # A keyword provider declines nothing (M6). There is no cheaper existence
  # query than the search itself, and a word Unsplash has nothing for is a
  # negative cache rather than a decline.
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
        "per_page" => page_size,
        # Unsplash's own safety filter; the stricter of the two values it
        # offers, because a dictionary page is not an opt-in context.
        "content_filter" => "high"
      },
      headers: auth_headers()
    ]
  end

  # The key and the version are Unsplash's; the user-agent line is the kit's.
  defp auth_headers do
    [
      {"authorization", "Client-ID #{config()[:access_key]}"},
      {"accept-version", "v1"} | headers()
    ]
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
        {:ok, %{"results" => rows} = body} when is_list(rows) ->
          {:ok, page(mapping, request, rows, offset, limit, body)}

        {:ok, %{"errors" => _errors}} ->
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

  # One card per upload, where an upload is one photographer's one title.
  # Measured on *soldier* 2026-09-19: two ids by HIZIR KAYA under one
  # identical description, which `Shelf.dedup/2` cannot fold because they are
  # not the same file. An item missing either field keeps its own id and folds
  # with nobody.
  # A short page is the last page, and so is `total_pages`, which Unsplash
  # answers against a `total` it does not cap: *love* reports 10,000 results
  # over 500 pages. Asking for the page past the last one answers an empty
  # list rather than an error, so this is thrift rather than correctness.
  defp next_cursor(rows, offset, limit, body) do
    next = offset + limit
    page = div(offset, limit) + 1

    cond do
      length(rows) < limit -> nil
      is_integer(body["total_pages"]) and page >= body["total_pages"] -> nil
      true -> Integer.to_string(next)
    end
  end

  # One search hit reduced to what a card and a credit need, or nil when the
  # item may not be shown: no id, no usable URL, or nothing a card could print.
  defp item(mapping, %{"id" => id} = row) when is_binary(id) and id != "" do
    urls = row["urls"] || %{}

    with title when is_binary(title) <- title(row),
         thumbnail when is_binary(thumbnail) <-
           media_url(urls["small"]) || media_url(urls["regular"]),
         full when is_binary(full) <-
           media_url(urls["full"]) || media_url(urls["raw"]) || thumbnail do
      %{
        external_namespace: namespace(),
        external_id: id,
        identifiers: [
          %{namespace: namespace(), external_id: id, metadata: %{"field" => "id"}}
        ],
        position: 0,
        # No identifier was matched, and saying so is the whole of M6.
        match_details: %{
          "kind" => "query",
          "evidence" => "query",
          "query" => mapping["term"],
          "source" => "unsplash"
        },
        preview_metadata: preview(row, title, thumbnail, full),
        display_allowed: true
      }
    else
      _ -> nil
    end
  end

  defp item(_mapping, _row), do: nil

  # M4's six fixed names, plus the title, the ladder the `:image` row reads and
  # the download trigger the licence asks for when a reader carries the photo.
  defp preview(row, title, thumbnail, full) do
    user = row["user"] || %{}
    creator = presence(user["name"]) || presence(user["username"])

    %{
      "title" => title,
      "year" => iso_year(row["created_at"]),
      "thumbnail_url" => thumbnail,
      # The full-size file, not the 400 px rung: `Shelf.canonical_media_url/1`
      # compares this and never the derivative.
      "image_url" => full,
      "source_url" => utm(presence(get_in(row, ["links", "html"]))),
      "license" => @license,
      "license_url" => license_url(),
      "creator" => creator,
      "creator_url" => utm(presence(get_in(user, ["links", "html"]))),
      "attribution" => attribution(creator),
      "author" => creator,
      # Fired only when a reader carries the photo somewhere, by
      # `track_download/2` and nothing else. Persisted because the endpoint is
      # per-photo and expires from nothing: it is part of the item.
      "download_location" => download_location(row),
      "content_type" => "image",
      "provider" => "Unsplash"
    }
    |> sparse()
  end

  # The line the API Guidelines ask for, word for word. The renderer links the
  # photographer's name to `creator_url` and *Unsplash* to `license_url` (D3),
  # so the rendered credit is the guideline's own markup without this module
  # writing any.
  defp attribution(nil), do: "Photo on Unsplash"
  defp attribution(creator), do: "Photo by #{creator} on Unsplash"

  @doc """
  What a card can print for an Unsplash photo, or `nil`.

  There is no title. `description` is what the photographer wrote and is
  absent on a third to a half of any page; `alt_description` is generated for
  accessibility and reads like it (*man in brown and black camouflage uniform
  holding rifle*), but it is a true sentence about the picture and it is
  always there. Measured over 120 results across six words on 2026-09-19: no
  item carried neither.
  """
  def title(row) when is_map(row) do
    (presence(row["description"]) || presence(row["alt_description"]))
    |> clamp()
  end

  def title(_row), do: nil

  defp clamp(nil), do: nil

  defp clamp(title),
    do: title |> String.replace(~r/\s+/u, " ") |> String.trim() |> clamp_label()

  defp download_location(row) do
    case presence(get_in(row, ["links", "download_location"])) do
      nil -> nil
      url -> if String.starts_with?(url, @download_prefix), do: url, else: nil
    end
  end

  @doc """
  Fires Unsplash's download endpoint for one persisted item, or refuses.

  The API Guidelines require this call when an application does something
  equivalent to a download — when a reader **carries** the photo somewhere —
  and explicitly not when one is merely displayed. `url` comes out of a
  provider response, so it is checked against
  `https://api.unsplash.com/photos/` before anything is sent: a URL a response
  chose is a URL an attacker may have chosen, and the one thing this guard
  buys is that a compromised or mistaken `download_location` cannot point this
  server at an arbitrary host with the key attached.

  Returns `:ok` when Unsplash accepted the trigger, `{:error, :refused}` when
  the URL is not one this function may call, and `{:error, reason}` otherwise.
  Nothing on a page calls it: `DevilsDictionaryWeb.Culture`'s composer link
  needs a resolved `object_id` and a `sense_id`, and a search-only provider
  proposes no identity, so no reader path carries an Unsplash photo yet. The
  mechanism is here, guarded and tested, for the phase that adds one.
  """
  @spec track_download(map() | String.t() | nil, keyword()) :: :ok | {:error, term()}
  def track_download(item, opts \\ [])

  def track_download(%{preview_metadata: %{"download_location" => url}}, opts),
    do: track_download(url, opts)

  def track_download(url, opts) when is_binary(url) do
    if String.starts_with?(url, @download_prefix) do
      request =
        [url: url, headers: headers()]
        |> Keyword.merge(Application.get_env(:devils_dictionary, :discovery_req_options, []))
        |> Keyword.merge(opts)

      case Req.get(request) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, status}
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning("unsplash: refused a download trigger outside #{@download_prefix}")
      {:error, :refused}
    end
  end

  def track_download(_item, _opts), do: {:error, :refused}

  # Every link back to Unsplash carries the referral parameters the API
  # Guidelines require, and a URL that already has a query keeps it.
  defp utm(nil), do: nil

  defp utm(url) when is_binary(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    %{uri | query: URI.encode_query(Map.merge(query, @utm))} |> URI.to_string()
  end

  # An absolute `http(s)` URL or nothing. A relative or malformed one is not a
  # picture we can hotlink, and a scheme we did not ask for is not one we
  # follow.
  # This provider's own stanza; the read is the kit's.
  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:unsplash)
end
