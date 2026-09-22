defmodule DevilsDictionary.Discovery.Providers.Openverse do
  @moduledoc """
  Openverse, the second source on the Images shelf — a search, and honest
  about it.

  #116 Phase 2. Wikimedia Commons reaches a page by identity (`P180` depicts a
  QID a sense refers to); Openverse reaches one by **text**, and M6 of #116 is
  the rule that lets it: a photo item's reason is a `:query` reason, the
  `:image` row is the only one whose `evidence` admits that class, and
  `MatchReason.describe/2` renders it as *Search result for “war”, ranked by
  the provider and not matched on an identifier.* A search result on any other
  shelf is a red suite. Nothing here proposes an encyclopedia identity: there
  is no `identity_record/1`, so every result persists as
  `:insufficient_evidence`, which is what a text match deserves.

  Five things the 2026-09-19 probes found
  (`docs/integrations/openverse.md`) are built in rather than documented:

    * **The query is an exact phrase.** Bare `q=war` answers twenty copies of
      *Star Wars Episode 1* — Openverse matches a stemmed `q` against
      `title`, `description` and `tags.name` — and bare `q=nepotism` answers
      photographs of *Negri Nepote*, a grassland in New Jersey. `q="war"`
      answers pictures whose title is *war*. The quotes are the difference
      between a shelf and a results page.

    * **The licence gate is this project's, applied twice.** `license` narrows
      the search to `cc0,pdm,by,by-sa`, and every returned item's own
      `license` is checked again before it becomes an item — the same
      posture Commons takes, and the same reason: the gate belongs on the
      object, not on the query that found it. No `NC`, no `ND`.

    * **Openverse names the Commons file it aggregates.** A `source ==
      "wikimedia"` item's `foreign_landing_url` is
      `https://commons.wikimedia.org/w/index.php?curid=<pageid>`, and that
      pageid is exactly the `commons_file` external id
      `DevilsDictionary.Discovery.Providers.Commons` registers. The provider
      proposes it as a second identifier, so `Shelf.dedup/2` folds this copy
      into the Commons item on the same page without either provider knowing
      about the other (M3).

    * **`filter_dead` is what makes a second page unreliable, so only the
      first page asks for it.** Openverse validates upstream links against a
      cached *dead-link mask* per query; when that cache is cold it serves
      the requested page from the **start** of the ranking rather than from
      the page's own offset. Measured live 2026-09-19 on `q="war"`,
      `page_size=12`: with `filter_dead=true`, page 2 answered with page 1's
      twelve ids (`cf-cache-status: HIT`, `age: 7603`, the entry written at
      the moment #126 Phase 1 clicked *Load more*), and a cold-cache repeat
      on a fresh key answered from index 0 again; with `filter_dead=false`,
      pages 1, 2 and 3 were three cold misses and perfectly contiguous. The
      same walk at `page_size` 6, 10 and 20 was contiguous only because the
      mask was warm by then. So the first page — the one every reader sees —
      keeps the filter, and a page after it does not, which is the only
      reading of this API under which *Load more* can move a count. The cost
      is stated rather than hidden: an item on page 2 or later has not been
      link-checked, so its thumbnail may be dead. The two rankings differ by
      the items the filter removed, so the unfiltered page 2 can repeat one
      item from the filtered page 1 — exactly one, measured — and
      `Shelf.dedup/2` folds it at read time.

    * **The rate limit is advertised but not enforced.** Every response
      carries `x-ratelimit-limit-anon_burst: 20/min` and
      `x-ratelimit-limit-anon_sustained: 200/day`; 54 anonymous requests, 40
      of which reached the origin rather than Cloudflare's edge, drew no
      `429`, no `Retry-After`, and never moved the counters.
      `request_interval_ms` is sized to the **advertised** burst anyway — the
      number a public service publishes is the number it is owed — and the
      200/day is the ceiling the 30-day positive cache exists to make
      survivable (M8). A registered key (10,000/day, 100/min) is the owner's
      action to take, not this module's.

  Image bytes are never fetched (D14). `thumbnail_url` is Openverse's own
  thumbnail proxy and `image_url` is the upstream file the item aggregates,
  which is also the join key of last resort when no identifier is shared.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  alias DevilsDictionary.Discovery.Providers.Commons

  @adapter_version "openverse.search.v1"
  @operation "image_search"

  # The page window when the pipeline names no `first`. Openverse caps an
  # anonymous `page_size` at 20 and an anonymous walk at 240 results.
  @default_limit 12
  @max_limit 20
  @max_results 240

  # Advertised in every response header as `20/min`. Measured: not enforced —
  # see the moduledoc. 3 s is what 20/min asks for.
  @request_interval_ms 3_000

  # The burst window Openverse's headers name is a minute, so a refusal is a
  # minute old at worst. No `429` was observed, so this is a floor rather than
  # a measurement.
  @min_retry_interval_ms 60_000

  # This project's posture, unchanged from Commons: public domain, CC0, CC BY
  # and CC BY-SA. Openverse spells them without the `cc-` prefix.
  @licenses ~w(cc0 pdm by by-sa)

  # D2 of #126. The ceiling conformance asserts on every `:required` row is
  # 160; this provider keeps its own sentence inside it with room to spare,
  # and clamps the one part of the sentence a licence does not require.
  #
  # 72 rather than 160, because 160 characters is a paragraph in the column
  # this line is rendered in. Measured through the card component on the 131
  # real image credits this project holds for `war` and `soldier`: at the
  # `:image` row's 96 px column a credit needs about 46 characters to fit
  # three rows, Pexels's longest is 44 and Unsplash's 47, and Openverse — the
  # only one of the four whose line carries a *title* — reached 91 and nine
  # rows before this. 72 puts its worst case beside its peers instead of
  # beside Commons's, and the title is the part that pays for it: the card's
  # own `h3` two lines above already says it in full.
  @credit_limit 72
  @credit_title_limit 32

  # The creator is the one run of the line that is never dropped, so it is the
  # one that has to be bounded: an upstream `creator` is free text and can be
  # a paragraph or carry a URL (CodeRabbit on #129). Sixty characters holds
  # every real creator this project has seen; the clamped name is written to
  # the `creator` field as well as into the line, so the card's link still
  # finds its needle. With the title at most 34 characters quoted, the
  # creator at most 60 and the licence's short form under 16, the line is
  # under 120 by construction, and D2's 160 is a ceiling nothing here reaches.
  @credit_creator_limit 60

  # `https://commons.wikimedia.org/w/index.php?curid=73850232`
  @commons_curid ~r{^https?://commons\.wikimedia\.org/w/index\.php\?curid=(\d+)$}

  import DevilsDictionary.Discovery.Provider.Helpers,
    only: [
      clamp_label: 1,
      drop_hidden: 1,
      headers: 0,
      interval: 3,
      limit: 3,
      media_url: 1,
      offset: 1,
      page: 5,
      presence: 1,
      sparse: 1
    ]

  @doc "The identity namespace one Openverse media item is registered under: its UUID."
  def namespace, do: "openverse_media"

  @impl true
  def slug, do: "openverse"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Openverse",
      # D1 of #116 Phase 3: a search-only source is a plebs-tier source, so
      # that an identity-bearing item — Commons's `P180` depiction — leads the
      # rail wherever one exists and search results follow. This was `:middle`
      # in Phase 2, when Openverse was the only search on the shelf and the
      # order it produced (Commons, Openverse, Commons, Openverse) was the
      # same either way; with three searches beside one identity source it is
      # not.
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Per item; only CC0, CC BY, CC BY-SA and public-domain items are shown",
      license_url: "https://openverse.org/search-help",
      homepage: "https://openverse.org/",
      logo: "/images/sources/openverse.svg",
      url_template: "https://openverse.org/image/{external_id}",
      attribution: "Openverse; each item carries its own creator, licence and attribution line",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "an exact-phrase search for the page's term; no identifier is matched",
        "licence_gate" =>
          "the item's own `license`, after the search was narrowed to the same set",
        "preview_storage" => "thumbnail and upstream URL, creator, licence and attribution only",
        "image_delivery" => "openverse and upstream CDN references; images are not rehosted"
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
  def shelf_detail, do: "search: CC and public domain"

  @impl true
  def enabled? do
    config()[:enabled] != false and is_binary(config()[:endpoint])
  end

  # A keyword provider declines nothing (M6). There is no cheap existence query
  # that would be cheaper than the search itself, and a word Openverse has
  # nothing for is a negative cache rather than a decline.
  @impl true
  def covers?(_target), do: true

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "exact_phrase_search_v1"
     }}
  end

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "resolution_strategy" => "exact_phrase_search_v1"
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
        # Quoted: an exact phrase, not a stem. See the moduledoc.
        "q" => ~s("#{term}"),
        "page" => page,
        "page_size" => page_size,
        "license" => Enum.join(@licenses, ","),
        "mature" => "false",
        "filter_dead" => filter_dead(page)
      },
      headers: headers()
    ]
  end

  # Openverse checks the upstream URL still resolves, and a dead hotlink is the
  # one failure D14 cannot recover from: we hold no bytes. It is also what
  # breaks the walk — a cold dead-link mask serves any page from index 0 — so
  # the first page is filtered and the pages after it are paged. See the
  # moduledoc for the measurement, and #128.
  defp filter_dead("1"), do: "true"
  defp filter_dead(_page), do: "false"

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

        {:ok, %{"detail" => _detail}} ->
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

  # One card per upload, where an upload is one creator's one title.
  #
  # `Shelf.dedup/2` folds two items that are the same *file*, and these are
  # not: measured on `/define/war` 2026-09-19, eight of the twelve items
  # Openverse returned were `"War Horse" by Eva Rinaldi Celebrity
  # Photographer` — eight distinct ids, eight distinct Flickr URLs, eight
  # frames of one evening, each of which the shelf was obliged to show. One
  # photographer's set is one thing a reader learns from, and the rest is the
  # rail repeating itself. Not perceptual dedup, which M3 rules out: an exact
  # match on two fields the provider already carries, inside this provider's
  # own page, before the shelf ever sees them. An item missing either field
  # keeps its own id and folds with nobody.
  # A short page is the last page, and so is the anonymous walk's own ceiling:
  # Openverse answers `page_count` against a `result_count` it caps at 240 for
  # a keyless client, and asking for the page past it is a 400.
  defp next_cursor(rows, offset, limit, body) do
    next = offset + limit

    cond do
      length(rows) < limit -> nil
      next >= @max_results -> nil
      is_integer(body["page_count"]) and div(next, limit) + 1 > body["page_count"] -> nil
      true -> Integer.to_string(next)
    end
  end

  # One search hit reduced to what a card, a credit and a fold need, or nil
  # when the item may not be shown: no usable URL, or a licence outside the
  # gate. The gate reads the item Openverse returned, never the `license`
  # parameter that asked for it.
  defp item(mapping, %{"id" => id} = row) when is_binary(id) and id != "" do
    with {:ok, license} <- license(row),
         thumbnail when is_binary(thumbnail) <-
           media_url(row["thumbnail"]) || media_url(row["url"]),
         landing when is_binary(landing) <- media_url(row["foreign_landing_url"]) do
      %{
        external_namespace: namespace(),
        external_id: id,
        identifiers: identifiers(id, row, landing),
        position: 0,
        # No identifier was matched, and saying so is the whole of M6. The
        # `:image` row is the only one whose `evidence` admits this class.
        match_details: %{
          "kind" => "query",
          "evidence" => "query",
          "query" => mapping["term"],
          "fields_matched" => fields_matched(row),
          "source" => row["source"]
        },
        preview_metadata: preview(row, license, thumbnail, landing),
        display_allowed: true
      }
    else
      _ -> nil
    end
  end

  defp item(_mapping, _row), do: nil

  # M4's six fixed names, plus the title and the ladder the `:image` row reads.
  # `attribution` is the one line this provider composes (D2 of #126) and the
  # card shows beneath the thumbnail; `row["attribution"]`, the CC boilerplate
  # Openverse ships, is deliberately not forwarded — see `attribution/3`.
  defp preview(row, license, thumbnail, landing) do
    creator = credit_name(presence(row["creator"]))

    %{
      "title" => title(row),
      "thumbnail_url" => thumbnail,
      # The upstream file, not the thumbnail: `Shelf.canonical_media_url/1`
      # compares this and never the derivative.
      "image_url" => media_url(row["url"]) || thumbnail,
      "source_url" => landing,
      "license" => license,
      "license_url" => presence(row["license_url"]),
      "creator" => creator,
      "creator_url" => presence(row["creator_url"]),
      "attribution" => attribution(row, license, creator),
      "author" => creator,
      "content_type" => "image",
      "provider" => "Openverse",
      "upstream_source" => presence(row["source"])
    }
    |> sparse()
  end

  @doc """
  The credit line, composed here from this item's own fields (D2 of #126).

  Openverse ships a ready-made `attribution`, and forwarding it was what M4's
  *verbatim* was read to mean. It is the full CC boilerplate — *"war" by
  zbigphotography (1M+ views) is licensed under CC BY-SA 2.0. To view a copy
  of this license, visit https://creativecommons.org/licenses/by-sa/2.0/.* —
  **155 characters**, two sentences and an unbreakable URL. Measured through
  the card component on `/define/war`, that one credit is **fourteen rows**
  at 375 and eleven at 1280, which is four times the card it belongs to and
  the tallest thing on it (#126 item 2 recorded seven; the number on this
  card is worse). D2 settles it: a
  credit is at most one sentence naming the creator and the licence, with no
  URL in the prose, because the licence link `Culture.credit_parts/2` puts on
  the licence name is where *view a copy* lives.

  So the line is `"{title}" by {creator}, {licence}`, and what is missing is
  simply absent rather than filled with a word. The **title** is the part
  that gives, because it is the one a CC licence does not ask for: it is
  clamped to #{@credit_title_limit} characters, and dropped outright if the
  sentence still would not fit #{@credit_limit}. The creator and the licence
  are never cut — they are the two runs the card turns into links, and a
  truncated creator matches no needle and therefore carries no link, which is
  the condition itself.
  """
  def attribution(row, license, creator) do
    creator = credit_name(creator)
    line = credit(credit_title(title(row)), creator, license)

    if String.length(line) <= @credit_limit, do: line, else: credit(nil, creator, license)
  end

  # A name as the credit prints it and the `creator` field carries it: no
  # URL (the licence link is the only link a credit's prose may imply), one
  # space between words, at most `@credit_creator_limit` characters. Applied
  # once and used in both places, so `Culture.credit_parts/2` finds the
  # printed name when it looks for the field.
  defp credit_name(nil), do: nil

  defp credit_name(creator) do
    creator
    |> String.replace(~r{https?://\S+|www\.\S+}iu, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> presence()
    |> case do
      nil -> nil
      name when byte_size(name) > 0 -> clamp_run(name, @credit_creator_limit)
    end
  end

  defp clamp_run(text, limit) do
    if String.length(text) > limit,
      do: text |> String.slice(0, limit - 1) |> String.trim_trailing() |> Kernel.<>("…"),
      else: text
  end

  defp credit(title, creator, license) do
    [title && ~s("#{title}"), creator && "by #{creator}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> license
      lead -> "#{lead}, #{license}"
    end
  end

  defp credit_title(nil), do: nil

  # The title is clamped harder than the creator and, like it, carries no
  # URL: a Commons `ObjectName` or a Flickr title can hold one.
  defp credit_title(title) do
    title
    |> String.replace(~r{https?://\S+|www\.\S+}iu, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> presence()
    |> case do
      nil -> nil
      text -> clamp_run(text, @credit_title_limit)
    end
  end

  @doc """
  One Openverse title as a card can show it.

  Almost always the plain string Openverse indexed. Not always: for a
  `wikimedia` item Openverse passes Commons's `ObjectName` through unchanged,
  and a museum upload's `ObjectName` is a whole title block — a `<div>` per
  language plus hidden `label QS:Lfr,…` QuickStatements lines. Measured on
  `/define/allegory` 2026-09-19: *Allegory of Europe* arrived as ninety
  characters of markup. Commons's own provider solves this by preferring the
  English element and falling back to the file name; Openverse gives no file
  name to fall back to, so this takes the hidden blocks out first — they are
  machine-readable text a reader was never meant to see — then the tags, and
  keeps the first line of what is left.
  """
  def title(row) do
    row |> Map.get("title") |> presence() |> strip() |> clamp()
  end

  defp strip(nil), do: nil

  defp strip(title) do
    if String.contains?(title, "<") do
      title
      |> drop_hidden()
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.split(~r/\bQS:/, parts: 2)
      |> hd()
      |> presence()
    else
      title
    end
  end

  defp clamp(nil), do: nil
  defp clamp(title), do: title |> String.trim() |> clamp_label()

  # The provider's own identity, and the upstream one when the upstream is a
  # source this encyclopedia already holds. The Commons pageid is the exact
  # `commons_file` external id `Commons` writes, so `Shelf.dedup/2` folds the
  # two copies with neither provider naming the other (M3).
  defp identifiers(id, row, landing) do
    own = %{namespace: namespace(), external_id: id, metadata: %{"field" => "id"}}

    case commons_pageid(row, landing) do
      nil ->
        [own]

      pageid ->
        [
          own,
          %{
            namespace: Commons.namespace(),
            external_id: pageid,
            metadata: %{"field" => "foreign_landing_url"},
            # Two sources naming one file is the point; neither owns it.
            exclusive: false
          }
        ]
    end
  end

  defp commons_pageid(%{"source" => "wikimedia"}, landing) do
    case Regex.run(@commons_curid, landing) do
      [_, pageid] -> pageid
      _ -> nil
    end
  end

  defp commons_pageid(_row, _landing), do: nil

  @doc """
  The short licence name an Openverse item may be shown under, or `:error`.

  `license` is Openverse's own slug — `by`, `by-sa`, `cc0`, `pdm`, and the
  `nc`/`nd` variants this project does not show — and `license_version` is
  separate. Together they make the short form M4 names: `CC-BY-SA-4.0`,
  `CC0-1.0`, `PDM-1.0`. Anything outside the gate is refused here even though
  the search was narrowed to it, because the gate belongs on the object.
  """
  def license(%{"license" => license} = row) when is_binary(license) do
    slug = String.downcase(license)

    if slug in @licenses do
      {:ok, short_license(slug, presence(row["license_version"]))}
    else
      :error
    end
  end

  def license(_row), do: :error

  defp short_license("cc0", version), do: "CC0-#{version || "1.0"}"
  defp short_license("pdm", version), do: "PDM-#{version || "1.0"}"
  defp short_license(slug, nil), do: "CC-" <> String.upcase(slug)
  defp short_license(slug, version), do: "CC-#{String.upcase(slug)}-#{version}"

  # Which of Openverse's indexed fields the phrase hit, recorded on the match
  # so a reader following `/connect` can see the search was a search. Openverse
  # leaves it empty on some hits; an empty list is not a reason.
  defp fields_matched(row) do
    row
    |> Map.get("fields_matched")
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  # An absolute `http(s)` URL or nothing. A relative or malformed one is not a
  # picture we can hotlink, and a scheme we did not ask for is not one we
  # follow.
  # This provider's own stanza; the read is the kit's.
  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:openverse)
end
