defmodule DevilsDictionary.Discovery.Providers.Commons do
  @moduledoc """
  Wikimedia Commons, matched by what a file's own structured data says it
  depicts — identity, never text.

  Commons carries structured data on files: `P180` *depicts* statements whose
  values are Wikidata QIDs, one licence per file, and a MediaWiki API with
  `continue` cursors. Its search is asked one thing —
  `haswbstatement:P180=<QID>` for the QIDs the page's senses already `refers_to`
  (`DevilsDictionary.Discovery.PageEvidence`, the same read the Met uses) —
  and that search only **proposes**. A file is kept when its hydrated
  `statements.P180` carries one of those QIDs: the search proposes, the
  statements dispose. No broader walk; equal QID or nothing (#109 Phase 3a).

  A page costs at most **two** requests: one `generator=search` that returns
  the window with `prop=imageinfo` (thumbnail URL and `extmetadata` licence in
  the same answer), and one `wbgetentities` for the window's `M`-ids — skipped
  when the licence and mime gates leave nothing to hydrate. The
  probe (`docs/integrations/commons.md`) measured no throttle at 250 ms
  spacing; the 1 s interval is what a public service is owed by something that
  visits it on every word page, and `maxlag=5` rides on every request as the
  Wikimedia etiquette asks.

  Three things the probe found are built in rather than documented:

    * **The licence gate is applied to the hydrated file**, read from
      `extmetadata.License` (`pd`, `cc0`, `cc-by-*`, `cc-by-sa-*`), with
      `LicenseShortName` as the fallback. Everything else is dropped — the
      `Attribution` template, GFDL, any `NC` or `ND` variant. Two of the first
      twelve soldier files were `Attribution` and are not shown.
    * **A lag refusal is a 200.** MediaWiki answers `maxlag` with HTTP 200 and
      `error.code == "maxlag"`, so the shared transport's `Retry-After` path
      never sees it. The provider reads the body and defers the run itself.
    * **A video can depict a soldier.** The sandbox item is depicted by a
      `video/webm`; the window is `filetype:bitmap` and every kept file's
      `mime` is `image/*`.

  Image bytes are never fetched (D14). Two URLs travel with the file's licence
  and author, which is the attribution a CC licence requires when the
  thumbnail is shown: `thumbnail_url` is the 640 px derivative the card paints
  and `image_url` is the file itself, which since #116 Phase 3's D4 is the
  `url` `imageinfo` returns rather than a second copy of the thumbnail. The
  second is never painted — it is the join key of last resort, the thing
  `Shelf.dedup/2` compares when an aggregator republishes this file and
  proposes no shared identifier.
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  alias DevilsDictionary.Discovery.PageEvidence
  alias DevilsDictionary.SourceIdentity.Entry

  @adapter_version "commons.depicts.v1"
  @operation "depicts_qid_discovery"

  @doc "The identity namespace one Commons file is registered under: its page id."
  def namespace, do: "commons_file"

  # The page window, when the pipeline names no `first`. `request["first"]` is
  # `:result_limit`; the window is that and not a number of this module's own,
  # because a search that proposed wider than the page it fills would pay a
  # `wbgetentities` for files it then threw away. MediaWiki caps a search at 50.
  @default_limit 12
  @max_limit 50

  # A page can be seven lexemes with fifteen senses between them; the QID set is
  # a match key, and CirrusSearch OR's them in one `haswbstatement`.
  @max_entities 8

  # Measured, not published: 30 request pairs at 250 ms drew no `429`, no
  # `maxlag` and no `Retry-After`. 1 s is the courtesy a public API is owed by
  # something that visits it on every word page.
  @request_interval_ms 1_000

  # MediaWiki's `Retry-After` on a lag refusal is 5 seconds, always.
  @maxlag 5
  @min_retry_interval_ms 5_000

  @thumb_width 640

  @extmetadata ~w(License LicenseShortName LicenseUrl Artist Credit Attribution
    ObjectName DateTimeOriginal UsageTerms)

  @impl true
  def slug, do: "commons"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Wikimedia Commons",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Per file; only CC0, CC BY, CC BY-SA and public-domain files are shown",
      license_url: "https://commons.wikimedia.org/wiki/Commons:Licensing",
      homepage: "https://commons.wikimedia.org/",
      url_template: "https://commons.wikimedia.org/?curid={external_id}",
      attribution: "Wikimedia Commons contributors; each file carries its own author and licence",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "P180 depicts statements on the hydrated file equal a QID a sense refers to",
        "licence_gate" => "extmetadata.License on the hydrated file",
        "preview_storage" => "thumbnail and full-size URL, author and licence only",
        "image_delivery" =>
          "thumb.wikimedia.org reference for the card, upload.wikimedia.org as the " <>
            "fold key; images are not rehosted"
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :persistent,
      pagination: :cursor,
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
  def shelf_detail, do: "depicts: Wikidata"

  @impl true
  def enabled? do
    config()[:enabled] != false and is_binary(config()[:endpoint])
  end

  @impl true
  def covers?(target) do
    PageEvidence.any?(DevilsDictionary.Discovery.page_lexeme_ids(target))
  end

  @impl true
  def mapping_identity(%{"entities" => entities}) when is_list(entities),
    do: PageEvidence.digest(entities)

  def mapping_identity(_parameters), do: "no-entities"

  @impl true
  def automatic_mapping(target) do
    entities =
      target
      |> DevilsDictionary.Discovery.page_lexeme_ids()
      |> PageEvidence.entities(@max_entities)

    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "depicts_qid_v1",
       "entities" => entities
     }}
  end

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "resolution_strategy" => "depicts_qid_v1",
        "entities" => entities
      })
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100 do
    if PageEvidence.valid_entities?(entities), do: :ok, else: {:error, :invalid_mapping}
  end

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def request_options(%{"endpoint" => "search", "params" => params}) do
    [
      method: :get,
      url: config()[:endpoint],
      params: Map.merge(base_params(), params),
      headers: headers()
    ]
  end

  def request_options(%{"endpoint" => "entities", "ids" => ids}) do
    params =
      Map.merge(base_params(), %{"action" => "wbgetentities", "ids" => ids, "props" => "claims"})

    [method: :get, url: config()[:endpoint], params: params, headers: headers()]
  end

  defp base_params,
    do: %{"format" => "json", "formatversion" => "2", "maxlag" => Integer.to_string(@maxlag)}

  defp headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      case mapping["entities"] do
        [] -> {:ok, empty(request, nil)}
        entities -> search(entities, request, request_fun)
      end
    else
      {:error, _} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  defp empty(request, cursor) do
    %{request_parameters: request, items: [], next_cursor: cursor, completion_reason: :no_results}
  end

  defp search(entities, request, request_fun) do
    limit = request["first"] |> limit()

    with {:ok, continuation} <- cursor(request["after"]) do
      params =
        %{
          "action" => "query",
          "generator" => "search",
          "gsrsearch" => search_query(entities),
          "gsrnamespace" => "6",
          "gsrlimit" => Integer.to_string(limit),
          # Files used on many pages first: a filter query has no relevance of
          # its own, and how widely a file is used is the one quality signal
          # the search can sort on.
          "gsrsort" => "incoming_links_desc",
          "prop" => "imageinfo",
          "iiprop" => "url|mime|user|extmetadata",
          "iiurlwidth" => Integer.to_string(@thumb_width),
          "iiextmetadatafilter" => Enum.join(@extmetadata, "|")
        }
        |> Map.merge(continuation)

      case request_fun.("search", %{"endpoint" => "search", "params" => params}) do
        {:ok, %{"error" => %{"code" => "maxlag"} = error}} ->
          {:deferred, "maxlag", lag_seconds(error), request}

        {:ok, %{"error" => _error}} ->
          {:error, "provider_api_error"}

        {:ok, %{"query" => %{"pages" => pages}} = body} when is_list(pages) ->
          hydrate(entities, request, pages, next_cursor(body), request_fun)

        # A search that proposes nothing has no `query` key at all — measured,
        # `{"batchcomplete": true}` and nothing else. An ordinary empty page.
        {:ok, %{"batchcomplete" => _}} ->
          {:ok, empty(Map.put(request, "scanned", 0), nil)}

        {:ok, _body} ->
          {:error, "malformed_response"}

        {:error, code} ->
          {:error, code}

        {:deferred, code, seconds} ->
          {:deferred, code, seconds, request}
      end
    else
      :error -> {:error, "malformed_cursor"}
    end
  end

  defp limit(first) when is_integer(first) and first > 0, do: min(first, @max_limit)
  defp limit(_first), do: @default_limit

  # One CirrusSearch clause for every QID: `haswbstatement:P180=Q1|P180=Q2`.
  # Measured as a union — 26,220 hits for dog OR Canidae against 26,131 and 115.
  defp search_query(entities) do
    clauses = entities |> Enum.map(&"P180=#{&1["qid"]}") |> Enum.join("|")
    "haswbstatement:#{clauses} filetype:bitmap"
  end

  # The cursor is MediaWiki's own `continue` object, JSON-encoded, and handed
  # back as the parameters it names. Only the two keys a search continuation
  # carries are accepted; anything else did not come from this provider.
  defp cursor(nil), do: {:ok, %{}}
  defp cursor(""), do: {:ok, %{}}

  defp cursor(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"continue" => continue, "gsroffset" => offset}}
      when is_binary(continue) and (is_integer(offset) or is_binary(offset)) ->
        {:ok, %{"continue" => continue, "gsroffset" => to_string(offset)}}

      _ ->
        :error
    end
  end

  defp cursor(_value), do: :error

  defp next_cursor(%{"continue" => %{"continue" => _, "gsroffset" => _} = continue}),
    do: Jason.encode!(Map.take(continue, ["continue", "gsroffset"]))

  defp next_cursor(_body), do: nil

  defp lag_seconds(%{"lag" => lag}) when is_number(lag), do: max(@maxlag, ceil_seconds(lag))
  defp lag_seconds(_error), do: @maxlag

  defp ceil_seconds(lag) when is_integer(lag), do: lag
  defp ceil_seconds(lag), do: lag |> Float.ceil() |> trunc()

  # The candidates the licence and mime gates admit, then one `wbgetentities`
  # for their statements. A window with nothing displayable spends no second
  # request: there is nothing whose statements could dispose anything.
  defp hydrate(entities, request, pages, cursor, request_fun) do
    candidates = pages |> Enum.map(&candidate/1) |> Enum.reject(&is_nil/1)

    request =
      request |> Map.put("scanned", length(pages)) |> Map.put("displayable", length(candidates))

    case candidates do
      [] ->
        {:ok, empty(request, cursor)}

      candidates ->
        ids = candidates |> Enum.map(&"M#{&1.pageid}") |> Enum.join("|")

        case request_fun.("entities", %{"endpoint" => "entities", "ids" => ids}) do
          {:ok, %{"error" => %{"code" => "maxlag"} = error}} ->
            {:deferred, "maxlag", lag_seconds(error), request}

          {:ok, %{"error" => _error}} ->
            {:error, "provider_api_error"}

          {:ok, %{"entities" => statements}} when is_map(statements) ->
            {:ok, keep(entities, request, candidates, statements, cursor)}

          {:ok, _body} ->
            {:error, "malformed_response"}

          {:error, code} ->
            {:error, code}

          {:deferred, code, seconds} ->
            {:deferred, code, seconds, request}
        end
    end
  end

  defp keep(entities, request, candidates, statements, cursor) do
    index = Map.new(entities, &{&1["qid"], &1})

    items =
      candidates
      |> Enum.flat_map(fn candidate ->
        case depicted(statements["M#{candidate.pageid}"], index) do
          [] -> []
          depicts -> [item(candidate, depicts)]
        end
      end)
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    %{
      request_parameters: Map.put(request, "kept", length(items)),
      items: items,
      next_cursor: cursor,
      completion_reason: if(items == [], do: :no_results, else: :results)
    }
  end

  @doc """
  The `P180` QIDs of one MediaInfo entity that are in the page's QID index.

  The statements dispose: a file the search proposed is kept only when its own
  structured data names a QID a sense refers to. A missing entity, an entity
  with no statements, and a `somevalue` snak with no id all name nothing.
  """
  def depicted(entity, index) when is_map(entity) and is_map(index) do
    entity
    |> get_in(["statements", "P180"])
    |> List.wrap()
    |> Enum.map(&get_in(&1, ["mainsnak", "datavalue", "value", "id"]))
    |> Enum.filter(&(is_binary(&1) and is_map_key(index, &1)))
    |> Enum.uniq()
    |> Enum.map(fn qid ->
      %{
        "qid" => qid,
        "relation" => "exact",
        "entity_qid" => qid,
        "entity_label" => index[qid]["label"]
      }
    end)
  end

  def depicted(_entity, _index), do: []

  # One search hit reduced to what a card and an identity need, or nil when the
  # file may not be shown: not a bitmap image, no thumbnail, or a licence
  # outside CC0 / CC BY / CC BY-SA / public domain. The gate reads the hydrated
  # file's `extmetadata`, never the query that found it.
  defp candidate(%{"pageid" => pageid, "title" => title, "imageinfo" => [info | _]} = _page)
       when is_integer(pageid) and is_binary(title) and is_map(info) do
    metadata = info["extmetadata"] || %{}
    thumb = info["thumburl"]

    with true <- is_binary(info["mime"]) and String.starts_with?(info["mime"], "image/"),
         true <- is_binary(thumb) and thumb != "",
         {:ok, licence} <- licence(metadata) do
      %{
        pageid: pageid,
        title: file_title(metadata, title),
        thumbnail_url: thumb,
        # D4 of #116 Phase 3. `iiprop=url` returns both: `thumburl` is the
        # 640 px derivative this project asked for and `url` is the file
        # itself. Both keys used to hold the thumbnail, so a Commons item
        # could never fold with anything by media URL — and the one source
        # that republishes Commons files, Openverse, hands back exactly this
        # `upload.wikimedia.org` URL. `image_url` is the join key of last
        # resort, and the thumbnail is each provider's own derivative.
        image_url: presence(info["url"]) || thumb,
        source_url:
          presence(info["descriptionurl"]) || "https://commons.wikimedia.org/?curid=#{pageid}",
        author: author(metadata, info["user"]),
        author_url: author_url(metadata, info["user"]),
        attribution: presence(text(metadata, "Attribution")),
        licence: licence,
        licence_url: presence(text(metadata, "LicenseUrl")),
        date: presence(text(metadata, "DateTimeOriginal"))
      }
    else
      _ -> nil
    end
  end

  defp candidate(_page), do: nil

  @doc """
  The licence a file may be shown under, or `:error`.

  `extmetadata.License` is the machine-readable code Commons derives from the
  licence template — `pd`, `cc0`, `cc-by-4.0`, `cc-by-sa-3.0` — and is the gate.
  `LicenseShortName` is the human label and the fallback when the code is
  absent. Anything else is refused, including `Attribution` (Commons's own
  copyrighted-free-use template), GFDL, and every `NC` or `ND` variant.
  """
  def licence(metadata) when is_map(metadata) do
    code = metadata |> text("License") |> String.downcase()
    short = text(metadata, "LicenseShortName")

    cond do
      code in ["pd", "cc0"] ->
        {:ok, presence(short) || String.upcase(code)}

      String.starts_with?(code, "cc-by-sa-") ->
        {:ok, presence(short) || code}

      String.starts_with?(code, "cc-by-") and not restricted?(code) ->
        {:ok, presence(short) || code}

      code != "" ->
        :error

      short in ["Public domain", "CC0"] ->
        {:ok, short}

      String.starts_with?(short, "CC BY-SA ") ->
        {:ok, short}

      String.starts_with?(short, "CC BY ") ->
        {:ok, short}

      true ->
        :error
    end
  end

  def licence(_metadata), do: :error

  defp restricted?(code), do: String.contains?(code, "-nc") or String.contains?(code, "-nd")

  # `ObjectName` when the uploader gave a title-sized one, else the file name
  # without its namespace and extension. Measured on `/define/soldier`: a
  # museum upload's `ObjectName` is a whole title block — one
  # `<div lang="xx">` per language, plus hidden `title QS:P1476,…`
  # QuickStatements lines. The English element is the title when there is one;
  # a block that is still description-sized after that yields to the file
  # name. Clamped to `entities.preferred_label`'s 255.
  @title_length 120
  @english ~r/<(\w+)\b[^>]*\blang="en"[^>]*>(.*?)<\/\1>/s

  defp file_title(metadata, title) do
    raw = get_in(metadata, ["ObjectName", "value"])

    name =
      case english(raw) do
        nil -> presence(text(metadata, "ObjectName"))
        english -> english
      end

    chosen =
      cond do
        not is_binary(name) -> file_name(title)
        String.length(name) > @title_length -> file_name(title)
        String.contains?(name, "QS:") -> file_name(title)
        true -> name
      end

    String.slice(chosen, 0, 255)
  end

  defp english(raw) when is_binary(raw) do
    case Regex.run(@english, drop_hidden(raw)) do
      [_, _tag, inner] -> presence(strip(inner))
      _ -> nil
    end
  end

  defp english(_raw), do: nil

  defp file_name(title) do
    title
    |> String.replace_prefix("File:", "")
    |> String.replace(~r/\.[A-Za-z0-9]{2,5}\z/, "")
    |> String.replace("_", " ")
  end

  # `Artist` is HTML — a user link, a `<div class="fn">`, a museum credit — so
  # the tags go and the text stays. The uploading account is the fallback.
  defp author(metadata, user) do
    case presence(text(metadata, "Artist")) do
      nil -> presence(user) || "Unknown author"
      artist -> String.slice(artist, 0, 200)
    end
  end

  # M4's `creator_url` (#116 Phase 2). `Artist` is HTML and the name inside it
  # is almost always a link — a Commons user page, an `en.wikipedia.org` user
  # page, an institution. The first `href` is that link; MediaWiki writes some
  # of them protocol-relative (`//commons.wikimedia.org/…`), which is not a URL
  # a card can put in an anchor, so it is given a scheme. When `Artist` names
  # nobody the author fell back to the uploading account, and that account's
  # own page is where the credit points.
  @href ~r/<a\b[^>]*\bhref="([^"]+)"/

  defp author_url(metadata, user) do
    artist = get_in(metadata, ["Artist", "value"])

    case is_binary(artist) and Regex.run(@href, artist) do
      [_, href] -> absolute(href)
      _ -> user_page(metadata, user)
    end
  end

  defp user_page(metadata, user) do
    if presence(text(metadata, "Artist")) == nil and presence(user) do
      "https://commons.wikimedia.org/wiki/User:" <> URI.encode(String.replace(user, " ", "_"))
    end
  end

  defp absolute("//" <> rest), do: "https://" <> rest
  defp absolute("http://" <> _rest = url), do: url
  defp absolute("https://" <> _rest = url), do: url
  defp absolute("/" <> rest), do: "https://commons.wikimedia.org/" <> rest
  defp absolute(_href), do: nil

  @doc "One `extmetadata` value as plain text: tags stripped, entities decoded, whitespace folded."
  def text(metadata, key) when is_map(metadata) do
    case get_in(metadata, [key, "value"]) do
      value when is_binary(value) -> strip(value)
      _ -> ""
    end
  end

  # Hidden blocks first — `<div style="display: none;">date QS:P571,…</div>` is
  # machine-readable text a reader was never meant to see — then every tag.
  defp strip(html) do
    html
    |> drop_hidden()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @hidden ~r/<(\w+)\b[^>]*style="[^"]*display:\s*none[^"]*"[^>]*>(?:(?!<\1\b).)*?<\/\1>/s

  defp drop_hidden(html) do
    case Regex.replace(@hidden, html, " ") do
      ^html -> html
      stripped -> drop_hidden(stripped)
    end
  end

  defp item(candidate, depicts) do
    external_id = Integer.to_string(candidate.pageid)

    %{
      external_namespace: namespace(),
      external_id: external_id,
      identifiers: [
        %{namespace: namespace(), external_id: external_id, metadata: %{"field" => "pageid"}}
      ],
      position: 0,
      match_details: %{
        "kind" => "depiction",
        "depicts" => depicts
      },
      preview_metadata: %{
        "title" => candidate.title,
        "year" => year(candidate.date),
        "thumbnail_url" => candidate.thumbnail_url,
        "image_url" => candidate.image_url,
        "source_url" => candidate.source_url,
        # The card's creator line carries the attribution a CC licence asks for
        # when the thumbnail is shown: who made it, under what terms.
        "artist" => "#{candidate.author} · #{candidate.licence}",
        "author" => candidate.author,
        "license" => candidate.licence,
        "license_url" => candidate.licence_url,
        # M4's six fixed names (#116 Phase 2). `credit_line` stays as it was —
        # the renderer's fallback, and what `identity_record/1` registers — and
        # `attribution` is the line shown when the file names one of its own.
        "creator" => candidate.author,
        "creator_url" => candidate.author_url,
        "attribution" => attribution(candidate),
        "credit_line" => credit_line(candidate),
        "content_type" => "image",
        "provider" => "Wikimedia Commons",
        "depicts" => Enum.map(depicts, &Map.take(&1, ["qid", "entity_label"]))
      },
      display_allowed: true
    }
  end

  defp credit_line(candidate),
    do: "#{candidate.author}, #{candidate.licence}, via Wikimedia Commons"

  # M4's `attribution`: the ready-made line the renderer shows verbatim.
  #
  # `extmetadata.Attribution` is the one field that is that line — the text an
  # uploader set when the file's terms require a particular wording — and it
  # is absent on most files. `Credit` is **not** the fallback, although M4's
  # list named it: measured on three files 2026-09-19, `Credit` is provenance
  # prose ("Derived from Template:Libyan Civil War detailed map", "This tag
  # does not indicate the copyright status of the attached work…"), sometimes
  # a paragraph with a list in it, and never a credit. The composed line is
  # the fallback instead, which is what the card already showed.
  defp attribution(candidate), do: candidate.attribution || credit_line(candidate)

  # `DateTimeOriginal` is free text — "2006-10-16", "Taken on 6 June 1944",
  # "circa 1944-06-06", "1887". The first four-digit run is the only part that
  # is a year, and there may not be one.
  defp year(value) when is_binary(value) do
    case Regex.run(~r/\b(1\d{3}|20\d{2})\b/, value) do
      [_, year] -> year
      _ -> nil
    end
  end

  defp year(_value), do: nil

  @impl DevilsDictionary.SourceIdentity.Adapter
  def identity_record(%{external_namespace: "commons_file", external_id: pageid} = item) do
    metadata = item.preview_metadata

    Entry.new(%{
      source_slug: slug(),
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "image",
      stable_identifier: %{namespace: namespace(), external_id: pageid},
      identifiers: Map.get(item, :identifiers, []),
      label: metadata["title"],
      year: integer_year(metadata["year"]),
      metadata: %{
        # Deliberately the thumbnail, and not the `image_url` D4 changed on
        # the shelf item: this is the registry entity's display image, shown
        # on an entity page at the same size a card shows it, and putting a
        # 4,000 px original behind it would be a page fetching megabytes to
        # paint a 96 px frame.
        "image_url" => metadata["thumbnail_url"],
        "image_attribution" => metadata["credit_line"],
        "credit_line" => metadata["credit_line"],
        "author" => metadata["author"],
        "license" => metadata["license"],
        "license_url" => metadata["license_url"],
        "source_url" => metadata["source_url"],
        "content_type" => "image"
      },
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported_commons_identity}

  defp integer_year(<<year::binary-size(4)>>) do
    case Integer.parse(year) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp integer_year(_year), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :commons, [])
end
