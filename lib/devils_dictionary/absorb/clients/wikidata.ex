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

  defp claims(entity, property), do: entity |> Map.get("claims", %{}) |> Map.get(property, [])
end
