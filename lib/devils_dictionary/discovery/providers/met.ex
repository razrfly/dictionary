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

  import Ecto.Query

  alias DevilsDictionary.Discovery.Providers.Met.BroaderWalk
  alias DevilsDictionary.Registry.{Entity, Lexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Entry

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
      min_retry_interval_ms: 1_500
    }
  end

  @impl true
  def shelf_detail, do: "tags: Wikidata"

  @impl true
  def enabled? do
    config()[:enabled] != false
  end

  @doc """
  The QIDs the page's senses already point at, with the labels to search for.

  This is the whole of the Met's association evidence, and it is read from the
  encyclopedia rather than from the provider: a sense's active `refers_to`
  entity is a claim someone can inspect and withdraw. A target with no such
  claim yields an empty set, and `covers?/1` then declines it outright.

  ## Why this reads the page and not the target lexeme

  `Discovery.target_for_page/3` resolves a page to **one** lexeme — the lowest
  id when several share the address — and marks the target `term_unverified`
  when there is more than one. `/define/war` is seven lexemes: the verb, the
  noun, a prefix, and four names. The lowest id is the *verb*, and the QID for
  Q198 hangs off a sense of the *noun*. Reading only the target lexeme would
  have put no artwork on `/define/war` while the encyclopedia plainly says what
  *war* means.

  So the evidence is scoped the way the page itself is scoped
  (`Lexicon.by_lemma_or_slug/2`: same language, matching lemma or slug), which
  is also the scope the shelf already admits to when it says *keyword relevance
  to this particular meaning is unverified*. Narrowing this to one sense is a
  sense-level-target change, and that belongs to whatever phase moves
  `target_for_page/3` — not to a provider reaching around it.
  """
  def target_entities(object_id) do
    case Repo.one(
           from lx in Lexeme,
             where: lx.object_id == ^object_id,
             select: {lx.lemma, lx.slug, lx.language_tag}
         ) do
      nil -> []
      {lemma, slug, language} -> entities_for_page(lemma, slug, language)
    end
  end

  defp entities_for_page(lemma, slug, language) do
    down = String.downcase(lemma)

    Repo.all(
      from s in Sense,
        join: lx in Lexeme,
        on: lx.object_id == s.lexeme_id,
        join: r in DevilsDictionary.Claims.AssertionRevision,
        on: r.subject_object_id == s.object_id and r.is_current,
        join: p in DevilsDictionary.Claims.Predicate,
        on: p.id == r.predicate_id and p.key == "refers_to",
        join: e in Entity,
        on: e.object_id == r.object_object_id,
        join: ei in DevilsDictionary.Registry.ExternalIdentifier,
        on: ei.object_id == e.object_id and ei.namespace == "wikidata",
        where:
          lx.language_tag == ^language and
            (fragment("lower(?)", lx.lemma) == ^down or lx.slug == ^slug),
        where: r.lifecycle_state == :active and ei.status == :verified,
        select: %{
          qid: ei.external_id,
          label: e.preferred_label,
          object_id: e.object_id,
          confidence: r.confidence
        },
        order_by: [desc: r.confidence, asc: e.object_id]
    )
    |> Enum.uniq_by(& &1.qid)
    |> Enum.take(@max_entities)
    |> Enum.map(&Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
  end

  @impl true
  def covers?(target) do
    target_entities(target.object_id) != []
  end

  @doc """
  The QID set this target's mapping was built from, as a short digest.

  `automatic_mapping/1` freezes the QIDs into the mapping parameters, and
  `retrieve/4` matches tags against those frozen QIDs — so a `refers_to` claim
  withdrawn or replaced after the mapping was created would otherwise keep the
  Met querying a concept the encyclopedia has stopped asserting. Coverage does
  not catch this: swapping QID A for QID B leaves the set non-empty and
  `covers?/1` still says yes.

  The digest covers the QIDs **in order**, because order is what
  `search_terms/2` reads, and not the labels, because a relabelled entity is the
  same evidence — the match key is the QID.
  """
  @impl true
  def mapping_identity(object_id) do
    case target_entities(object_id) do
      [] ->
        "no-entities"

      entities ->
        entities
        |> Enum.map_join(",", & &1["qid"])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  @impl true
  def automatic_mapping(target) do
    entities = target_entities(target.object_id)
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
       "search_terms" => search_terms(entities, term)
     }}
  end

  defp search_terms(entities, term) do
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
    if Enum.all?(entities, &valid_entity?/1), do: :ok, else: {:error, :invalid_mapping}
  end

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  defp valid_entity?(%{"qid" => qid}) when is_binary(qid),
    do: Regex.match?(~r/\AQ\d+\z/, qid)

  defp valid_entity?(_), do: false

  @impl true
  def request_options(%{"endpoint" => "search", "params" => params}) do
    [method: :get, url: @base <> @search_path, params: params, headers: headers()]
  end

  def request_options(%{"endpoint" => "object", "object_id" => object_id}) do
    [method: :get, url: "#{@base}#{@object_path}/#{object_id}", headers: headers()]
  end

  defp headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
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
    offset = offset(request["after"])
    term = mapping["search_terms"] |> List.wrap() |> List.first() || mapping["term"]

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

    case request_fun.("search", payload) do
      {:ok, %{"objectIDs" => ids}} when is_list(ids) ->
        hydrate(entities, request, term, offset, ids, request_fun)

      # The Met answers a search with no matches with a null `objectIDs`, so
      # this is an ordinary empty page rather than a malformed body.
      {:ok, %{"total" => total}} when is_integer(total) ->
        {:ok, empty(request, :no_results)}

      {:ok, _body} ->
        {:error, "malformed_response"}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  defp hydrate(entities, request, term, offset, ids, request_fun) do
    ids = Enum.take(ids, @scan_window)

    case fetch_objects(ids, request_fun, []) do
      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}

      {:ok, objects} ->
        keep(entities, request, term, offset, ids, objects)
    end
  end

  # One object at a time, each with its own stage name. The stage is the retry
  # ladder's key, so sharing one across 25 hydrations would exhaust the whole
  # page's attempts on the third object. A single object that will not come back
  # is dropped; the page is still a page without it.
  defp fetch_objects([], _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_objects([id | rest], request_fun, acc) do
    pace()

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

  defp pace do
    case config()[:request_interval_ms] do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp keep(entities, request, term, offset, ids, objects) do
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
         |> Map.put("offset", Integer.to_string(offset))
         |> Map.put("scanned", length(ids))
         |> Map.put("broader_index", walk),
       items: items,
       # A short page means the search is out of candidates; a full one means
       # there is at least one more window behind it.
       next_cursor: if(length(ids) == @scan_window, do: Integer.to_string(offset + @scan_window)),
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

  defp title(object) do
    case presence(object["title"]) do
      nil -> "Untitled"
      title -> String.slice(title, 0, 300)
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

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :met, [])
end
