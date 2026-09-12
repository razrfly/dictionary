defmodule DevilsDictionaryWeb.Culture do
  @moduledoc "Compact poster shelf for factual film discovery."
  use DevilsDictionaryWeb, :html

  attr :states, :map, required: true

  def section(assigns) do
    assigns =
      assign(
        assigns,
        :provider_states,
        assigns.states |> Map.values() |> Enum.sort_by(& &1.provider)
      )

    ~H"""
    <.compact_section :if={@provider_states != []} states={@provider_states} />
    """
  end

  attr :states, :list, required: true

  defp compact_section(assigns) do
    assigns = assign(assigns, :provider_count, length(assigns.states))

    ~H"""
    <section
      id="in-culture"
      aria-label="Related discoveries"
      class="mt-6 border-y border-mist-950/10 py-5 dark:border-white/10"
    >
      <div :for={state <- @states} id={"culture-provider-#{state.provider}"} class="space-y-3">
        <%= if state.status == :ready do %>
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h2
              id="culture-filter-film"
              class="font-display text-xl text-balance text-mist-950 dark:text-white"
            >
              Films
            </h2>
            <p class="text-base text-mist-500 sm:text-sm">{state.provider_name} · keywords: TMDb</p>
          </div>
          <ul
            role="list"
            tabindex="0"
            aria-label="Film matches; scroll for more"
            id={status_id("culture-results", state, @provider_count)}
            class="flex snap-x snap-proximity gap-5 overflow-x-auto overscroll-x-contain pb-3 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            <li
              :for={item <- state.items}
              id={"culture-result-#{item.external_namespace}-#{item.external_id}"}
              class="w-24 shrink-0 snap-start sm:w-28"
            >
              <.film_thumbnail item={item} />
            </li>
          </ul>
          <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
            <.compact_note state={state} />
            <.compact_more state={state} />
          </div>
        <% else %>
          <h2 class="font-display text-xl text-mist-950 dark:text-white">In film</h2>
          <p
            id={status_id(status_base(state.status), state, @provider_count)}
            role="status"
            class="text-base text-mist-500 sm:text-sm"
          >
            <%= case state.status do %>
              <% :empty -> %>
                No matching films for this term yet.
              <% :failed -> %>
                Film discovery is temporarily unavailable.
              <% status when status in [:deferred, :expired, :withdrawn] -> %>
                Film discovery will retry when available.
              <% _ -> %>
                Looking for matching films…
            <% end %>
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true

  defp film_thumbnail(assigns) do
    assigns =
      assign(
        assigns,
        :image,
        assigns.item.preview_metadata["poster_url"] || assigns.item.preview_metadata["image_url"]
      )

    ~H"""
    <a
      href={@item.preview_metadata["source_url"]}
      target="_blank"
      rel="noreferrer"
      id={"culture-source-#{@item.external_id}"}
      class="group flex min-w-0 flex-col gap-2 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2"
    >
      <div class="aspect-[2/3] w-full shrink-0 overflow-hidden rounded-sm bg-mist-950/5 dark:bg-white/5">
        <img
          :if={@image}
          src={@image}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class="size-full object-cover"
        />
        <div
          :if={!@image}
          id={"culture-missing-poster-#{@item.external_id}"}
          class="flex size-full items-center justify-center text-mist-400"
        >
          <.icon name="hero-film" class="size-5" />
        </div>
      </div>
      <div class="min-w-0 space-y-1">
        <h3 class="line-clamp-2 text-base font-medium text-balance text-mist-950 group-hover:underline sm:text-sm dark:text-white">
          {@item.preview_metadata["title"]}
        </h3>
        <p class="text-base tabular-nums text-mist-500 sm:text-sm">
          {@item.preview_metadata["year"] || "Year unknown"}
        </p>
      </div>
    </a>
    """
  end

  attr :state, :map, required: true

  defp compact_note(assigns) do
    ~H"""
    <details id={"culture-about-#{@state.provider}"}>
      <summary class="w-fit cursor-pointer text-base text-mist-500 hover:text-mist-700 sm:text-sm dark:text-mist-400">
        Keyword matches for “{@state.term}” · About these results
      </summary>
      <div class="space-y-2 pt-2 text-base text-mist-600 sm:text-sm dark:text-mist-300">
        <p class="text-pretty">
          Source matches from {@state.provider_name}, using TMDb keywords. These are search results, not curated examples.
        </p>
        <p :if={@state.relevance == "term_unverified"} class="text-pretty">
          Keyword relevance to this particular meaning is unverified.
        </p>
        <ul role="list" class="space-y-1">
          <li :for={item <- @state.items}>
            {item.preview_metadata["title"]}: {match_detail(item.match_details, @state.term)}
          </li>
        </ul>
      </div>
    </details>
    """
  end

  attr :state, :map, required: true

  defp compact_more(assigns) do
    ~H"""
    <button
      :if={@state[:next_cursor]}
      type="button"
      phx-click="discovery_more"
      phx-value-provider={@state.provider}
      disabled={@state[:loading_more] == true}
      class="rounded-sm py-1 text-sm text-mist-600 underline underline-offset-4 hover:text-mist-950 disabled:opacity-50 dark:text-mist-300"
    >{if @state[:loading_more], do: "Loading…", else: "Find more films"}</button>
    """
  end

  defp status_id(base, _state, 1), do: base
  defp status_id(base, state, _count), do: "#{base}-#{state.provider}"
  defp status_base(:empty), do: "culture-empty"
  defp status_base(:failed), do: "culture-failed"

  defp status_base(status) when status in [:deferred, :expired, :withdrawn],
    do: "culture-deferred"

  defp status_base(_), do: "culture-loading"

  defp match_detail(details, term) do
    case keyword_names(details) do
      [] -> "The provider returned this result for “#{term}”."
      names -> "Matched #{keyword_label(names)} “#{Enum.join(names, "”, “")}” for this term."
    end
  end

  defp keyword_names(details),
    do:
      details
      |> Map.get("keywords", [])
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

  defp keyword_label([_one]), do: "the keyword"
  defp keyword_label(_many), do: "keywords"
end
