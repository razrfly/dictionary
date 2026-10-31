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
      class="record-filters border-y border-mist-950/10 py-6 dark:border-white/10"
    >
      <.form for={@form} id="record-search" method="get" action="" class="flex flex-col gap-4">
        <input type="hidden" name="view" value="records" />
        <input :for={{key, value} <- @params} type="hidden" name={key} value={value} />
        <div class="grid min-w-0 grid-cols-1 gap-4 sm:grid-cols-3">
          <.input
            id="record-query"
            name="q"
            type="search"
            label="Search this entry’s records"
            value={@filters["q"] || ""}
            placeholder="Words, titles, creators…"
          />
          <.input
            id="record-type"
            name="type"
            type="select"
            label="Content type"
            value={@filters["type"] || ""}
            options={[
              {"All types", ""},
              {"Definitions", "definition"},
              {"Examples and claims", "example"},
              {"Quotations", "quote"},
              {"Artworks", "artwork"},
              {"Images", "image"},
              {"Films", "film"},
              {"Books, poems and articles", "text"},
              {"News", "news"},
              {"Music", "music"},
              {"GIFs", "gif"},
              {"Entities and subjects", "entity"},
              {"Related words", "related"}
            ]}
          />
          <.input
            id="record-source"
            name="source"
            type="select"
            label="Source / API"
            value={@filters["source"] || ""}
            options={@source_options}
          />
        </div>
        <div class="flex flex-wrap items-center gap-5 text-base/7">
          <button
            type="submit"
            class="rounded-md bg-mist-950 px-4 py-2 text-white dark:bg-white dark:text-mist-950"
          >Search</button>
          <a
            id="record-clear"
            href={"?" <> URI.encode_query(Map.put(@params, "view", "records"))}
            class="underline underline-offset-4"
          >Clear filters</a>
          <p
            data-record-status
            role="status"
            aria-live="polite"
            class="text-mist-600 dark:text-mist-400"
          >
            All available records
          </p>
        </div>
      </.form>
      <p class="mt-4 max-w-[80ch] text-base/7 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400">
        Search covers the records already available for this entry, including fetched pages.
        “More” may acquire additional results within the existing provider limits.
        Browser-only results are filtered on your device and are not saved.
        Definition cards retain their source context when a quotation matches.
      </p>
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
