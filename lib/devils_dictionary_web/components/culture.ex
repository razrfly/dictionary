defmodule DevilsDictionaryWeb.Culture do
  @moduledoc "Provider-neutral reader cards for factual discovery, never curation."

  use DevilsDictionaryWeb, :html

  attr :states, :map, required: true

  def section(assigns) do
    states = assigns.states |> Map.values() |> Enum.sort_by(& &1.provider)

    assigns =
      assigns
      |> assign(:provider_states, states)
      |> assign(:content_types, content_types(states))
      |> assign(:provider_count, length(states))

    ~H"""
    <section
      :if={@provider_states != []}
      id="in-culture"
      aria-labelledby="in-culture-title"
      class="mt-12 border-t border-mist-950/10 pt-8 dark:border-white/10"
    >
      <div class="flex flex-col gap-6">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div class="flex flex-col gap-2">
            <p class="font-mono text-sm tracking-wide text-mist-500 uppercase">In culture</p>
            <h2
              id="in-culture-title"
              class="font-display text-3xl tracking-tight text-balance text-mist-950 dark:text-white"
            >
              Related discoveries
            </h2>
            <p class="max-w-[64ch] text-base text-pretty text-mist-600 sm:text-sm dark:text-mist-300">
              These are source matches, not curated examples.
            </p>
          </div>

          <div
            id="culture-filters"
            class="flex w-fit flex-wrap items-center gap-2 rounded-full bg-mist-950/5 p-1 dark:bg-white/10"
            aria-label="Available culture types"
          >
            <span
              :for={type <- @content_types}
              id={"culture-filter-#{type}"}
              class="rounded-full bg-white px-3 py-2 text-base text-mist-950 shadow-sm ring-1 ring-black/5 sm:py-1.5 sm:text-sm dark:bg-mist-800 dark:text-white dark:ring-white/10"
            >
              {plural_label(type)}
            </span>
          </div>
        </div>

        <div id="culture-providers" class="flex flex-col gap-8">
          <section
            :for={state <- @provider_states}
            id={"culture-provider-#{state.provider}"}
            aria-label={state.provider_name || state.provider}
            class="flex flex-col gap-4"
          >
            <p :if={@provider_count > 1} class="text-sm font-medium text-mist-500 dark:text-mist-300">
              {state.provider_name || state.provider}
            </p>

            <%= case state.status do %>
              <% :ready -> %>
                <ul
                  id={status_id("culture-results", state, @provider_count)}
                  role="list"
                  class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3"
                >
                  <li
                    :for={item <- state.items}
                    id={"culture-result-#{item.external_namespace}-#{item.external_id}"}
                  >
                    <.media_card item={item} state={state} />
                  </li>
                </ul>

                <button
                  :if={state[:next_cursor]}
                  id={status_id("culture-show-more", state, @provider_count)}
                  type="button"
                  phx-click="discovery_more"
                  phx-value-provider={state.provider}
                  class="min-h-11 w-fit rounded-full bg-mist-950 px-4 py-2 text-sm font-medium text-white transition hover:-translate-y-0.5 hover:bg-mist-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 disabled:cursor-wait disabled:opacity-60 dark:bg-white dark:text-mist-950 dark:hover:bg-mist-200"
                  disabled={state[:loading_more] == true}
                >
                  {if state[:loading_more], do: "Loading…", else: "Show more"}
                </button>
              <% :empty -> %>
                <.status_box id={status_id("culture-empty", state, @provider_count)}>
                  No matching {content_phrase(state)} for this term yet.
                </.status_box>
              <% :failed -> %>
                <.status_box id={status_id("culture-failed", state, @provider_count)}>
                  {content_label(state)} discovery is temporarily unavailable. The definitions above are unaffected.
                </.status_box>
              <% status when status in [:deferred, :withdrawn, :expired] -> %>
                <div
                  id={status_id("culture-deferred", state, @provider_count)}
                  role="status"
                  class="flex items-center gap-3 py-4"
                >
                  <.icon name="hero-clock" class="size-5 text-mist-500 sm:size-4" />
                  <p class="text-base text-mist-600 sm:text-sm dark:text-mist-300">
                    {content_label(state)} discovery will retry when provider capacity is available.
                  </p>
                </div>
              <% _loading_or_idle -> %>
                <div
                  id={status_id("culture-loading", state, @provider_count)}
                  role="status"
                  aria-live="polite"
                  class="flex flex-col gap-4"
                >
                  <div class="flex items-center gap-3">
                    <.icon
                      name="hero-arrow-path"
                      class="size-5 motion-safe:animate-spin text-mist-500 sm:size-4"
                    />
                    <p class="text-base text-mist-600 sm:text-sm dark:text-mist-300">
                      Looking for matching {content_phrase(state)}…
                    </p>
                  </div>
                  <div class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3" aria-hidden="true">
                    <div
                      :for={id <- 1..3}
                      id={"culture-skeleton-#{state.provider}-#{id}"}
                      class="overflow-hidden rounded-xl bg-mist-950/5 ring-1 ring-black/5 dark:bg-white/5 dark:ring-white/10"
                    >
                      <div class="aspect-[2/1] animate-pulse bg-mist-200 dark:bg-mist-800" />
                      <div class="flex flex-col gap-3 p-5">
                        <div class="h-5 w-2/3 animate-pulse rounded bg-mist-200 dark:bg-mist-800" />
                        <div class="h-4 w-full animate-pulse rounded bg-mist-200 dark:bg-mist-800" />
                      </div>
                    </div>
                  </div>
                </div>
            <% end %>
          </section>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  defp status_box(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="rounded-xl bg-mist-950/5 p-5 ring-1 ring-black/5 dark:bg-white/5 dark:ring-white/10"
    >
      <p class="text-base text-pretty text-mist-700 sm:text-sm dark:text-mist-200">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :state, :map, required: true

  defp media_card(assigns) do
    assigns =
      assigns
      |> assign(:preview, assigns.item.preview_metadata)
      |> assign(:matches, assigns.item.match_details)
      |> assign(:type, assigns.item.preview_metadata["content_type"] || "work")
      |> assign(
        :image_url,
        assigns.item.preview_metadata["poster_url"] || assigns.item.preview_metadata["image_url"]
      )

    ~H"""
    <article class="h-full overflow-hidden rounded-xl bg-white shadow-sm ring-1 ring-black/5 transition duration-200 hover:-translate-y-0.5 hover:shadow-md dark:bg-mist-900 dark:ring-white/10">
      <%= if @image_url do %>
        <img
          src={@image_url}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class="aspect-[2/1] w-full object-cover object-[50%_24%] outline-1 -outline-offset-1 outline-black/5 dark:outline-white/10"
        />
      <% else %>
        <div
          id={"culture-missing-poster-#{@item.external_id}"}
          class="flex aspect-[2/1] items-center justify-center bg-mist-100 dark:bg-mist-800"
        >
          <div class="flex flex-col items-center gap-2 text-mist-500 dark:text-mist-300">
            <.icon name={type_icon(@type)} class="size-8" />
            <p class="font-mono text-sm tracking-wide uppercase">{singular_label(@type)}</p>
          </div>
        </div>
      <% end %>

      <div class="flex flex-col gap-4 p-5">
        <div class="flex flex-col gap-1">
          <p class="font-mono text-sm tracking-wide text-mist-500 uppercase">
            {singular_label(@type)}
          </p>
          <h3 class="text-xl font-medium text-balance text-mist-950 dark:text-white">
            {@preview["title"]}<span :if={@preview["year"]} class="font-normal text-mist-500"> · {@preview[
              "year"
            ]}</span>
          </h3>
        </div>

        <p class="text-base text-pretty text-mist-700 sm:text-sm dark:text-mist-200">
          {match_summary(@matches, @state.term)}
        </p>
        <p
          :if={@state.relevance == "term_unverified"}
          class="text-base text-pretty text-mist-600 sm:text-sm dark:text-mist-300"
        >
          Keyword relevance to this particular meaning is unverified.
        </p>
        <p class="text-base text-mist-500 sm:text-sm">
          {@preview["provider"] || @state.provider_name}<span :if={@preview["keyword_source"]}> · keywords: {@preview[
            "keyword_source"
          ]}</span>
        </p>

        <details class="group border-t border-mist-950/10 pt-4 dark:border-white/10">
          <summary class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 text-base font-medium text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 sm:text-sm dark:text-white">
            Details
            <.icon name="hero-chevron-down" class="size-5 transition group-open:rotate-180 sm:size-4" />
          </summary>
          <div class="flex flex-col gap-3 pt-4">
            <h4 class="text-base font-medium text-mist-950 sm:text-sm dark:text-white">
              Why this appeared
            </h4>
            <p class="text-base text-pretty text-mist-600 sm:text-sm dark:text-mist-300">
              {match_detail(@matches, @state.term)}
            </p>
            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-base sm:text-sm">
              <dt class="text-mist-500">Source</dt>
              <dd class="text-mist-800 dark:text-mist-100">
                {@preview["provider"] || @state.provider_name}
              </dd>
              <dt :if={@preview["keyword_source"]} class="text-mist-500">Keyword source</dt>
              <dd :if={@preview["keyword_source"]} class="text-mist-800 dark:text-mist-100">
                {@preview["keyword_source"]}
              </dd>
            </dl>
            <a
              :if={@preview["source_url"]}
              id={"culture-source-#{@item.external_id}"}
              href={@preview["source_url"]}
              target="_blank"
              rel="noreferrer"
              class="flex min-h-11 w-fit items-center gap-2 rounded-md py-2 text-base font-medium text-mist-950 underline decoration-mist-300 underline-offset-4 transition hover:decoration-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 sm:text-sm dark:text-white dark:decoration-mist-600 dark:hover:decoration-white"
            >
              View {String.downcase(singular_label(@type))} at source
              <.icon name="hero-arrow-up-right" class="size-5 sm:size-4" />
            </a>
          </div>
        </details>
      </div>
    </article>
    """
  end

  defp status_id(base, _state, 1), do: base
  defp status_id(base, state, _count), do: "#{base}-#{state.provider}"

  defp content_types(states),
    do:
      states
      |> Enum.flat_map(&Map.get(&1, :content_types, []))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

  defp content_label(state), do: state |> primary_type() |> plural_label()
  defp content_phrase(state), do: state |> content_label() |> String.downcase()
  defp primary_type(state), do: state |> Map.get(:content_types, [:work]) |> List.first() || :work

  defp singular_label(type) when type in [:film, "film"], do: "Film"
  defp singular_label(type) when type in [:art, "art"], do: "Artwork"
  defp singular_label(_type), do: "Work"
  defp plural_label(type) when type in [:film, "film"], do: "Films"
  defp plural_label(type) when type in [:art, "art"], do: "Art"
  defp plural_label(_type), do: "Works"
  defp type_icon(type) when type in [:film, "film"], do: "hero-film"
  defp type_icon(type) when type in [:art, "art"], do: "hero-photo"
  defp type_icon(_type), do: "hero-square-3-stack-3d"

  defp match_summary(details, term) do
    case keyword_names(details) do
      [] -> "Search result for “#{term}”"
      names -> "Found through #{keyword_label(names)}: “#{Enum.join(names, "”, “")}”"
    end
  end

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
