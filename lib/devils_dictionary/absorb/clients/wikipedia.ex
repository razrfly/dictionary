defmodule DevilsDictionary.Absorb.Clients.Wikipedia do
  @moduledoc """
  English Wikipedia, through the Action API rather than `rest_v1/page/summary`.

  #69 §2 pins the REST summary, one title per request. The Action API takes
  **20 titles per request** and returns strictly more of what the pipeline needs:

    * `normalized` and `redirects`, so `oyster drill` is reported as landing on
      *Urosalpinx cinerea* instead of the caller having to guess;
    * `pageprops.disambiguation`, a flag rather than an inferred `type`;
    * `pageprops.wikibase_item`, the QID that seeds the whole Wikidata pass;
    * `missing: true` for a title with no article, which is the absent marker.

  19,987 scope lemmas therefore cost ~1,000 requests instead of ~20,000. The
  record's `url` still points at the canonical article, so the link back is
  unchanged.
  """

  alias DevilsDictionary.Absorb.Clients.HTTP

  @api "https://en.wikipedia.org/w/api.php"
  @batch 20

  @doc "Maximum titles per request. `exlimit` caps extracts at 20."
  def batch_size, do: @batch

  @doc """
  Looks up at most #{@batch} titles.

  Returns `{:ok, %{requested_title => page | :missing}}`, keyed by the title the
  caller asked for — the response's `normalized` and `redirects` chains are
  followed back so the caller never has to.
  """
  def summaries(titles, opts \\ [])

  def summaries([], _opts), do: {:ok, %{}}

  def summaries(titles, opts) when length(titles) <= @batch do
    params = [
      action: "query",
      format: "json",
      formatversion: "2",
      redirects: "1",
      titles: Enum.join(titles, "|"),
      prop: "extracts|pageimages|pageprops|description|info",
      exintro: "1",
      explaintext: "1",
      exlimit: "20",
      piprop: "thumbnail",
      pithumbsize: "400",
      ppprop: "wikibase_item|disambiguation",
      inprop: "url"
    ]

    with {:ok, body} <- HTTP.get_json(@api, params, opts) do
      {:ok, index(titles, body["query"] || %{})}
    end
  end

  @doc """
  QIDs and descriptions only, for disambiguation candidates.

  Same endpoint without the extract, so the limit is 50 rather than 20 and a
  page of candidates costs one call.
  """
  def pageprops(titles, opts \\ [])

  def pageprops([], _opts), do: {:ok, %{}}

  def pageprops(titles, opts) do
    params = [
      action: "query",
      format: "json",
      formatversion: "2",
      redirects: "1",
      titles: Enum.join(titles, "|"),
      prop: "pageprops|description|info",
      ppprop: "wikibase_item|disambiguation",
      inprop: "url"
    ]

    with {:ok, body} <- HTTP.get_json(@api, params, opts) do
      {:ok, index(titles, body["query"] || %{})}
    end
  end

  @doc """
  The namespace-0 links of one page — the candidate articles of a
  disambiguation page ("Seal" lists 63).
  """
  def links(title, opts \\ []) do
    params = [
      action: "query",
      format: "json",
      formatversion: "2",
      redirects: "1",
      titles: title,
      prop: "links",
      plnamespace: "0",
      pllimit: "max"
    ]

    with {:ok, body} <- HTTP.get_json(@api, params, opts) do
      links =
        body
        |> get_in(["query", "pages"])
        |> List.wrap()
        |> Enum.flat_map(&(&1["links"] || []))
        |> Enum.map(& &1["title"])

      {:ok, links}
    end
  end

  # ── response indexing ────────────────────────────────────────────────────

  # The API answers by resolved title. `normalized` ("oyster drill" →
  # "Oyster drill") and `redirects` ("Oyster drill" → "Urosalpinx cinerea") are
  # separate chains and must both be walked, or a redirected lemma looks missing.
  defp index(titles, query) do
    pages = Map.new(List.wrap(query["pages"]), &{&1["title"], &1})
    steps = chain(query["normalized"]) |> Map.merge(chain(query["redirects"]))

    Map.new(titles, fn title ->
      resolved = follow(title, steps, 0)

      case Map.get(pages, resolved) do
        nil -> {title, :missing}
        %{"missing" => true} -> {title, :missing}
        page -> {title, page}
      end
    end)
  end

  defp chain(nil), do: %{}
  defp chain(entries), do: Map.new(entries, &{&1["from"], &1["to"]})

  # Depth-capped: the API never returns a cycle, but a bad response should not
  # spin a 19,987-lemma absorb.
  defp follow(title, _steps, depth) when depth > 4, do: title

  defp follow(title, steps, depth) do
    case Map.get(steps, title) do
      nil -> title
      next -> follow(next, steps, depth + 1)
    end
  end
end
