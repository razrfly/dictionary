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

  Four things the 2026-09-19 probe found
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

  # `https://commons.wikimedia.org/w/index.php?curid=73850232`
  @commons_curid ~r{^https?://commons\.wikimedia\.org/w/index\.php\?curid=(\d+)$}

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
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Per item; only CC0, CC BY, CC BY-SA and public-domain items are shown",
      license_url: "https://openverse.org/search-help",
      homepage: "https://openverse.org/",
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
      min_retry_interval_ms: interval(:min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(:request_interval_ms, @request_interval_ms)
    }
  end

  defp interval(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
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
        # Openverse checks the upstream URL still resolves. A dead hotlink is
        # the one failure D14 cannot recover from: we hold no bytes.
        "filter_dead" => "true"
      },
      headers: headers()
    ]
  end

  defp headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      limit = limit(request["first"])
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

  defp limit(first) when is_integer(first) and first > 0, do: min(first, @max_limit)
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

  defp page(mapping, request, rows, offset, limit, body) do
    items =
      rows
      |> Enum.map(&item(mapping, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.uniq_by(&upload/1)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    request =
      request
      |> Map.put("offset", Integer.to_string(offset))
      |> Map.put("scanned", length(rows))
      |> Map.put("kept", length(items))

    %{
      request_parameters: request,
      items: items,
      next_cursor: next_cursor(rows, offset, limit, body),
      completion_reason: if(items == [], do: :no_results, else: :results)
    }
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
  defp upload(item) do
    case {item.preview_metadata["creator"], item.preview_metadata["title"]} do
      {creator, title} when is_binary(creator) and is_binary(title) ->
        {String.downcase(creator), String.downcase(title)}

      _ ->
        item.external_id
    end
  end

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
         thumbnail when is_binary(thumbnail) <- media(row["thumbnail"]) || media(row["url"]),
         landing when is_binary(landing) <- media(row["foreign_landing_url"]) do
      %{
        external_namespace: namespace(),
        external_id: id,
        identifiers: identifiers(id, row, landing),
        position: 0,
        # No identifier was matched, and saying so is the whole of M6. The
        # `:image` row is the only one whose `evidence` admits this class.
        match_details: %{
          "kind" => "query",
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
  # `attribution` is Openverse's own ready-made line, shown verbatim beneath
  # the thumbnail; `credit_line` is the fallback the renderer uses for a
  # provider that has none, and Openverse always has one.
  defp preview(row, license, thumbnail, landing) do
    creator = presence(row["creator"])

    %{
      "title" => title(row),
      "thumbnail_url" => thumbnail,
      # The upstream file, not the thumbnail: `Shelf.canonical_media_url/1`
      # compares this and never the derivative.
      "image_url" => media(row["url"]) || thumbnail,
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
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Openverse composes the line a CC licence asks for — `"Title" by Creator is
  # licensed under CC BY-SA 2.0. To view a copy of this license, visit …` — and
  # it is shown verbatim. The composed fallback is for the item that carries
  # none; it names the same three things in the same order.
  defp attribution(row, license, creator) do
    case presence(row["attribution"]) do
      nil ->
        [
          title(row) && ~s("#{title(row)}"),
          creator && "by #{creator}",
          "licensed under #{license}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> Kernel.<>(", via Openverse")

      line ->
        line
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

  @hidden ~r/<(\w+)\b[^>]*style=["'][^"']*display:\s*none[^"']*["'][^>]*>(?:(?!<\1\b).)*?<\/\1>/s

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

  defp drop_hidden(html) do
    case Regex.replace(@hidden, html, " ") do
      ^html -> html
      stripped -> drop_hidden(stripped)
    end
  end

  defp clamp(nil), do: nil
  defp clamp(title), do: title |> String.trim() |> String.slice(0, 255)

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
  defp media(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.trim(value)

      _uri ->
        nil
    end
  end

  defp media(_value), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :openverse, [])
end
