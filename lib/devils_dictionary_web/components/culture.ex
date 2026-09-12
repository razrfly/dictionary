defmodule DevilsDictionaryWeb.Culture do
  @moduledoc "Reusable reader cards for factual provider discovery, never curation."

  use DevilsDictionaryWeb, :html

  attr :state, :map, required: true

  def section(assigns) do
    ~H"""
    <section
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
            class="flex w-fit items-center gap-2 rounded-full bg-mist-950/5 p-1 dark:bg-white/10"
            aria-label="Culture type"
          >
            <span class="rounded-full bg-white px-3 py-2 text-base text-mist-950 shadow-sm ring-1 ring-black/5 sm:py-1.5 sm:text-sm dark:bg-mist-800 dark:text-white dark:ring-white/10">
              Films
            </span>
          </div>
        </div>

        <%= case @state.status do %>
          <% :ready -> %>
            <ul
              id="culture-results"
              role="list"
              class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3"
            >
              <li
                :for={item <- @state.items}
                id={"culture-result-#{item.external_namespace}-#{item.external_id}"}
              >
                <.film_card item={item} term={@state.term} relevance={@state.relevance} />
              </li>
            </ul>

            <button
              :if={@state[:next_cursor]}
              id="culture-show-more"
              type="button"
              phx-click="discovery_more"
              class="relative w-fit rounded-full bg-mist-950 px-3 py-2 text-sm font-medium text-white hover:bg-mist-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 disabled:cursor-wait disabled:opacity-60 dark:bg-white dark:text-mist-950 dark:hover:bg-mist-200"
              disabled={@state[:loading_more] == true}
            >
              <span
                class="absolute top-1/2 left-1/2 size-[max(100%,3rem)] -translate-1/2 pointer-fine:hidden"
                aria-hidden="true"
              />
              {if @state[:loading_more], do: "Loading…", else: "Show more"}
            </button>
          <% :empty -> %>
            <div
              id="culture-empty"
              class="rounded-xl bg-mist-950/5 p-5 ring-1 ring-black/5 dark:bg-white/5 dark:ring-white/10"
            >
              <p class="text-base text-pretty text-mist-700 sm:text-sm dark:text-mist-200">
                <%= if @state[:empty_reason] == :no_exact_keyword do %>
                  No exact film keyword matches this term yet.
                <% else %>
                  No film matches for this meaning yet.
                <% end %>
              </p>
            </div>
          <% :failed -> %>
            <div
              id="culture-failed"
              role="status"
              class="rounded-xl bg-mist-950/5 p-5 ring-1 ring-black/5 dark:bg-white/5 dark:ring-white/10"
            >
              <p class="text-base text-pretty text-mist-700 sm:text-sm dark:text-mist-200">
                Film discovery is temporarily unavailable. The definitions above are unaffected.
              </p>
            </div>
          <% :deferred -> %>
            <div id="culture-deferred" role="status" class="flex items-center gap-3 py-4">
              <.icon name="hero-clock" class="size-5 text-mist-500 sm:size-4" />
              <p class="text-base text-mist-600 sm:text-sm dark:text-mist-300">
                Film discovery is waiting for provider capacity.
              </p>
            </div>
          <% _loading_or_idle -> %>
            <div id="culture-loading" role="status" aria-live="polite" class="flex flex-col gap-4">
              <div class="flex items-center gap-3">
                <.icon
                  name="hero-arrow-path"
                  class="size-5 motion-safe:animate-spin text-mist-500 sm:size-4"
                />
                <p class="text-base text-mist-600 sm:text-sm dark:text-mist-300">
                  Looking for film matches…
                </p>
              </div>
              <div class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3" aria-hidden="true">
                <div
                  :for={id <- 1..3}
                  id={"culture-skeleton-#{id}"}
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
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :term, :string, required: true
  attr :relevance, :string, required: true

  defp film_card(assigns) do
    assigns =
      assigns
      |> assign(:preview, assigns.item.preview_metadata)
      |> assign(:matches, assigns.item.match_details)

    ~H"""
    <article class="h-full overflow-hidden rounded-xl bg-white shadow-sm ring-1 ring-black/5 dark:bg-mist-900 dark:ring-white/10">
      <%= if @preview["poster_url"] do %>
        <img
          src={@preview["poster_url"]}
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
            <.icon name="hero-film" class="size-8" />
            <p class="font-mono text-sm tracking-wide uppercase">Film</p>
          </div>
        </div>
      <% end %>

      <div class="flex flex-col gap-4 p-5">
        <div class="flex flex-col gap-1">
          <p class="font-mono text-sm tracking-wide text-mist-500 uppercase">Film</p>
          <h3 class="text-xl font-medium text-balance text-mist-950 dark:text-white">
            {@preview["title"]}<span :if={@preview["year"]} class="font-normal text-mist-500"> · {@preview[
              "year"
            ]}</span>
          </h3>
        </div>

        <p class="text-base text-pretty text-mist-700 sm:text-sm dark:text-mist-200">
          <%= if keyword_names(@matches) == [] do %>
            Search results for “{@term}”
          <% else %>
            Found through {keyword_label(keyword_names(@matches))}: “{Enum.join(
              keyword_names(@matches),
              "”, “"
            )}”
          <% end %>
        </p>

        <p
          :if={@relevance == "term_unverified"}
          class="text-base text-pretty text-mist-600 sm:text-sm dark:text-mist-300"
        >
          Keyword relevance to this particular meaning is unverified.
        </p>

        <p class="text-base text-mist-500 sm:text-sm">
          CineGraph · keywords: TMDb
        </p>

        <details class="group border-t border-mist-950/10 pt-4 dark:border-white/10">
          <summary class="relative flex cursor-pointer list-none items-center justify-between gap-3 text-base font-medium text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 sm:text-sm dark:text-white">
            Details <.icon name="hero-chevron-down" class="size-5 group-open:rotate-180 sm:size-4" />
            <span
              class="absolute top-1/2 left-1/2 size-[max(100%,3rem)] -translate-1/2 pointer-fine:hidden"
              aria-hidden="true"
            />
          </summary>
          <div class="flex flex-col gap-3 pt-4">
            <div class="flex flex-col gap-1">
              <h4 class="text-base font-medium text-mist-950 sm:text-sm dark:text-white">
                Why this appeared
              </h4>
              <p class="text-base text-pretty text-mist-600 sm:text-sm dark:text-mist-300">
                <%= if keyword_names(@matches) == [] do %>
                  Search results for “{@term}”. The provider supplied no tag match.
                <% else %>
                  Matched {keyword_label(keyword_names(@matches))} “{Enum.join(
                    keyword_names(@matches),
                    "”, “"
                  )}” for this selected term.
                <% end %>
              </p>
            </div>

            <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-base sm:text-sm">
              <dt class="text-mist-500">Source</dt>
              <dd class="text-mist-800 dark:text-mist-100">CineGraph</dd>
              <dt class="text-mist-500">Keyword source</dt>
              <dd class="text-mist-800 dark:text-mist-100">TMDb</dd>
            </dl>

            <a
              :if={@preview["source_url"]}
              id={"culture-source-#{@item.external_id}"}
              href={@preview["source_url"]}
              target="_blank"
              rel="noreferrer"
              class="relative flex w-fit items-center gap-2 rounded-md py-2 pr-2 pl-0 text-base font-medium text-mist-950 underline decoration-mist-300 underline-offset-4 hover:decoration-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 sm:text-sm dark:text-white dark:decoration-mist-600 dark:hover:decoration-white"
            >
              View film at source <.icon name="hero-arrow-up-right" class="size-5 sm:size-4" />
              <span
                class="absolute top-1/2 left-1/2 size-[max(100%,3rem)] -translate-1/2 pointer-fine:hidden"
                aria-hidden="true"
              />
            </a>
          </div>
        </details>
      </div>
    </article>
    """
  end

  defp keyword_names(match_details) do
    match_details
    |> Map.get("keywords", [])
    |> Enum.map(& &1["name"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp keyword_label([_one]), do: "the keyword"
  defp keyword_label(_many), do: "keywords"
end
