defmodule DevilsDictionary.Discovery.Providers.Guardian do
  @moduledoc """
  The Guardian's Content API, matched by attestation in the article's own body
  — the News shelf's second source, and its first with published terms.

  #142, Phase 1 of #134. `GET https://content.guardianapis.com/search` with a
  registered `api-key`, answering JSON. Where Bing (#135) is a keyless search
  over other people's mastheads and can only see a headline, this reads the
  publisher's own full `bodyText`, so the shelf's reason moves from *in a
  headline* to **in the text** and carries the sentence a reader can check.

  ## Two identities, and why the second one matters

  Every item carries both:

    * `guardian_article` — the result's own `id`, the path
      `us-news/2026/sep/15/kash-patel-fbi-hiring-policy-bestiality`. The
      Guardian's own durable identifier, and what a later Wikidata crosswalk
      would join on.
    * `news_article` — the sha256 of the **normalised `webUrl`**, computed by
      calling `BingNews.normalize/1` and `BingNews.article_id/1` rather than
      restating them. Bing's moduledoc names this provider as the reason those
      two functions are public and the reason its query parameters are sorted
      before hashing.

  The second is the one the reader sees the effect of. Bing's feed and this
  API both carry the 15 September Kash Patel piece; because both write the
  same `news_article` id, `Shelf.dedup/2` folds them into **one** card, and
  neither provider knows the other exists.

  No `identity_record/1`, as Bing and Openverse: an article proposes no
  encyclopedia identity, so every result persists as `:insufficient_evidence`.

  ## The search proposes, the body disposes

  The gate is three questions asked of every candidate, and any one of them
  failing drops the candidate rather than failing the run:

    1. **Is the word actually in it?** Whole-word at a Unicode boundary — the
       pattern `Poetrydb.first_attestation/2` and `BingNews.matched_text/2`
       use — in `bodyText` first, and `webTitle` only if the body does not
       have it. Measured 2026-09-21: of the six articles the API returned for
       `"bestiality"` in 30 days, **all six** had the word in the body and
       **one** had it in the title, which is the whole argument for a keyed
       source on this shelf.
    2. **Did it run recently enough?** `webPublicationDate` inside
       `max_age_days` (30, the same default as Bing) of `now/0`.
    3. **Does it name somewhere to send the reader?** `webUrl` an absolute
       `http(s)` URL with a host — the standard `Culture.external_href/1`
       applies to anything reaching an `href` (#116 Phase 3).

  ## Quoting is mandatory, and it is the opposite of Bing

  Measured on the two-word case, which is where it shows: `q=red herring` over
  90 days answered **2,615** articles — every article containing both words
  anywhere — and `q="red herring"` answered **9**. Bing's probe (#135)
  measured the reverse and this module's sibling therefore sends its term
  bare; here the term is always a quoted phrase. The two are not in conflict:
  they are different indexes, and each was measured.

  ## `type=article`, which excludes the live blogs

  Measured: `"bestiality"` over 30 days answers **6** results unfiltered and
  **5** with `type=article`, and the one it drops is a running live blog —
  `us-news/live/…`, a 62,683-character `bodyText` in which the word appears
  five times, buried among a day's unrelated politics. Its extracted sentence
  read *"More here Earlier, FBI director Kash Patel clashed with lawmakers …
  bestiality (among other issues)."*, because a live blog's `bodyText` is its
  blocks concatenated with no sentence boundary between them. A live blog is
  not an article that uses a word; it is a day. Filtered out at the API.

  ## Retention: 24 hours, by the terms, and enforced by deletion

  Clause 5 of the Open Platform terms, quoted in full in
  `docs/integrations/guardian.md`:

  > You must either replace (by re-requesting) or delete all OP Content you
  > hold (whether or not published on Your Website) at least every 24 hours.
  > For legal reasons, you must not keep any OP Content for longer than 24
  > hours.

  A 24-hour positive refresh satisfies the *replace* half for a page somebody
  visits. It does nothing for a page nobody visits, whose rows sit until
  cleanup gets to them — and "whether or not published" means the cache counts.
  So this source also declares `retention_seconds: 86_400` in its
  `source_policies`, which `Discovery.cleanup/0` honours by deleting this
  source's runs, and then its orphaned source records, past that age —
  including the ones currently on display, which the general retention sweep
  deliberately protects. See `docs/integrations/guardian.md` for why option 1
  of #142 was taken over `:transient`.

  ## The key

  `GUARDIAN_API_KEY`, server-only, on the Unsplash pattern (#116 Phase 3). It
  is read in `config/runtime.exs` from the shell or the local `.env`, and
  `enabled?/0` is false without it — so a host with no key registers the
  provider, shows no News item from it, and makes no keyless call. It is sent
  as a query parameter because the API takes it no other way, which is why
  `request_options/1` is the only place it appears and why nothing in
  `preview_metadata`, `match_details`, a log line or a ledger row is ever
  built from the request.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  alias DevilsDictionary.Discovery.Providers.BingNews

  @adapter_version "guardian.attestation.v1"
  @operation "guardian_attestation"

  # Its own, durable, the Guardian's to define.
  @identity_namespace "guardian_article"

  # Thirty days, the same default as Bing's, so one shelf does not hold two
  # ideas of what "current" means.
  @default_max_age_days 30

  @default_limit 12

  # Clause 4(b) allows 500 requests per key per day and the published ceiling
  # is 1/s. Measured 2026-09-21: seventy requests in 3.9 s all answered `200`,
  # so the per-minute limit is not enforced the way it is published — see the
  # ledger. One request a second is therefore the rate this provider *chooses*,
  # the published one rather than the tolerated one.
  @request_interval_ms 1_000

  # A minute, because the published window is a minute: a refusal this could
  # not read a reset from is cleared by waiting out the longest window it could
  # belong to.
  @min_retry_interval_ms 60_000

  # The API answers a throttle with `ratelimit-reset` (seconds) and not with
  # `Retry-After`. Declared so the shared transport reads it; see
  # `DevilsDictionary.Discovery.Transport.retry_after_seconds/2`.
  @retry_after_headers ["retry-after", "ratelimit-reset"]

  @months {"January", "February", "March", "April", "May", "June", "July", "August", "September",
           "October", "November", "December"}

  # About 200 characters, as #142 asks. A sentence longer than this is cut at a
  # word and ellipsed rather than mid-word: measured, the six real sentences
  # ran 145–383 characters, so this is a cut that happens rather than a limit
  # nothing reaches.
  @max_sentence_length 200

  @impl true
  def slug, do: "guardian"

  @impl true
  def adapter_version, do: @adapter_version

  @doc "The identity namespace one Guardian article is registered under."
  def namespace, do: @identity_namespace

  @doc """
  The namespace this provider shares with Bing so one article is one card.

  Read from `BingNews` rather than restated, because a copy of this string
  that drifted would silently stop two providers deduping and nothing would
  fail.
  """
  def shared_namespace, do: BingNews.namespace()

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "The Guardian",
      # #100's tier for the Guardian, and the one that puts it beside Bing on
      # this shelf: both are plebs, so the turns go by slug and `bing-news`
      # leads `guardian`.
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      # 255 characters is the column, so the clauses are named rather than
      # quoted; `docs/integrations/guardian.md` quotes them in full.
      license:
        "Guardian Open Platform, Developer tier: non-commercial (7a), 500 requests per " <>
          "key per day (4b), content not kept longer than 24 hours (5), byline, link " <>
          "back and a \"Powered by The Guardian\" mark required (6b) — see " <>
          "docs/integrations/guardian.md",
      license_url: "https://www.theguardian.com/open-platform/terms-and-conditions",
      homepage: "https://www.theguardian.com/open-platform",
      url_template: "https://www.theguardian.com/{id}",
      attribution: "The Guardian",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "attestation: the article uses the word in its own text",
        "verification" =>
          "whole-word match on bodyText, else webTitle, within the freshness window",
        "retention" => "24 hours, by clause 5 of the Open Platform terms"
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      # Persistent, with a 24-hour refresh *and* a 24-hour retention — see the
      # moduledoc. `:transient` would meet the terms by construction and spend
      # a request on every page view of a 500-a-day key; the decision and its
      # arithmetic are in the integration doc.
      persistence: :persistent,
      pagination: :offset,
      operations: [@operation],
      content_types: [:news],
      retry_after_headers: @retry_after_headers,
      min_retry_interval_ms: interval(:min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(:request_interval_ms, @request_interval_ms)
    }
  end

  # Both paces are overridable for the reason Bing's and the Met's are: a
  # suite that paid a live rate would spend a minute being polite to a server
  # it never calls.
  defp interval(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  @impl true
  def enabled? do
    config = config()

    config[:enabled] != false and is_binary(config[:endpoint]) and
      is_binary(config[:api_key]) and config[:api_key] != ""
  end

  @impl true
  def shelf_detail, do: "dated reporting"

  @doc """
  The "Powered by The Guardian" mark, which clause 6(b)(vi) makes a condition.

  > Include a "Powered by The Guardian" logo (or such other Guardian logo as
  > we may require from time to time) on the same webpage as any republished
  > OP Content, or any tool or function that is based on OP Content. Such logo
  > must be a reproduction of the "Powered By" file found at
  > http://www.theguardian.com/open-platform/logos

  Three things about it are the Guardian's decision and not this project's, so
  they are followed literally rather than designed:

    * **The file is theirs.** `poweredbyguardianBLACK.png` and
      `poweredbyguardianWHITE.png`, 140×45, committed under `priv/static/images`
      exactly as downloaded. The clause says *a reproduction of* that file, so
      it is not redrawn, retraced as SVG or recoloured — and the two variants
      are the two the Guardian publishes for light and dark backgrounds, not a
      CSS filter over one of them.
    * **It links back to theguardian.com**, which the logos page requires
      alongside the terms: *"Please ensure that the image links back to
      theguardian.com, and that it is placed adjacent to our content."*
    * **It sits adjacent to the content** — in the shelf's own byline column,
      immediately beside the rail of Guardian cards, rather than in a page
      footer.

  The bytes are committed rather than hotlinked from `static.guim.co.uk`. That
  is the opposite of D14's rule for *item* images, and deliberately: D14 keeps
  provider **content** out of this repository, and a brand mark a licence
  obliges us to display is not content — hotlinking it would put every
  reader's address in the Guardian's logs to render our own compliance, and
  would break the obligation the day their CDN path moved. It is the same
  choice GIPHY's `priv/static/images/giphy-powered-by.png` already makes.
  """
  @impl true
  def attribution_mark do
    %{
      src: "/images/guardian-powered-by.png",
      dark_src: "/images/guardian-powered-by-dark.png",
      alt: "Powered by The Guardian",
      href: "https://www.theguardian.com/",
      width: 80
    }
  end

  # No `covers?/1`: any word can be searched for, and a word with no coverage
  # is an honest empty the pipeline caches as a negative. No
  # `mapping_identity/1`: the recipe is the word, so there is no frozen
  # evidence that can move underneath it. No `identity_record/1`: see the
  # moduledoc.

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
  def request_options(%{"term" => term, "page" => page, "page_size" => page_size}) do
    [
      method: :get,
      url: config()[:endpoint],
      params: %{
        # Always a quoted phrase. Measured: `red herring` over 90 days is
        # 2,615 articles and `"red herring"` is 9. See the moduledoc.
        "q" => ~s("#{term}"),
        # Excludes `liveblog`, and that is the only thing it excludes on this
        # query. See the moduledoc.
        "type" => "article",
        "from-date" => from_date(),
        "order-by" => "newest",
        "show-fields" => "headline,trailText,byline,bodyText,firstPublicationDate",
        "page-size" => page_size,
        "page" => page,
        # The only place the key appears. Never logged, never in an assign,
        # never in a ledger row, never in `preview_metadata`.
        "api-key" => config()[:api_key]
      },
      headers: [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
    ]
  end

  @doc """
  The oldest publication date a search will even ask for, as `YYYY-MM-DD`.

  Derived from `max_age_days/0` and the injected clock, so the request and the
  gate agree: asking for a wider window than the gate admits would spend the
  budget on candidates that are dropped on arrival.
  """
  def from_date do
    now() |> DateTime.to_date() |> Date.add(-max_age_days()) |> Date.to_iso8601()
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      limit = limit(request["first"])
      offset = offset(request["after"])

      payload = %{
        "term" => mapping["term"],
        # The API pages from 1; the pipeline counts from 0.
        "page" => Integer.to_string(div(offset, limit) + 1),
        "page_size" => Integer.to_string(limit)
      }

      case request_fun.(@operation, payload) do
        {:ok, %{"response" => %{"status" => "ok"} = response}} when is_map(response) ->
          {:ok, page(mapping["term"], request, response, offset, limit)}

        {:ok, %{"response" => %{"status" => _other}}} ->
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

  defp limit(first) when is_integer(first) and first > 0, do: first
  defp limit(_first), do: @default_limit

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  # The API pages for us, so — unlike Bing, whose whole answer arrives at once
  # — the offset is a real offset and each page is one request. The gate then
  # runs over the page that came back, so a page can be shorter than
  # `page_size` or empty while later pages still hold items; `next_cursor`
  # is therefore computed from the API's own `pages`, not from what survived.
  defp page(term, request, response, offset, limit) do
    now = now()
    rows = List.wrap(response["results"])

    attested =
      rows
      |> Enum.flat_map(&attest(term, &1, now))
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    current_page = integer(response["currentPage"], div(offset, limit) + 1)
    pages = integer(response["pages"], current_page)

    %{
      request_parameters:
        request
        |> Map.put("offset", Integer.to_string(offset))
        |> Map.put("scanned", length(rows))
        |> Map.put("attested", length(attested))
        |> Map.put("total", integer(response["total"], length(rows))),
      items: attested,
      next_cursor: if(current_page < pages, do: Integer.to_string(offset + limit)),
      completion_reason: if(attested == [], do: :no_results, else: :results)
    }
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer(_value, default), do: default

  # One row becomes an item only when all three gates pass. Any of them failing
  # is a dropped candidate and never a failed run.
  defp attest(term, row, now) when is_map(row) do
    # An item without an `id` is dropped here rather than refused by the
    # result changeset downstream, where one bad row fails the run and every
    # good item with it. The API always sends one; this is the guard for the
    # day it does not.
    with article_id when is_binary(article_id) <- presence(row["id"]),
         {:ok, published_at} <- published_at(row["webPublicationDate"]),
         true <- fresh?(published_at, now),
         {:ok, url} <- article_url(row["webUrl"]),
         {locator_part, text} <- matched_text(term, row) do
      [item(term, row, url, published_at, locator_part, text)]
    else
      _ -> []
    end
  end

  defp attest(_term, _row, _now), do: []

  @doc """
  Where the term is used, as `{the locator's first part, the sentence}`.

  The **body** first, which is the whole point of a keyed source on this
  shelf: a headline is what a word was worth to a sub-editor and the text is
  where it was actually used. The title is the fallback, and the part that is
  returned names which, so an item matched on the headline does not claim the
  text it has not got.

  Measured on the six real articles for `bestiality`: six matched in the body,
  one in the title.
  """
  def matched_text(term, row) when is_map(row) do
    pattern = word_pattern(term)
    body = field(row, "bodyText")
    title = presence(row["webTitle"])

    cond do
      is_binary(body) and Regex.match?(pattern, body) ->
        {"the text", sentence(body, pattern)}

      is_binary(title) and Regex.match?(pattern, title) ->
        {"the headline", title}

      true ->
        nil
    end
  end

  def matched_text(_term, _row), do: nil

  # Word boundary in the Unicode sense rather than `\b`, which treats an
  # apostrophe as a boundary. The same pattern PoetryDB and Bing use, for the
  # same reason: it is what stops *bestiality* matching inside
  # *#Bestialitygate* and *war* inside *warden*.
  defp word_pattern(term) do
    escaped = Regex.escape(String.trim(term))
    Regex.compile!("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu")
  end

  @doc """
  The sentence around the first use of the word, trimmed to ~200 characters.

  This is what a reader checks the reason against, so it is a real span of the
  article's own text and never a summary. The span runs from the end of the
  previous sentence to the end of the one containing the hit; a body with no
  punctuation either side falls back to a window around the match.

  It is trimmed at a word boundary with an ellipsis rather than cut mid-word.
  Measured on the six real bodies: the sentences ran 145, 199, 249, 256, 280
  and 383 characters, so the trim is a thing that happens.
  """
  def sentence(text, pattern) when is_binary(text) do
    case Regex.run(pattern, text, return: :index) do
      [{start, length} | _] ->
        text
        |> span(start, length)
        |> String.trim()
        |> clamp()

      _ ->
        nil
    end
  end

  defp span(text, start, length) do
    from =
      text
      |> binary_part(0, start)
      |> then(fn before ->
        case Regex.scan(~r/[.!?]["'\x{201d}\x{2019}]?\s+/u, before, return: :index) do
          [] -> 0
          matches -> matches |> List.last() |> List.first() |> then(fn {s, l} -> s + l end)
        end
      end)

    rest_start = start + length
    rest = binary_part(text, rest_start, byte_size(text) - rest_start)

    # The fallback is a grapheme count turned back into bytes, never a byte
    # count: `rest_start + 200` lands inside a multi-byte character one time
    # in a few, and the invalid binary it makes survives `clamp/1` (which
    # counts graphemes and sees fewer than 200) to fail JSON encoding at
    # insert, losing the whole run.
    to =
      case Regex.run(~r/[.!?]["'\x{201d}\x{2019}]?(?=\s|$)/u, rest, return: :index) do
        [{s, l} | _] -> rest_start + s + l
        _ -> rest_start + byte_size(String.slice(rest, 0, @max_sentence_length))
      end

    binary_part(text, from, to - from)
  end

  defp clamp(sentence) do
    if String.length(sentence) <= @max_sentence_length do
      sentence
    else
      sentence
      |> String.slice(0, @max_sentence_length)
      |> String.replace(~r/\s+\S*$/u, "")
      |> Kernel.<>("…")
    end
  end

  @doc """
  The `webPublicationDate` as a `DateTime`, or `:error`.

  ISO 8601 with a `Z`, measured on every result of every response in the
  probe. An item with no readable date is dropped rather than treated as
  fresh, because the date is half the reason this shelf exists and all of the
  locator.
  """
  def published_at(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, published_at, _offset} -> {:ok, published_at}
      _ -> :error
    end
  end

  def published_at(_value), do: :error

  # A day of slack on the future side, as Bing's: a newsroom that stamps
  # tomorrow happens, and a 30-day window does not care.
  defp fresh?(published_at, now) do
    seconds = DateTime.diff(now, published_at, :second)
    seconds >= -86_400 and seconds <= max_age_days() * 86_400
  end

  @doc """
  How many days old an article may be and still be news. Thirty by default.

  The same default as Bing's, deliberately: one shelf, one idea of current.
  It is also what `from_date/0` asks the API for, so the request and the gate
  cannot drift apart.
  """
  def max_age_days do
    case config()[:max_age_days] do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_max_age_days
    end
  end

  @doc """
  Now, injectable — `BingNews.now/0`'s contract, for the same reason.

  The fixture is a real capture with real September 2026 dates, and a
  freshness gate read against the wall clock would pass this week and fail
  next. `config :devils_dictionary, :guardian, now: ~U[...]` pins it.
  """
  def now do
    case config()[:now] do
      %DateTime{} = now -> now
      now when is_function(now, 0) -> now.()
      _ -> DateTime.utc_now()
    end
  end

  @doc """
  The article's own URL, or `:error` when it is not one a card could link.

  Absolute `http(s)` with a host, normalised through `BingNews.normalize/1`
  so that this provider and Bing produce the same string — and therefore the
  same `news_article` id — for the same article.
  """
  def article_url(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} = parsed when is_binary(host) and host != "" <-
           URI.parse(String.trim(url)),
         true <- scheme in ["http", "https"] do
      {:ok, BingNews.normalize(parsed)}
    else
      _ -> :error
    end
  end

  def article_url(_url), do: :error

  @doc """
  The shared cross-source identity of one article: Bing's, computed on ours.

  `BingNews.article_id/1` of `BingNews.normalize/1` of the parsed `webUrl`.
  Called rather than copied — this is the byte-for-byte agreement that makes
  the Kash Patel piece one card instead of two.
  """
  def news_article_id(url) when is_binary(url), do: BingNews.article_id(url)

  defp item(term, row, url, published_at, locator_part, text) do
    fields = row["fields"] || %{}
    byline = presence(fields["byline"])
    headline = presence(fields["headline"]) || presence(row["webTitle"])
    article_id = presence(row["id"])
    date = DateTime.to_date(published_at)

    %{
      external_namespace: namespace(),
      external_id: article_id,
      identifiers: [
        %{
          namespace: namespace(),
          external_id: article_id,
          metadata: %{"field" => "id", "section" => row["sectionName"]}
        },
        %{
          # The shared one. Bing writes the same pair for the same article.
          namespace: shared_namespace(),
          external_id: news_article_id(url),
          metadata: %{"field" => "normalized_publisher_url", "url" => url}
        }
      ],
      position: 0,
      match_details: %{
        "kind" => "attestation",
        "query" => term,
        "lines" => [
          %{
            "locator" => locator(locator_part, date),
            "text" => text
          }
        ]
      },
      preview_metadata:
        %{
          "title" => headline,
          # Clause 6(b)(i): retain the byline. It goes in the creator keys,
          # which is the unclamped `text-sm` line under the headline, and is
          # the first item on this `:credited` row with a credit distinct
          # from its creator — which is what the row was left `:credited`
          # for (#140).
          "author" => byline,
          "artist" => byline,
          # Clause 6(b) again: the masthead, shown as the credit line beside
          # the byline. Bing writes none, so this is the line the row admits
          # and nobody had yet used.
          "attribution" => "The Guardian",
          # Both, as Bing writes them, so `Culture.year/1`'s date line works
          # the same on either source's card.
          "year" => Integer.to_string(date.year),
          "published_at" => DateTime.to_iso8601(published_at),
          "description" => presence(fields["trailText"]),
          # Clause 6(b)(iv): a link to the original article.
          "source_url" => url,
          "content_type" => "news",
          "provider" => "The Guardian"
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      display_allowed: true
    }
  end

  @doc """
  The citable locator: where the word was used, in what, and when.

  `the text, The Guardian, 15 September 2026`. Bing's shape (#135) with the
  masthead fixed, because a keyed source has only one. The day is not
  zero-padded, because this is a sentence and not a timestamp.
  """
  def locator(part, %Date{} = date) do
    "#{part}, The Guardian, #{date.day} #{elem(@months, date.month - 1)} #{date.year}"
  end

  defp field(row, key) do
    case row["fields"] do
      fields when is_map(fields) -> presence(fields[key])
      _ -> nil
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :guardian, [])
end
