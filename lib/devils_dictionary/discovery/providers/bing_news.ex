defmodule DevilsDictionary.Discovery.Providers.BingNews do
  @moduledoc """
  Bing's news RSS feed, matched by attestation — the first provider on the
  News shelf, and the first one that answers in something other than JSON.

  #135, from the live shootout in #134. Keyless, undocumented and unsupported,
  like the rest of the feeds #100 surveyed: `GET
  https://www.bing.com/news/search?q=<term>&format=rss` answers RSS 2.0 with a
  `News:` namespace, and every item carries the masthead, the day it ran, a
  sentence of description and — once decoded — the publisher's own URL.

  ## What the evidence is, and is not

  An article publishes no claim about what *bestiality* means. It is not tagged
  with a QID and there is no identifier the encyclopedia already asserts about
  it, so its evidence is the other kind the README names: **attestation**. This
  article *uses* this word, in its headline, on this day, and the shelf says so
  and never says *about*.

  The locator is the third shape the kit has needed, after PoetryDB's line and
  Open Library's (empty) page: the masthead and the date. It is a `"locator"`
  string in `match_details`, which `DevilsDictionary.Discovery.MatchReason`
  already reads, so a dated citation is data here rather than a new clause
  there.

  ## The search proposes, the text disposes

  Bing's feed is a search, not a wire, and the probe measured both ways it lies
  about currency and aboutness:

    * **Staleness.** `nepotism` answered with 2025 items; `logomachy` with two
      *Word of the day* pieces from March 2026; one of `bestiality`'s own items
      is from December 2023. A search has no opinion about what is news, so the
      freshness window is ours: `pubDate` within `max_age_days` (default 30) of
      `now/0`, and everything older is dropped at retrieval. A word whose only
      coverage is old is an honest empty, cached as a negative.
    * **Aboutness.** The word has to actually be in the text. The gate is a
      whole-word match of the term in `title`, else in `description`, at a
      Unicode boundary rather than `\\b` — the same gate
      `DevilsDictionary.Discovery.Providers.Poetrydb.first_attestation/2`
      applies to a poem's lines, asked of a headline.

  ## `mkt=en-US`, which is not cosmetic

  The feed infers a market from the caller's address and the probe's was
  Poland: the channel came back titled *BingWiadomości*, every link carried
  `mkt=pl-pl`, and `/define/war` answered with six Polish games-site pages
  about *War Thunder* and *Total War* — two of them Steam store listings from
  2006 and 2013. Pinning `mkt=en-US` answered the same word with the Iran war
  from Newsweek, UPI, the New York Times and the Atlantic, and took
  `bestiality` from 7 items to 12 (Wired, the Chicago Tribune, CBS, Rolling
  Stone, Al Jazeera). It is therefore a request parameter and not a
  preference, and it is also what makes the fixture reproducible from a
  different desk. It removes the need for Open Library's language gate: the
  market decides the language upstream.

  ## The link is not the item

  `link` is `http://www.bing.com/news/apiclick.aspx?…&url=<percent-encoded
  publisher URL>&…`. The `url=` parameter is the item — its `source_url` and
  its identity — and the redirect is never linked to and never hashed. The URL
  is normalised before it is hashed (scheme and host lowercased, tracking
  parameters stripped, remaining parameters sorted, no fragment) so that the
  same article reached twice is one item, and it is registered in the
  `news_article` namespace so that a later keyed Guardian provider (#63) can
  carry the *same* namespace for the same URL and `Shelf.dedup/2` folds the two
  into one card without either provider knowing about the other.

  No `identity_record/1`, as Openverse: a headline proposes no encyclopedia
  identity, so every result persists as `:insufficient_evidence`.

  ## Pagination it does not have

  The feed returns its whole answer in one response — `count=` is ignored,
  measured — so the offset is an offset into the *gated* list this module holds
  in memory, exactly as PoetryDB's is, and a page costs one request whichever
  page it is. In practice there is never a second page: twelve items is the
  most the feed has returned and `:result_limit` is twelve.

  ## What the feed says about itself

  Recorded here because `docs/integrations/bing-news.md` is where it belongs
  and a provider should not be the only place it is written down: the feed's
  own `<copyright>` element states that the results "may not be used,
  reproduced or transmitted in any manner or for any purpose other than
  rendering Bing results within an RSS aggregator for your personal,
  non-commercial use". That is narrower than a public word page, it is the
  feed's own text rather than an absence of terms, and `source_attrs/0`'s
  `license` says so rather than claiming none is published.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  @adapter_version "bing_news.attestation.v1"
  @operation "bing_news_attestation"

  @identity_namespace "news_article"

  # The market. Not a preference — see the moduledoc. Overridable because it is
  # the one parameter a different deployment might want to change.
  @default_market "en-US"

  # What makes this a News shelf rather than a search shelf. Thirty days is "in
  # the news"; a 2025 article about nepotism is not.
  @default_max_age_days 30

  # How many gated items one page carries when the pipeline names no limit.
  @default_limit 12

  # Measured 2026-09-21: twenty distinct words at 1 req/s all answered `200`,
  # with no `429`, no `Retry-After` and flat latency (238/262/409 ms
  # min/median/max). So 1 s is not a throttle this provider was forced to; it
  # is what a search engine is owed by something that visits it on every word
  # page.
  @request_interval_ms 1_000

  # Nothing failed in the probe, so this is a posture and not a measurement: a
  # search engine that does refuse is refusing a rate, and retrying into it at
  # the shared 250 ms floor would collect another refusal.
  @min_retry_interval_ms 2_000

  # Stripped before hashing, so the same article linked twice is one item. The
  # `utm_` family is matched by prefix; these are the named ones the probe saw
  # or that newsrooms are known to append.
  @tracking_parameters ~w(
    fbclid gclid gbraid wbraid msclkid dclid yclid
    mc_cid mc_eid igshid twclid ttclid
    ocid cmp icid ito smid srnd taid partner
    guccounter guce_referrer guce_referrer_sig
    ref referrer source amp __twitter_impression
  )

  @months {"January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December"}

  @impl true
  def slug, do: "bing-news"

  @impl true
  def adapter_version, do: @adapter_version

  @doc "The identity namespace one news article is registered under."
  def namespace, do: @identity_namespace

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Bing News",
      # D1 of #116 Phase 3, and #100's tier for the Guardian and Hacker News:
      # an aggregator of other people's mastheads is a plebs-tier source. It is
      # also this shelf's place in the turns once the Guardian joins it.
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      # Not "none published". The feed publishes its own restriction in
      # `<copyright>`, measured 2026-09-21 and quoted in full in
      # `docs/integrations/bing-news.md`; what is *kept* is metadata — a
      # headline, a masthead, a date, a sentence and the publisher's URL —
      # which is the posture #100 records for GDELT and the NYT.
      license:
        "Undocumented public RSS feed; metadata only. The feed's own <copyright> " <>
          "restricts these results to rendering Bing results within an RSS aggregator " <>
          "for personal, non-commercial use — see docs/integrations/bing-news.md",
      homepage: "https://www.bing.com/news",
      # A news item has no id to put in a template, and its page is the
      # publisher's rather than Bing's. The card links to `source_url`.
      url_template: nil,
      attribution: "via Bing News",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "attestation: the article uses the word in its headline",
        "verification" =>
          "whole-word match on title, else description, within the freshness window",
        "market" => @default_market
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
      content_types: [:news],
      # RSS 2.0, not JSON. `Discovery.Transport` reads this and hands the
      # binary body to `parse_body/1` below.
      body: :xml,
      min_retry_interval_ms: interval(:min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(:request_interval_ms, @request_interval_ms)
    }
  end

  # Both paces are overridable for the same reason the Met's and PoetryDB's
  # are: an interval is a live-rate courtesy, and a suite that paid it would
  # spend a second per stubbed request being polite to a server it never calls.
  defp interval(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  @impl true
  def enabled? do
    config()[:enabled] != false and is_binary(config()[:endpoint])
  end

  @impl true
  def shelf_detail, do: "dated headlines"

  # No `covers?/1`. The default `true` is right: any word can be searched for
  # in the news, and a word with no current coverage is an empty answer the
  # pipeline caches as a negative rather than a failure. No `mapping_identity/1`
  # either — the recipe is the word, so there is no frozen evidence to move.
  #
  # No `identity_record/1`: see the moduledoc.

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "attestation_v1"
     }}
  end

  @impl true
  def validate_mapping(@operation, %{"term" => term, "resolution_strategy" => "attestation_v1"})
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100,
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def request_options(%{"term" => term}) do
    [
      method: :get,
      url: config()[:endpoint],
      # Bare, not quoted. Measured on a two-word lemma, which is the case a
      # quoted phrase was supposed to be for: `q=red herring` answered six
      # items of which four use the phrase, two of them from the last three
      # days, while `q="red herring"` answered three and the freshest was from
      # 2024. The gate already enforces the phrase, so quoting only narrows
      # the candidates it has to choose from — and for a single word it
      # returned a different seven with no more of them usable.
      params: %{"q" => term, "format" => "rss", "mkt" => market()},
      headers: headers()
    ]
  end

  defp market do
    case config()[:market] do
      market when is_binary(market) and market != "" -> market
      _ -> @default_market
    end
  end

  # The project's own line. Measured first, as the brief asked: Bing answered
  # it with `200` and the same seven items a Chrome UA got, so no browser
  # impersonation is needed here.
  defp headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @doc """
  Decodes one RSS 2.0 document into `%{"items" => [item map]}`.

  `Discovery.Transport` calls this because `capabilities/0` declares
  `body: :xml`; `parse/1` below then sees the map, so the document is walked
  once.

  Floki is the parser — already a dependency, and Johnson's TEI-XML uses it —
  but not its CSS selectors for the namespaced tags: it lowercases
  `News:Source` to `"news:source"` and the escaped selector `news\\:source`
  matches nothing (measured on the captured fixture). So each `item`'s
  children are read by tag name off the tree, which is both what works and
  what keeps an unexpected extra tag from being a parse failure.

  A document with no `channel` is not this feed, and that is the discriminator
  rather than the item count: `referendum` answered `200` with a valid channel
  and **zero** items, which is an empty result and not a malformed one.
  """
  @impl true
  def parse_body(body) when is_binary(body) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        if Floki.find(document, "channel") == [] do
          :error
        else
          {:ok, %{"items" => Enum.map(Floki.find(document, "item"), &item_fields/1)}}
        end

      _error ->
        :error
    end
  end

  def parse_body(_body), do: :error

  defp item_fields({"item", _attributes, children}) do
    Enum.reduce(children, %{}, fn
      {tag, _attributes, _children} = node, fields ->
        Map.put_new(fields, tag, node |> Floki.text() |> String.trim())

      _text, fields ->
        fields
    end)
  end

  defp item_fields(_node), do: %{}

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      term = mapping["term"]
      limit = limit(request)
      offset = offset(request["after"])

      case request_fun.(@operation, %{"term" => term}) do
        {:ok, body} ->
          case parse(body) do
            {:ok, rows} -> {:ok, page(term, request, rows, offset, limit)}
            :error -> {:error, "malformed_response"}
          end

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

  defp parse(%{"items" => rows}) when is_list(rows), do: {:ok, rows}
  defp parse(_body), do: :error

  defp limit(request) do
    case request["first"] do
      first when is_integer(first) and first > 0 -> first
      _ -> @default_limit
    end
  end

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  # The gate runs over the whole answer and the window is cut from what
  # survives it, so the cursor counts items a reader could see rather than
  # rows Bing happened to return.
  defp page(term, request, rows, offset, limit) do
    now = now()

    attested =
      rows
      |> Enum.flat_map(&attest(term, &1, now))
      |> Enum.uniq_by(& &1.external_id)

    window =
      attested
      |> Enum.slice(offset, limit)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    %{
      request_parameters:
        request
        |> Map.put("offset", Integer.to_string(offset))
        |> Map.put("scanned", length(rows))
        |> Map.put("attested", length(attested)),
      items: window,
      next_cursor: if(offset + limit < length(attested), do: Integer.to_string(offset + limit)),
      completion_reason: if(window == [], do: :no_results, else: :results)
    }
  end

  # One row becomes an item only when the word is in its text at a word
  # boundary *and* it ran inside the freshness window *and* the `apiclick`
  # link yielded a publisher URL. Any of the three failing is a dropped
  # candidate and never a failed run.
  defp attest(term, row, now) when is_map(row) do
    with {:ok, published_at} <- published_at(row["pubdate"]),
         true <- fresh?(published_at, now),
         {:ok, url} <- publisher_url(row["link"]),
         {locator_part, text} <- matched_text(term, row) do
      [item(term, row, url, published_at, locator_part, text)]
    else
      _ -> []
    end
  end

  defp attest(_term, _row, _now), do: []

  @doc """
  Where the term is used, as `{the locator's first part, the text that used it}`.

  The headline first, because a word in a headline is the strongest thing this
  feed can show, and Bing's one-sentence `description` only if the headline
  does not have it. The part that is returned names which, so an item matched
  on the description does not claim a headline it has not got.
  """
  def matched_text(term, row) when is_map(row) do
    pattern = word_pattern(term)

    cond do
      present?(row["title"]) and Regex.match?(pattern, row["title"]) ->
        {"a headline", row["title"]}

      present?(row["description"]) and Regex.match?(pattern, row["description"]) ->
        {"a summary", row["description"]}

      true ->
        nil
    end
  end

  # Word boundary in the Unicode sense rather than `\b`, which treats an
  # apostrophe as a boundary and would find *war* inside *war's* but also
  # inside a hyphenated form the newsroom did not write. The same pattern
  # PoetryDB uses, for the same reason.
  defp word_pattern(term) do
    escaped = Regex.escape(String.trim(term))
    Regex.compile!("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu")
  end

  @doc """
  The `pubDate` as a `DateTime`, or `:error`.

  RFC 1123, as RSS 2.0 requires — `Tue, 15 Sep 2026 06:50:00 GMT`, measured on
  every item of every response in the probe. An item with no readable date is
  dropped rather than treated as fresh, because the date is half the reason
  this shelf exists.
  """
  def published_at(value) when is_binary(value), do: parse_rfc1123(String.trim(value))

  def published_at(_value), do: :error

  defp parse_rfc1123(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/^(?:\w{3},\s*)?(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})/,
             value
           ),
         {:ok, month} <- month_number(month),
         {:ok, date} <-
           Date.new(String.to_integer(year), month, String.to_integer(day)),
         {:ok, time} <-
           Time.new(
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      # Every `pubDate` measured ended in `GMT`, and RSS 2.0's default is UTC.
      # A feed that one day sends an offset would be read an hour or two out
      # rather than dropped, which for a 30-day window is not a difference.
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> :error
    end
  end

  defp month_number(abbreviation) do
    @months
    |> Tuple.to_list()
    |> Enum.find_index(&String.starts_with?(&1, abbreviation))
    |> case do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  # A day of slack on the future side, because a newsroom that stamps tomorrow
  # is a thing that happens and a 30-day window does not care; anything
  # further ahead than that is a date we do not believe.
  defp fresh?(published_at, now) do
    seconds = DateTime.diff(now, published_at, :second)
    seconds >= -86_400 and seconds <= max_age_days() * 86_400
  end

  @doc """
  How many days old an article may be and still be news. Thirty by default.

  The window is what separates this shelf from a search: the feed happily
  answers `nepotism` with 2025 and `logomachy` with March. It is configurable
  because "current" is a product decision and not a fact about the feed.
  """
  def max_age_days do
    case config()[:max_age_days] do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_max_age_days
    end
  end

  @doc """
  Now, injectable.

  The fixture is a real captured response with real September 2026 dates, and
  a freshness gate read against the wall clock would pass today and fail in
  October. `config :devils_dictionary, :bing_news, now: ~U[...]` pins it; a
  zero-arity function is accepted too, for a suite that wants to move time
  rather than stop it.
  """
  def now do
    case config()[:now] do
      %DateTime{} = now -> now
      now when is_function(now, 0) -> now.()
      _ -> DateTime.utc_now()
    end
  end

  defp item(term, row, url, published_at, locator_part, text) do
    masthead = presence(row["news:source"])
    external_id = article_id(url)
    date = DateTime.to_date(published_at)

    %{
      external_namespace: namespace(),
      external_id: external_id,
      identifiers: [
        %{
          namespace: namespace(),
          external_id: external_id,
          metadata: %{"field" => "normalized_publisher_url", "url" => url}
        }
      ],
      position: 0,
      match_details: %{
        "kind" => "attestation",
        "evidence" => "attestation",
        "query" => term,
        "lines" => [
          %{
            # The dated locator promise 3 of the README calls the next shape
            # after a line and a page: where the word was used, who ran it and
            # when. `MatchReason.attestations/1` reads `"locator"` already.
            "locator" => locator(locator_part, masthead, date),
            "text" => text
          }
        ]
      },
      preview_metadata:
        %{
          "title" => presence(row["title"]),
          # The masthead, once. It goes in the creator keys because a masthead
          # is who made the article, and because that is the line the card
          # gives a fact: `text-sm`, unclamped, under the headline.
          #
          # It is deliberately *not* also written to `"attribution"`, which the
          # `:credited` row would render as a second line beneath it. #135
          # specified both and asked for the decision to be made in the
          # browser; measured on `/define/bestiality` at 1280 px, the card read
          #
          #     Kash Patel and GOP lawmaker have bizarre 'bestiality' debate
          #     15 Sep 2026 · News
          #     HuffPost on MSN
          #     HuffPost on MSN
          #
          # One fact twice, the second time in the fine print reserved for an
          # obligation. The row stays `:credited` rather than dropping to
          # `:none`, because `:none` means *the shelf byline is the whole
          # credit* and the shelf byline is Bing — which is the one thing a
          # News shelf must not say about somebody else's journalism. The row
          # admits a per-item credit; this source simply has no credit to name
          # beyond the masthead it already names, and a later keyed source with
          # a wire agency's byline can write one without touching the row.
          "author" => masthead,
          "artist" => masthead,
          "year" => Integer.to_string(date.year),
          "published_at" => DateTime.to_iso8601(published_at),
          "description" => presence(row["description"]),
          "source_url" => url,
          "content_type" => "news",
          "provider" => "Bing News"
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      display_allowed: true
    }
  end

  @doc """
  The citable locator: where the word was used, who ran it, and when.

  `a headline, Wired, 15 September 2026`. The day is not zero-padded, because
  this is a sentence and not a timestamp.
  """
  def locator(part, masthead, %Date{} = date) do
    [part, presence(masthead), long_date(date)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp long_date(%Date{} = date),
    do: "#{date.day} #{elem(@months, date.month - 1)} #{date.year}"

  @doc """
  The publisher's own URL, decoded out of Bing's `apiclick` redirect.

  The `url=` parameter is the item. The redirect is never the `source_url` and
  never the identity: it carries a per-response `tid` and a `mkt`, so hashing
  it would make the same article a new item on every fetch, and linking it
  would send the reader to Bing.

  An item is dropped rather than linked to Bing when the parameter is missing
  or is not an absolute `http(s)` URL with a host — the same standard
  `Culture.external_href/1` applies to anything that reaches an `href`
  (#116 Phase 3).
  """
  def publisher_url(link) when is_binary(link) do
    with %URI{query: query} when is_binary(query) <- URI.parse(link),
         %{"url" => url} <- URI.decode_query(query),
         %URI{scheme: scheme, host: host} = parsed when is_binary(host) and host != "" <-
           URI.parse(url),
         true <- scheme in ["http", "https"] do
      {:ok, normalize(parsed)}
    else
      _ -> :error
    end
  end

  def publisher_url(_link), do: :error

  @doc """
  One publisher URL, normalised so that the same article twice is one item.

  Scheme and host lowercased, the fragment dropped, tracking parameters
  stripped and what is left sorted. Sorting is part of it because two feeds —
  Bing today and the Guardian later, on the same `news_article` namespace —
  can name the same article with the same parameters in a different order, and
  an identity that depended on their order would not merge.
  """
  def normalize(%URI{} = uri) do
    %URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host),
        fragment: nil,
        query: normalize_query(uri.query),
        # A userinfo in a news URL is not a thing, and carrying one into an
        # `href` would be.
        userinfo: nil
    }
    |> URI.to_string()
  end

  defp normalize_query(nil), do: nil

  defp normalize_query(query) do
    query
    |> URI.decode_query()
    |> Enum.reject(fn {key, _value} ->
      downcased = String.downcase(key)
      downcased in @tracking_parameters or String.starts_with?(downcased, "utm_")
    end)
    |> Enum.sort()
    |> case do
      [] -> nil
      pairs -> URI.encode_query(pairs)
    end
  end

  @doc """
  The stable identity of one article: the digest of its normalised URL.

  The URL is the only identity the feed publishes — there is no article id in
  the envelope — and it is the one a keyed Guardian provider can also compute
  for the same article, which is what lets `Shelf.dedup/2` fold the two.
  """
  def article_id(url) when is_binary(url) do
    :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :bing_news, [])
end
