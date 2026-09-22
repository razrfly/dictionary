defmodule DevilsDictionary.Discovery.Providers.Met do
  @moduledoc """
  Metropolitan Museum of Art Open Access, matched by identity rather than text.

  The Met's own search is a text search, and text is not evidence: `q=war`
  returns a uniform, a Greek oil flask and a photograph album, and nothing in
  that ranking says which of them is *about* war. So the search is used for
  exactly one thing — generating candidates — and the decision to keep a
  candidate is made against the hydrated object's `tags`, every one of which
  carries a Wikidata QID (215/215 and 68/68 measured in the #99 P0 probe).

  A result is kept when a tag's QID equals a QID the target's senses already
  point at through an active `refers_to` claim, or reaches one in at most two
  `P31`/`P279` steps on Wikidata — *World War I → world war → war*. That is the
  same shape as CineGraph's exact keyword-id match, and the reason shown on the
  shelf names the tag that did it.

  Three consequences of the P0 probe are built in rather than documented:

    * `403` is this provider's throttle signal, not an authentication verdict,
      and it arrives with no `Retry-After` (`retryable_status?/1` plus
      `min_retry_interval_ms`).
    * `isPublicDomain=true` on the search is **not** honoured — measured, see
      `docs/integrations/met-2a-2026-09-17.md` — so the public-domain gate is
      applied to the hydrated object, never to the query.
    * Image bytes are never fetched. `primaryImageSmall` is stored as a URL and
      travels with `creditLine`, which is the paired attribution.
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  alias DevilsDictionary.Discovery.PageEvidence
  alias DevilsDictionary.Discovery.Providers.Met.BroaderWalk
  alias DevilsDictionary.SourceIdentity.Entry

  import DevilsDictionary.Discovery.Provider.Helpers,
    only: [clamp_label: 1, headers: 0, interval: 3, presence: 1]

  @adapter_version "met.openaccess.v1"
  @operation "tag_qid_discovery"

  @base "https://collectionapi.metmuseum.org/public/collection"
  @search_path "/v1.1/search"
  @object_path "/v1/objects"

  # How many candidate object IDs one page hydrates. Every one is a request, so
  # this is the page's whole Met spend beyond the single search: a page costs at
  # most `1 + @scan_window`.
  @scan_window 25

  # A page can be seven lexemes with fifteen senses between them. The QID set is
  # a match key, not a summary, and the highest-confidence handful is what a
  # search and a tag comparison can actually use.
  @max_entities 8

  # The sustained gap between this provider's requests, when the environment
  # does not override it. Measured, not documented: the Met's published 80
  # req/s refused 44% of 2,600 requests at 1 req/s and none at 3 s/request.
  @request_interval_ms 3_000

  @impl true
  def slug, do: "met"

  @impl true
  def adapter_version, do: @adapter_version

  @doc "The candidate window one page hydrates, and so its request cost minus one."
  def scan_window, do: @scan_window

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "The Met",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "CC0 metadata; images only where the object is public domain",
      license_url: "https://www.metmuseum.org/information/terms-and-conditions",
      homepage: "https://www.metmuseum.org/",
      url_template: "https://www.metmuseum.org/art/collection/search/{external_id}",
      attribution: "The Metropolitan Museum of Art Open Access",
      config: %{
        "operation" => @operation,
        "tag_vocabulary" => "Wikidata QIDs on Met subject tags",
        "preview_storage" => "normalized permitted fields only",
        "image_delivery" => "primaryImageSmall reference; images are not rehosted",
        "public_domain_gate" => "isPublicDomain on the hydrated object"
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
      content_types: [:artwork],
      # The probe measured 21 of 100 hydrations refused at ~6.7 req/s. 1.5 s is
      # the interval that recovered 17 of those 21 on one retry.
      min_retry_interval_ms: 1_500,
      # K5 of #109: pacing is a capability the shared transport honours, not a
      # `Process.sleep/1` this provider hides inside its own hydration loop.
      # 3 s is the measured sustainable rate: 44% of 2,600 requests were refused
      # at 1 req/s and none at 3 s/request.
      request_interval_ms: interval(config(), :request_interval_ms, @request_interval_ms)
    }
  end

  @impl true
  def shelf_detail, do: "tags: Wikidata"

  @impl true
  def enabled? do
    config()[:enabled] != false
  end

  # The QIDs the page's senses already point at, with the labels to search for.
  #
  # This is the whole of the Met's association evidence, and it is read from the
  # encyclopedia rather than from the provider — `PageEvidence` is the shared
  # read, since #109 Phase 3a also Wikimedia Commons's. A target with no such
  # claim yields an empty set, and `covers?/1` then declines it outright.
  defp page_entities(lexeme_ids), do: PageEvidence.entities(lexeme_ids, @max_entities)

  @impl true
  def covers?(target) do
    # Coverage is an existence question and is asked as one. Every word page
    # renders this before any run exists, and the answer is no for about 99% of
    # them — so it must not pay for the ordering, the dedup and the labels that
    # only a mapping about to be built has any use for.
    PageEvidence.any?(DevilsDictionary.Discovery.page_lexeme_ids(target))
  end

  @doc """
  The QID set a recipe was built from, as a short digest.

  `automatic_mapping/1` freezes the QIDs into the mapping parameters, and
  `retrieve/4` matches tags against those frozen QIDs — so a `refers_to` claim
  withdrawn or replaced after the mapping was created would otherwise keep the
  Met querying a concept the encyclopedia has stopped asserting. Coverage does
  not catch this: swapping QID A for QID B leaves the set non-empty and
  `covers?/1` still says yes.

  This reads the parameters and never the database, so versioning the mapping by
  its evidence costs no query beyond the one that built the recipe.

  The digest covers the QIDs **in order**, because order is what
  `search_terms/2` reads, and not the labels, because a relabelled entity is the
  same evidence — the match key is the QID.
  """
  @impl true
  def mapping_identity(%{"entities" => entities}) when is_list(entities),
    do: PageEvidence.digest(entities)

  def mapping_identity(_parameters), do: "no-entities"

  @impl true
  def automatic_mapping(target) do
    entities = target |> DevilsDictionary.Discovery.page_lexeme_ids() |> page_entities()
    term = String.trim(target.term)

    {@operation,
     %{
       "term" => term,
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "tag_qid_v1",
       "entities" => entities,
       # The entity's own label is a better query than the headword — the sense
       # picked the entity, so its label is the sense, not the spelling.
       "search_terms" => mapping_search_terms(entities, term)
     }}
  end

  defp mapping_search_terms(entities, term) do
    entities
    |> Enum.map(& &1["label"])
    |> Kernel.++([term])
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(3)
  end

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "resolution_strategy" => "tag_qid_v1",
        "entities" => entities
      })
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100 and
             is_list(entities) do
    if PageEvidence.valid_entities?(entities), do: :ok, else: {:error, :invalid_mapping}
  end

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def request_options(%{"endpoint" => "search", "params" => params}) do
    [method: :get, url: @base <> @search_path, params: params, headers: headers()]
  end

  def request_options(%{"endpoint" => "object", "object_id" => object_id}) do
    [method: :get, url: "#{@base}#{@object_path}/#{object_id}", headers: headers()]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      case mapping["entities"] do
        [] -> {:ok, empty(request, :no_results)}
        entities when is_list(entities) -> search(mapping, entities, request, request_fun)
      end
    else
      {:error, _} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  defp empty(request, reason) do
    %{request_parameters: request, items: [], next_cursor: nil, completion_reason: reason}
  end

  defp search(mapping, entities, request, request_fun) do
    terms = search_terms(mapping)
    {index, offset, more} = cursor(request["after"], length(terms))
    term = Enum.at(terms, index)

    payload = %{
      "endpoint" => "search",
      "params" => %{
        "q" => term,
        "tags" => "true",
        "hasImages" => "true",
        "offset" => Integer.to_string(offset),
        "limit" => Integer.to_string(@scan_window)
      }
    }

    position = {index, offset, length(terms), more}

    case request_fun.("search", payload) do
      {:ok, %{"objectIDs" => ids}} when is_list(ids) ->
        hydrate(entities, request, term, position, ids, request_fun)

      # The Met answers a search with no matches with a null `objectIDs`, so
      # this is an ordinary empty page rather than a malformed body. It still
      # advances the cursor: one term coming up empty is not the other terms
      # coming up empty, and stopping here is how only the first was ever asked.
      {:ok, %{"total" => total}} when is_integer(total) ->
        {:ok,
         %{
           request_parameters:
             request
             |> Map.put("term_index", index)
             |> Map.put("offset", Integer.to_string(offset))
             |> Map.put("scanned", 0),
           items: [],
           next_cursor: next_cursor(position, 0),
           completion_reason: :no_results
         }}

      {:ok, _body} ->
        {:error, "malformed_response"}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  # The terms a recipe actually holds, never just the first of them (K5 of
  # #109). `automatic_mapping/1` puts the entity labels ahead of the headword
  # precisely because the sense chose the entity, and until now only the
  # headword's neighbour at position 0 was ever asked.
  defp search_terms(mapping) do
    case mapping["search_terms"] |> List.wrap() |> Enum.filter(&presence(&1)) do
      [] -> [mapping["term"]]
      terms -> terms
    end
  end

  # `"<term index>:<offset>"`, with a trailing `":more"` once any term in the
  # current cycle has answered a full window. A page asks one term, and the next
  # page asks the next term at the same offset — round-robin — so a mapping's
  # second and third terms are reached within the first three pages rather than
  # never. Completing a cycle advances the window.
  #
  # A bare integer is the pre-#109 cursor, read as term 0 so a cursor persisted
  # by the previous adapter version still resolves.
  defp cursor(nil, _count), do: {0, 0, false}

  defp cursor(value, count) when is_binary(value) do
    case String.split(value, ":") do
      [index, offset | rest] ->
        {rem(max(integer(index), 0), max(count, 1)), max(integer(offset), 0), rest == ["more"]}

      [offset] ->
        {0, max(integer(offset), 0), false}
    end
  end

  defp cursor(_value, _count), do: {0, 0, false}

  # A cycle with every leg short is what ends the pagination: a term still
  # unasked at this offset always has a page, and a full page from *any* term
  # means that term's window has more behind it, so the whole cycle advances
  # even when the last leg came up short. The `more` flag carries that fact
  # from leg to leg, because only the cursor survives between pages. A term
  # exhausted early in a cycle is asked once more in the next one and answers
  # empty, which costs one search and is bounded by `:max_pages_per_context`.
  defp next_cursor({index, offset, count, more}, scanned) do
    more = more or scanned == @scan_window

    cond do
      index + 1 < count -> "#{index + 1}:#{offset}" <> if(more, do: ":more", else: "")
      more -> "0:#{offset + @scan_window}"
      true -> nil
    end
  end

  defp hydrate(entities, request, term, position, ids, request_fun) do
    ids = Enum.take(ids, @scan_window)

    case fetch_objects(ids, request_fun, []) do
      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}

      {:ok, objects} ->
        keep(entities, request, term, position, ids, objects)
    end
  end

  # One object at a time, each with its own stage name. The stage is the retry
  # ladder's key, so sharing one across 25 hydrations would exhaust the whole
  # page's attempts on the third object. A single object that will not come back
  # is dropped; the page is still a page without it.
  defp fetch_objects([], _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_objects([id | rest], request_fun, acc) do
    case request_fun.("object:#{id}", %{"endpoint" => "object", "object_id" => id}) do
      {:ok, object} when is_map(object) ->
        fetch_objects(rest, request_fun, [object | acc])

      {:ok, _body} ->
        fetch_objects(rest, request_fun, acc)

      {:error, _code} ->
        fetch_objects(rest, request_fun, acc)

      {:deferred, code, seconds} ->
        {:deferred, code, seconds}
    end
  end

  defp keep(entities, request, term, {term_index, offset, _count, _more} = position, ids, objects) do
    index = Enum.into(entities, %{}, &{&1["qid"], &1})
    {matcher, walk} = BroaderWalk.build(objects, Map.keys(index), request["broader_index"])

    items =
      objects
      |> Enum.filter(&displayable?/1)
      |> Enum.flat_map(fn object ->
        case matched_tags(object, index, matcher) do
          [] -> []
          tags -> [item(object, tags, term)]
        end
      end)
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.take(request["first"] || @scan_window)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    {:ok,
     %{
       request_parameters:
         request
         |> Map.put("term_index", term_index)
         |> Map.put("offset", Integer.to_string(offset))
         |> Map.put("scanned", length(ids))
         |> Map.put("broader_index", walk),
       items: items,
       next_cursor: next_cursor(position, length(ids)),
       completion_reason: if(items == [], do: :no_results, else: :results)
     }}
  end

  # The public-domain gate, applied where it is reliable. The search parameter
  # is not: `isPublicDomain=true` returned objects whose payload says false.
  defp displayable?(%{"isPublicDomain" => true} = object) do
    is_binary(object["primaryImageSmall"]) and object["primaryImageSmall"] != "" and
      is_integer(object["objectID"])
  end

  defp displayable?(_object), do: false

  defp matched_tags(object, index, matcher) do
    object
    |> tags()
    |> Enum.flat_map(fn {term, qid} ->
      cond do
        is_map_key(index, qid) ->
          entity = index[qid]

          [
            %{
              "term" => term,
              "qid" => qid,
              "relation" => "exact",
              "entity_qid" => qid,
              "entity_label" => entity["label"]
            }
          ]

        true ->
          case matcher.(qid) do
            {:ok, entity_qid, via} ->
              [
                %{
                  "term" => term,
                  "qid" => qid,
                  "relation" => "broader",
                  "entity_qid" => entity_qid,
                  "entity_label" => index[entity_qid]["label"],
                  "via" => via
                }
              ]

            :none ->
              []
          end
      end
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  @doc "The `{term, QID}` pairs of an object's tags, dropping any tag without a QID."
  def tags(object) do
    object
    |> Map.get("tags")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"term" => term, "Wikidata_URL" => url} when is_binary(term) ->
        case qid_from_url(url) do
          nil -> []
          qid -> [{term, qid}]
        end

      _ ->
        []
    end)
  end

  @doc "The QID at the end of a `wikidata.org/wiki/Qnnn` URL, or nil."
  def qid_from_url(url) when is_binary(url) do
    case Regex.run(~r{wikidata\.org/(?:wiki|entity)/(Q\d+)\z}, String.trim(url)) do
      [_, qid] -> qid
      _ -> nil
    end
  end

  def qid_from_url(_url), do: nil

  defp item(object, tags, term) do
    external_id = Integer.to_string(object["objectID"])

    %{
      external_namespace: "met_object",
      external_id: external_id,
      identifiers: identifiers(external_id, object),
      position: 0,
      match_details: %{
        "kind" => "tag",
        "evidence" => "identity",
        "query" => term,
        "tags" => tags
      },
      preview_metadata: %{
        "title" => title(object),
        "year" => presence(object["objectDate"]),
        "image_url" => object["primaryImageSmall"],
        "thumbnail_url" => object["primaryImageSmall"],
        "source_url" => presence(object["objectURL"]),
        "credit_line" => presence(object["creditLine"]),
        "artist" => presence(object["artistDisplayName"]),
        "content_type" => "artwork",
        "provider" => "The Met",
        "matched_tags" => Enum.map(tags, &Map.take(&1, ["term", "qid"]))
      },
      display_allowed: true
    }
  end

  defp identifiers(external_id, object) do
    [%{namespace: "met_object_id", external_id: external_id, metadata: %{"field" => "objectID"}}] ++
      case qid_from_url(object["objectWikidata_URL"]) do
        nil ->
          []

        qid ->
          [
            %{
              namespace: "wikidata",
              external_id: qid,
              metadata: %{"field" => "objectWikidata_URL"}
            }
          ]
      end
  end

  # Clamped to `entities.preferred_label`'s width, which this source reaches:
  # 16 of the 1,644 highlight titles in `met-highlights-v1` exceed it (the
  # longest is 498), and a 300-character clamp reached the database as a 22001
  # and killed the run.
  defp title(object) do
    case presence(object["title"]) do
      nil -> "Untitled"
      title -> clamp_label(title)
    end
  end

  @impl DevilsDictionary.SourceIdentity.Adapter
  def identity_record(%{external_namespace: "met_object", external_id: met_id} = item) do
    metadata = item.preview_metadata

    Entry.new(%{
      source_slug: slug(),
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "artwork",
      stable_identifier: %{namespace: "met_object_id", external_id: met_id},
      identifiers: Map.get(item, :identifiers, []),
      label: metadata["title"],
      year: begin_year(metadata["year"]),
      metadata: %{
        "image_url" => metadata["image_url"],
        "image_attribution" => metadata["credit_line"],
        "credit_line" => metadata["credit_line"],
        "artist_display_name" => metadata["artist"],
        "object_date" => metadata["year"],
        "content_type" => "artwork"
      },
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported_met_identity}

  # `objectDate` is free text — "ca. 1780", "1863–65", "19th century". The first
  # four-digit run is the only part that is a year, and there may not be one.
  defp begin_year(value) when is_binary(value) do
    case Regex.run(~r/\d{4}/, value) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp begin_year(_value), do: nil

  @impl true
  def retryable_status?(403), do: true

  def retryable_status?(status),
    do: DevilsDictionary.Discovery.Transport.default_retryable_status?(status)

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  # This provider's own stanza; the read is the kit's.
  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:met)
end
