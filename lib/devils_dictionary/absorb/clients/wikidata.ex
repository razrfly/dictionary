defmodule DevilsDictionary.Absorb.Clients.Wikidata do
  @moduledoc """
  Wikidata entities, through `wbgetentities` rather than `Special:EntityData`.

  #69 §2 pins `Special:EntityData/{QID}.json`, one entity per request at ~200 KB
  each. `wbgetentities` takes **50 QIDs per request** and, filtered to
  `languages=en` and `sitefilter=enwiki`, returns the same claims for a third of
  the bytes. ~18,000 entities cost ~360 requests instead of 18,000. The record's
  `url` still points at `https://www.wikidata.org/wiki/{QID}`, so the link back
  is unchanged.

  Claims are not filterable server-side — that is what `Sources.Wikidata.trim/1`
  is for.
  """

  alias DevilsDictionary.Absorb.Clients.HTTP

  @api "https://www.wikidata.org/w/api.php"
  @batch 50

  @doc "Maximum entity ids per request, an API limit."
  def batch_size, do: @batch

  @doc """
  Fetches at most #{@batch} entities. Returns `{:ok, %{qid => entity}}`.

  A QID the API does not know is simply absent from the map, which the caller
  turns into an absent marker.
  """
  def fetch(qids, opts \\ [])

  def fetch([], _opts), do: {:ok, %{}}

  def fetch(qids, opts) when length(qids) <= @batch do
    params = [
      action: "wbgetentities",
      format: "json",
      ids: Enum.join(qids, "|"),
      props: "labels|descriptions|aliases|claims|sitelinks",
      # `mul` is not optional: Wikidata moved taxon names to the multilingual
      # label, so `languages=en` alone returns no label at all for 41 % of the
      # taxa an Animals scope walks (measured on a 590-concept slice).
      languages: "en|mul",
      sitefilter: "enwiki"
    ]

    with {:ok, body} <- HTTP.get_json(@api, params, opts) do
      entities =
        body
        |> Map.get("entities", %{})
        |> Enum.reject(fn {_qid, entity} -> entity["missing"] != nil end)
        |> Map.new()

      {:ok, entities}
    end
  end

  @doc "One entity, for `enrich/2`. Same endpoint, same shape."
  def fetch_one(qid, opts \\ []) do
    with {:ok, entities} <- fetch([qid], opts) do
      case Map.get(entities, qid) do
        nil -> {:error, :not_found}
        entity -> {:ok, entity}
      end
    end
  end

  @doc "The API endpoint, for a caller that sends the request through its own transport."
  def api_url, do: @api

  @doc """
  Parameters for reading one wiki's sitelinks off up to #{@batch} items.

  For a caller whose requests go through a budgeted transport rather than
  `fetch/2` — a discovery provider (#158 build 4) asks Wikidata which
  `enwikiquote` page a sense's QID links to, and that request is spent against
  the provider's own ledger. `sitelink_titles/2` reads the answer.
  """
  def sitelink_params(qids, site) when is_list(qids) and length(qids) <= @batch do
    [
      action: "wbgetentities",
      format: "json",
      ids: Enum.join(qids, "|"),
      props: "sitelinks",
      sitefilter: site
    ]
  end

  @doc """
  Parameters for resolving up to #{@batch} page titles on one wiki to the items
  whose sitelink they are: the page `Ambrose Bierce` on `enwikiquote` is
  Q191050. A title is the wiki's own identifier for a page, so this is a
  crosswalk, not a search — a title no item links to is simply absent.
  """
  def title_params(titles, site) when is_list(titles) and length(titles) <= @batch do
    [
      action: "wbgetentities",
      format: "json",
      sites: site,
      titles: Enum.join(titles, "|"),
      props: "sitelinks",
      sitefilter: site
    ]
  end

  @doc """
  `%{qid => title}` for every item in a `wbgetentities` answer that carries a
  sitelink on `site`. Missing items (`"missing"`, the `-1` keys a title lookup
  returns) are left out.
  """
  def sitelink_titles(%{"entities" => entities}, site) when is_map(entities) do
    for {qid, entity} <- entities,
        is_map(entity),
        is_nil(entity["missing"]),
        %{"title" => title} <- [get_in(entity, ["sitelinks", site])],
        into: %{},
        do: {qid, title}
  end

  def sitelink_titles(_body, _site), do: %{}

  @doc """
  The items carrying one exact statement value, by CirrusSearch's
  `haswbstatement`. Returns `{:ok, [qid]}`, in the search's own order.

  This is a lookup by identifier, not a search by name: `P648=OL26320A` either
  is on an item or is not. Open Library's author keys reach a person this way
  (#164 C6). Several answers mean Wikidata itself is ambiguous and the caller
  decides nothing from them.
  """
  def items_with_statement(property, value, opts \\ [])
      when is_binary(property) and is_binary(value) do
    params = [
      action: "query",
      format: "json",
      list: "search",
      srsearch: "haswbstatement:#{property}=#{value}",
      srnamespace: "0",
      srlimit: "5",
      srprop: ""
    ]

    with {:ok, body} <- HTTP.get_json(@api, params, opts) do
      {:ok,
       body
       |> get_in(["query", "search"])
       |> List.wrap()
       |> Enum.flat_map(fn
         %{"title" => "Q" <> _ = qid} -> [qid]
         _ -> []
       end)}
    end
  end

  # ── claim readers ────────────────────────────────────────────────────────
  #
  # A claim is four levels deep and half of them are optional (a `novalue` snak
  # has no `datavalue` at all), so every read goes through these two.

  @doc "Every item id asserted by a property, in statement order."
  def entity_ids(entity, property) do
    entity
    |> claims(property)
    |> Enum.flat_map(fn claim ->
      case get_in(claim, ["mainsnak", "datavalue", "value"]) do
        %{"id" => id} -> [id]
        _ -> []
      end
    end)
  end

  @doc "Every plain string or monolingual-text value asserted by a property."
  def strings(entity, property, lang \\ nil) do
    entity
    |> claims(property)
    |> Enum.flat_map(fn claim ->
      case get_in(claim, ["mainsnak", "datavalue", "value"]) do
        value when is_binary(value) -> [value]
        %{"text" => text, "language" => l} when lang in [nil, l] -> [text]
        _ -> []
      end
    end)
  end

  @doc "The first value of `strings/3`, or nil."
  def string(entity, property, lang \\ nil) do
    case strings(entity, property, lang) do
      [value | _] -> value
      [] -> nil
    end
  end

  @doc """
  Every statement for a property, with its rank, qualifiers and references.

  For callers that need the evidence rather than just the value — the audit's
  finding #8: a deprecated statement was being read as if it were current.
  """
  def statements(entity, property) do
    entity
    |> raw_claims(property)
    |> Enum.map(fn claim ->
      %{
        id: claim["id"],
        rank: claim["rank"] || "normal",
        value: get_in(claim, ["mainsnak", "datavalue", "value"]),
        qualifiers: claim["qualifiers"] || %{},
        references: claim["references"] || []
      }
    end)
  end

  # Wikidata's own rank policy, which the readers above did not apply: a
  # `deprecated` statement is one the community has marked wrong and must never
  # be read as a value. Where any statement is `preferred`, the preferred ones
  # are the answer and the merely `normal` ones are not — that is what "rank"
  # means, and reading them all equally is how a superseded population figure or
  # a former taxonomic parent ends up on the page beside the current one.
  #
  # The full statements, ranks and references are still available through
  # `statements/2`, so nothing is discarded — only the *default reading* changes.
  defp claims(entity, property) do
    all = entity |> raw_claims(property) |> Enum.reject(&(&1["rank"] == "deprecated"))

    case Enum.filter(all, &(&1["rank"] == "preferred")) do
      [] -> all
      preferred -> preferred
    end
  end

  defp raw_claims(entity, property),
    do: entity |> Map.get("claims", %{}) |> Map.get(property, [])
end
