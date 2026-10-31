defmodule DevilsDictionaryWeb.RecordExplorer do
  @moduledoc """
  Page-scoped exploration of the already-permitted source projection (#291).
  Filters neither fetch providers nor write records. Browser-only payloads stay
  in the browser; the hook reads their current DOM and stores no content.
  """
  use DevilsDictionaryWeb, :html

  attr :id, :string, required: true
  attr :filters, :map, default: %{}
  attr :params, :map, default: %{}
  attr :sources, :list, default: []

  def controls(assigns) do
    source_options =
      [{"All sources", ""}, {"Native links and claims", "native"}] ++
        Enum.map(assigns.sources, &{&1.name, &1.slug})

    selected_source = assigns.filters["source"]

    source_options =
      if selected_source && not Enum.any?(source_options, fn {_, id} -> id == selected_source end),
        do: source_options ++ [{selected_source, selected_source}],
        else: source_options

    assigns =
      assigns
      |> assign(:form, to_form(assigns.filters))
      |> assign(:source_options, source_options)

    ~H"""
    <div
      id={@id}
      phx-hook="RecordExplorer"
      phx-update="ignore"
      class="record-filters"
    >
      <aside class="record-category-rail" aria-label="Browse materials">
        <h2 class="record-rail-heading">Browse materials</h2>
        <div data-record-categories role="group" aria-label="Material categories"></div>
        <details class="record-help">
          <summary>About these materials</summary>
          <p>
            Counts cover loaded records, not entire provider catalogues. Dictionary counts include their senses. Browser-only results stay on your device. Complete texts, credits, dates and provider status remain below.
          </p>
        </details>
      </aside>
      <div class="record-search-body">
        <.form for={@form} id="record-search" method="get" action="" class="record-toolbar">
          <input type="hidden" name="view" value="records" />
          <input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
          <input id="record-type" type="hidden" name="type" value={@filters["type"] || ""} />
          <div class="record-query-control">
            <.input
              id="record-query"
              name="q"
              type="search"
              label="Search all materials"
              value={@filters["q"] || ""}
              placeholder="Titles, creators, words…"
              class="record-control"
            />
          </div>
          <div class="record-source-control">
            <.input
              id="record-source"
              name="source"
              type="select"
              label="Source / API"
              value={@filters["source"] || ""}
              options={@source_options}
              class="record-control"
            />
          </div>
          <button type="submit" class="sr-only">Search materials</button>
          <a
            id="record-clear"
            href={"?" <> URI.encode_query(Map.put(@params, "view", "records"))}
            class="record-clear"
          >Clear</a>
        </.form>
        <div class="record-result-bar">
          <p data-record-status role="status" aria-live="polite">Loading materials…</p>
          <div role="group" aria-label="Result layout" class="record-layout-controls">
            <button type="button" data-record-layout="list" aria-pressed="true">List</button>
            <button type="button" data-record-layout="grid" aria-pressed="false">Grid</button>
          </div>
        </div>
        <div data-record-results class="record-results" aria-label="Matching materials"></div>
        <button type="button" data-record-more class="record-more" hidden>
          Show more loaded materials
        </button>
      </div>
      <noscript><p>Filtering requires JavaScript. All source records remain readable below.</p></noscript>
    </div>
    """
  end

  @doc "Bounded string-only filter parameters; malformed nested query values do not reach forms."
  def filters(params) do
    params
    |> Map.take(["q", "type", "source"])
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Map.new(fn {key, value} -> {key, String.slice(value, 0, 300)} end)
  end

  @doc "Source identities and labels already exposed by the public record projection."
  def sources(sources) do
    values =
      sources
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn source ->
        %{
          id: Map.get(source, :slug) || "native",
          label: Map.get(source, :name) || Map.get(source, :slug) || "Native links and claims"
        }
      end)
      |> Enum.uniq()

    Jason.encode!(
      if values == [], do: [%{id: "native", label: "Native links and claims"}], else: values
    )
  end
end
