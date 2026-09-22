defmodule DevilsDictionary.Discovery.Providers.Spotify do
  @moduledoc """
  Spotify's catalogue search — the first source on the Music shelf, and the
  first provider here whose request needs a credential the API itself issues.

  #143, from the correction in `docs/audits/2026-09-21-api-saturation-audit.md`
  §5. `GET https://api.spotify.com/v1/search?q=<term>&type=track` with a
  Client Credentials bearer token answers tracks with cover art, an artist, an
  album year, an ISRC and a link back to `open.spotify.com`. Nothing plays:
  `preview_url` was `null` on **every one of the 1,000 tracks** the probe saw,
  which is what the 2024-11-27 change did to an app registered after it, and
  the card does not pretend otherwise.

  ## The search proposes, the title disposes

  A catalogue search is a ranking, not a claim: `q=war` answers *Warm Safe
  Place*, *Warmth* and *warning signs (interlude)* above half the tracks
  actually called *War*. The gate is the whole-word Unicode-boundary match
  `DevilsDictionary.Discovery.Providers.BingNews.matched_text/2` applies to a
  headline, asked of `name`, and everything it does not keep is dropped. So
  *Warrior* and *Warlock* are not on the shelf for *war*.

  The reason that survives is still a `:query` reason and says so — *Search
  result for “war”, ranked by the provider and not matched on an identifier.*
  — because the gate proves the title contains the word and nothing more. The
  `:music` row admits `:query` for that reason and admits `:identity` for the
  follow-up that will not be a search: a Wikidata song whose `P921` is the
  page's QID.

  ## Why one request fetches fifty and shows twelve

  The gate is expensive in candidates. Measured 2026-09-21 over 23 words at
  `limit=50`: a median of 29 of 50 rows survive, but *folly* kept **1** and
  *greed* kept 8, while at `limit=12` *war* kept 6 and *logomachy* 4. Asking
  for fifty and showing the twelve that pass fills the shelf in one request
  where asking for twelve would have filled half of it — and Spotify's own
  `next` is unreliable to page into (`total` was 62 for *war* at `limit=50`
  and 18 for the same word at `offset=12`), so a second page is a worse way
  to spend a request than a wider first one. `@scan_window` is that fifty,
  which is also the API's maximum `limit`.

  The offset in the cursor is therefore an offset into the **gated** list, as
  PoetryDB's and Bing's are, and not the API's own.

  ## `market=US`, which is a decision and not a requirement

  The documentation the issue quotes says `market` is required with Client
  Credentials. **It is not**: `q=war&type=track` with no `market` at all
  answered `200` with twelve tracks (probe P5b). It is pinned anyway, because
  the market decides *which* catalogue is searched and the difference is not
  cosmetic: the same query kept 6 tracks at `market=US` and **2** at
  `market=GB`, where *War* by Chief Keef, *War with Us* and *War Ready* are
  simply not in the catalogue. `US` is the larger answer and the one that
  makes a captured fixture reproducible from another desk.

  ## Two identifiers, because a second source is coming

  Every item carries `spotify_track` (the track id, Wikidata `P2207`) and,
  when the response has one, `isrc` (`external_ids.isrc`, Wikidata `P1243`) —
  present on 100% of the tracks measured. MusicBrainz joins this shelf next
  (#116), and a recording with the same ISRC folds into the same card through
  `DevilsDictionary.Discovery.Shelf.dedup/2` without either provider knowing
  about the other.

  No `identity_record/1`, as Openverse and Bing: a search result proposes no
  encyclopedia identity, so every result persists as `:insufficient_evidence`.

  ## What the policy asks for, and where each part of it is

  The Developer Policy's two obligations are data this module writes, not a
  rule a reviewer remembers:

    * *If you display any Spotify Content you must clearly attribute the
      content as being supplied and made available by Spotify, by using the
      Spotify Marks.* → the mark itself under `"brand_mark"` on every item; the `:music`
      row is `attribution: :required` and the card renders the mark beside the
      credit, at the Branding Guidelines' minimum size and exclusion zone.
    * *Metadata, cover art and Audio Preview Clips must be accompanied by a
      link back to the applicable album, content or playlist on the Spotify
      Service.* → `source_url` is `external_urls.spotify` and the card's link
      reads *Listen on Spotify*, which is one of the three strings the
      Branding Guidelines permit.

  Cover art is hotlinked from `i.scdn.co` at the 300 px and 64 px rungs and no
  bytes are held (D14). The Developer Terms' caching clause — quoted in full
  in `docs/integrations/spotify.md` — caps nothing with a number but says *Do
  not store Spotify Content indefinitely*, so the shelf takes
  `positive_refresh_seconds: 86_400` rather than the shipped thirty days.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  alias DevilsDictionary.Discovery.Providers.Spotify.Token

  @adapter_version "spotify.search.v1"
  @operation "track_search"

  @namespace "spotify_track"
  @isrc_namespace "isrc"

  # The catalogue searched. A decision, not a requirement — see the moduledoc.
  @default_market "US"

  # The Spotify Marks the Branding Guidelines require beside the content: the
  # full logo, black on the light theme and white on the dark (the green one
  # is allowed only on black or white, and the card's dark surface is
  # neither), and one of the three link wordings the guidelines permit —
  # *OPEN SPOTIFY*, *PLAY ON SPOTIFY* or *LISTEN ON SPOTIFY*. #143's brief
  # asked for *Open on Spotify*, which is not one of them.
  @brand_mark %{
    "light" => "/images/spotify-full-logo-black.svg",
    "dark" => "/images/spotify-full-logo-white.svg",
    "alt" => "Spotify",
    "link" => "Listen on Spotify"
  }

  # How many rows one request asks Spotify for, before the gate. Fifty is the
  # API's maximum `limit` and the measurement in the moduledoc.
  @scan_window 50

  # How many gated tracks one page carries when the pipeline names no limit.
  @default_limit 12

  # Measured 2026-09-21: twenty distinct words at 1 req/s all answered `200`
  # (min/median/max 477/563/748 ms), and ten issued at once — 10.8 req/s —
  # also all answered `200`. No `429` and no `Retry-After` was drawn at any
  # rate this probe could reach, so 250 ms is a courtesy and not a throttle
  # the provider was forced to. It is the issue's number and the probe found
  # no reason to widen it.
  @request_interval_ms 250

  # Spotify's window is a rolling thirty seconds whose size it does not
  # publish, and a refusal carries `Retry-After` which `Transport` obeys
  # before this ever applies. A posture for the case where it does not: a
  # refusal from an undisclosed window is not worth retrying into at the
  # shared 250 ms floor.
  @min_retry_interval_ms 30_000

  @doc "The identity namespace one Spotify track is registered under."
  def namespace, do: @namespace

  @doc "The namespace an ISRC is registered under, shared with MusicBrainz (#116)."
  def isrc_namespace, do: @isrc_namespace

  @doc "How many rows one request asks for before the whole-word gate runs."
  def scan_window, do: @scan_window

  @impl true
  def slug, do: "spotify"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Spotify",
      # The recording industry's catalogue is an institution rather than the
      # crowd, and this shelf's place in the turns once MusicBrainz joins it.
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license:
        "Spotify Developer Terms and Developer Policy; metadata and cover art " <>
          "displayed with the Spotify mark and a link back",
      license_url: "https://developer.spotify.com/policy",
      homepage: "https://open.spotify.com/",
      url_template: "https://open.spotify.com/track/{external_id}",
      attribution: "Spotify",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "a text search of the catalogue; no identifier is matched",
        "verification" => "whole-word match of the term in the track name",
        "market" => @default_market,
        "preview_storage" =>
          "track and album metadata, cover-art URLs and the ISRC only; no audio, no bytes",
        "image_delivery" => "i.scdn.co references; cover art is not rehosted"
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
      content_types: [:music],
      min_retry_interval_ms: interval(:min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(:request_interval_ms, @request_interval_ms)
    }
  end

  # Overridable for the same reason every other provider's pace is: an
  # interval is a live-rate courtesy, and a suite that paid it would spend a
  # quarter-second per stubbed request being polite to a server it never calls.
  defp interval(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  @impl true
  def shelf_detail, do: "catalogue search"

  @doc """
  True when both credentials are configured and the switch is not off.

  `SPOTIFY_ENABLED=false` turns the shelf off without a deploy, as
  `BING_NEWS_ENABLED` does, and a host with neither key registers the provider
  and never runs it — which is what a deployment without the credentials
  should do: no keyless calls, no half-configured source on a page.
  """
  @impl true
  def enabled? do
    config = config()

    config[:enabled] != false and is_binary(config[:endpoint]) and
      is_binary(config[:token_endpoint]) and present?(config[:client_id]) and
      present?(config[:client_secret])
  end

  # No `covers?/1`. The default `true` is right: any word can be searched for
  # in a catalogue, and a word whose tracks all fail the gate is an honest
  # empty the pipeline caches as a negative rather than a failure.
  #
  # No `identity_record/1` and no `mapping_identity/1`: see the moduledoc.

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "track_search_v1"
     }}
  end

  @impl true
  def validate_mapping(@operation, %{"term" => term, "resolution_strategy" => "track_search_v1"})
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100,
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @doc """
  The two requests this provider makes, told apart by their payload.

  The token is a `POST` to the accounts host with the app's id and secret in
  HTTP Basic; the search is a `GET` to the API host with the cached bearer.
  Both go through `DevilsDictionary.Discovery.Transport`, so both are paced,
  budgeted, retried and recorded the same way.

  The credential is read here, at the moment the request is built, and reaches
  nothing else: not an assign, not a URL, not a log line, not the
  `request_parameters` this run persists.
  """
  @impl true
  def request_options(%{"grant" => "client_credentials"}) do
    config = config()
    basic = Base.encode64("#{config[:client_id]}:#{config[:client_secret]}")

    [
      method: :post,
      url: config[:token_endpoint],
      form: [grant_type: "client_credentials"],
      headers: [
        {"authorization", "Basic #{basic}"},
        {"user-agent", user_agent()}
      ]
    ]
  end

  def request_options(%{"term" => term, "offset" => offset, "limit" => limit}) do
    [
      method: :get,
      url: config()[:endpoint],
      params: %{
        # Bare, not quoted, and not field-filtered. Measured over the four
        # shapes the issue named, on *war*, *love* and *logomachy* at
        # `limit=12`: bare kept 19 of the 36 rows it was given, `"war"` 16 of
        # 31, `track:war` 10 of 18 and `track:"war"` the same 10. The two
        # `track:` shapes were also the narrowest — Spotify answered six rows
        # for every one of them whatever `limit` asked for — so they hand the
        # gate the least to work with. Bare is the widest candidate set and
        # the gate is what makes it honest.
        "q" => term,
        "type" => "track",
        "market" => market(),
        "limit" => limit,
        "offset" => offset
      },
      headers: [
        {"authorization", "Bearer #{Token.peek()}"},
        {"user-agent", user_agent()}
      ]
    ]
  end

  defp user_agent, do: Application.fetch_env!(:devils_dictionary, :user_agent)

  @doc "The catalogue this provider searches. `US` unless configured otherwise."
  def market do
    case config()[:market] do
      market when is_binary(market) and market != "" -> market
      _ -> @default_market
    end
  end

  @doc """
  One page of gated tracks, behind a token this run may have had to fetch.

  The token comes first and is a request like any other, so a run that starts
  with a cold cache costs two and a run that does not costs one. A `401` on
  the search is the one answer that means the cached token is not one Spotify
  believes in: the cache is dropped and the search is tried once more, which
  is at most one extra request and never a loop.
  """
  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      limit = limit(request["first"])
      offset = offset(request["after"])

      case Token.bearer(request_fun) do
        {:ok, token} -> search(mapping, request, offset, limit, request_fun, token)
        {:error, code} -> {:error, code}
        {:deferred, code, seconds} -> {:deferred, code, seconds, request}
      end
    else
      {:error, _reason} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  # `stale` is the token this run went out with, or nil once it has already
  # retried: a `401` invalidates *that* token and no other, so two runs
  # failing on the same stale token cannot clear each other's refresh.
  defp search(mapping, request, offset, limit, request_fun, stale) do
    payload = %{
      "term" => mapping["term"],
      "offset" => "0",
      "limit" => Integer.to_string(@scan_window)
    }

    case request_fun.(@operation, payload) do
      {:ok, %{"tracks" => %{"items" => rows}}} when is_list(rows) ->
        {:ok, page(mapping, request, rows, offset, limit)}

      {:ok, _body} ->
        {:error, "malformed_response"}

      # `Transport` reads a `401` as `"authentication_failed"`, which for this
      # provider is the token and nothing else: the id and the secret were
      # good enough to mint it a moment ago.
      {:error, "authentication_failed"} when is_binary(stale) ->
        :ok = Token.invalidate(stale)

        case Token.bearer(request_fun) do
          {:ok, _token} -> search(mapping, request, offset, limit, request_fun, nil)
          {:error, code} -> {:error, code}
          {:deferred, code, seconds} -> {:deferred, code, seconds, request}
        end

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  defp limit(first) when is_integer(first) and first > 0, do: first
  defp limit(_first), do: @default_limit

  defp offset(nil), do: 0
  defp offset(""), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  # The gate runs over the whole scan window and the page is cut from what
  # survives it, so the cursor counts cards a reader could see rather than
  # rows Spotify happened to rank.
  defp page(mapping, request, rows, offset, limit) do
    kept =
      rows
      |> Enum.flat_map(&item(mapping, &1))
      |> Enum.uniq_by(& &1.external_id)

    window =
      kept
      |> Enum.slice(offset, limit)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    %{
      request_parameters:
        request
        |> Map.put("offset", Integer.to_string(offset))
        |> Map.put("market", market())
        |> Map.put("scanned", length(rows))
        |> Map.put("kept", length(kept)),
      items: window,
      next_cursor: if(offset + limit < length(kept), do: Integer.to_string(offset + limit)),
      completion_reason: if(window == [], do: :no_results, else: :results)
    }
  end

  # One row becomes an item only when it has an id, a name the word is
  # actually in, and a link back — the last because a track shown without one
  # is the obligation the policy states, unmet.
  defp item(mapping, %{"id" => id, "name" => name} = row)
       when is_binary(id) and id != "" and is_binary(name) do
    term = mapping["term"]

    with true <- whole_word?(term, name),
         source_url when is_binary(source_url) <-
           absolute(get_in(row, ["external_urls", "spotify"])) do
      [
        %{
          external_namespace: @namespace,
          external_id: id,
          identifiers: identifiers(id, row),
          position: 0,
          # No identifier was matched. The gate proves the title holds the
          # word; the ranking that proposed it is Spotify's own.
          match_details: %{
            "kind" => "query",
            "evidence" => "query",
            "query" => term,
            "source" => "spotify"
          },
          preview_metadata: preview(row, name, source_url),
          display_allowed: true
        }
      ]
    else
      _ -> []
    end
  end

  defp item(_mapping, _row), do: []

  @doc """
  True when `term` is in `name` at a Unicode word boundary.

  `(?<![\\p{L}\\p{N}])term(?![\\p{L}\\p{N}])` rather than `\\b`, which treats
  an apostrophe as a boundary — the same pattern
  `DevilsDictionary.Discovery.Providers.BingNews.matched_text/2` applies to a
  headline and PoetryDB to a line. It is what keeps *Warrior*, *Warlock* and
  *Warm Safe Place* off the shelf for *war* while keeping *War Pigs* on it.
  """
  def whole_word?(term, name) when is_binary(term) and is_binary(name) do
    escaped = Regex.escape(String.trim(term))

    case Regex.compile("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu") do
      {:ok, pattern} -> Regex.match?(pattern, name)
      {:error, _reason} -> false
    end
  end

  def whole_word?(_term, _name), do: false

  # The track id always, and the ISRC when the response carries one — present
  # on every track the probe measured, and the join MusicBrainz will fold on.
  defp identifiers(id, row) do
    isrc = presence(get_in(row, ["external_ids", "isrc"]))

    [%{namespace: @namespace, external_id: id, metadata: %{"field" => "id"}}] ++
      if isrc do
        [
          %{
            namespace: @isrc_namespace,
            external_id: String.upcase(isrc),
            metadata: %{"field" => "external_ids.isrc"}
          }
        ]
      else
        []
      end
  end

  defp preview(row, name, source_url) do
    album = row["album"] || %{}
    artist = row["artists"] |> List.wrap() |> List.first() || %{}
    artist_name = artists(row)

    %{
      "title" => name,
      "artist" => artist_name,
      "author" => artist_name,
      # `creator` is the one artist `creator_url` reaches — the first credited
      # — because the card links every occurrence of `creator` in the credit
      # line to that URL, and *Kendrick Lamar, Zacari* as one link to
      # Kendrick's page sends Zacari's readers to the wrong artist. The full
      # credit is `attribution`, below, and stays unlinked past the first name.
      "creator" => presence(artist["name"]),
      "creator_url" => absolute(get_in(artist, ["external_urls", "spotify"])),
      # The credit line the `:required` row shows beneath the cover. The
      # artist, not the word *Spotify*: the mark beside it is what attributes
      # the content to Spotify, and printing the same name twice is the defect
      # #135 measured on the News shelf.
      "attribution" => artist_name,
      "album" => presence(album["name"]),
      "year" => year(album["release_date"]),
      "image_url" => image(album, 300),
      "thumbnail_url" => image(album, 64),
      "source_url" => source_url,
      # Carried, not gated. Whether the page's mature flag reads it is #134's
      # open question 3 and not this shelf's to answer.
      "explicit" => row["explicit"] == true,
      # What the card renders the Spotify mark from: the files, the alt text
      # and the wording of the link back, all of them this provider's to
      # declare so that the renderer matches on no provider's name (promise 9).
      "brand_mark" => @brand_mark,
      "content_type" => "music",
      "provider" => "Spotify"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  The artist credit: every credited artist, in the order Spotify names them.

  A featured artist is part of who made the track, and the Branding
  Guidelines' own layout note budgets 18 characters for the line — so it is
  joined rather than truncated here and the card clamps what does not fit.
  """
  def artists(row) when is_map(row) do
    row["artists"]
    |> List.wrap()
    |> Enum.map(&presence(&1["name"]))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  def artists(_row), do: nil

  # Spotify answers 640, 300 and 64 px rungs for an album cover, but the list
  # is a list and not a contract: the nearest rung at or above the one asked
  # for, else the largest there is, else nothing.
  defp image(album, want) do
    images =
      album["images"]
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and is_binary(absolute(&1["url"]))))

    at_least = Enum.filter(images, &(is_integer(&1["width"]) and &1["width"] >= want))

    chosen =
      case at_least do
        [] -> Enum.max_by(images, &(&1["width"] || 0), fn -> nil end)
        candidates -> Enum.min_by(candidates, & &1["width"])
      end

    chosen && absolute(chosen["url"])
  end

  # `release_date` is `YYYY`, `YYYY-MM` or `YYYY-MM-DD` by
  # `release_date_precision`; the year is the only part a card prints and it
  # is the first four digits of all three.
  defp year(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})/, value) do
      [_, year] -> year
      _ -> nil
    end
  end

  defp year(_value), do: nil

  # An absolute `http(s)` URL with a host, or nothing. Every one of these
  # reaches an `href` or an `img` out of a provider response, and
  # `DevilsDictionaryWeb.Culture.external_href/1` holds the same standard on
  # the other side (#116 Phase 3).
  defp absolute(value) when is_binary(value) do
    trimmed = String.trim(value)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        trimmed

      _uri ->
        nil
    end
  end

  defp absolute(_value), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp config, do: Application.get_env(:devils_dictionary, :spotify, [])
end
