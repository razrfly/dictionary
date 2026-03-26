defmodule DevilsDictionaryWeb.HomeLive do
  @moduledoc """
  Home page LiveView with search functionality.

  The landing page for the Devil's Dictionary featuring:
  - Search box with live autocomplete
  - Featured/random definitions from the aristocracy
  - Quick navigation to browse A-Z
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Dictionary

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "The Devil's Dictionary")
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:featured_definitions, get_featured_definitions())
     |> assign(:topic_count, length(Dictionary.list_topics()))}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    results = if String.length(query) >= 2, do: Dictionary.search_topics(query, 8), else: []

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="home-page min-h-screen bg-gradient-to-b from-stone-100 to-stone-50">
      <%!-- Hero Section --%>
      <header class="relative overflow-hidden">
        <div class="max-w-4xl mx-auto px-4 py-16 text-center">
          <h1 class="font-aristocracy text-5xl md:text-6xl font-bold text-stone-900 mb-4">
            The Devil's Dictionary
          </h1>
          <p class="text-xl text-stone-600 mb-2 font-aristocracy italic">
            A cynical compendium of human folly
          </p>
          <p class="text-stone-500 text-sm">
            {@topic_count} terms defined across three tiers of authority
          </p>
        </div>
      </header>

      <%!-- Search Section --%>
      <section class="max-w-2xl mx-auto px-4 -mt-4 relative z-10">
        <div class="bg-white rounded-xl shadow-lg border border-stone-200 p-1">
          <form phx-change="search" phx-submit="search" class="relative">
            <div class="flex items-center">
              <svg class="w-5 h-5 text-stone-400 ml-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search for a term..."
                autocomplete="off"
                class="flex-1 px-4 py-4 text-lg border-none focus:ring-0 focus:outline-none placeholder-stone-400"
                phx-debounce="150"
              />
              <button
                :if={@search_query != ""}
                type="button"
                phx-click="clear_search"
                class="p-2 mr-2 text-stone-400 hover:text-stone-600"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
          </form>

          <%!-- Search Results Dropdown --%>
          <div :if={@search_results != []} class="border-t border-stone-100">
            <ul class="py-2">
              <li :for={topic <- @search_results}>
                <.link
                  navigate={~p"/define/#{topic.slug}"}
                  class="flex items-center justify-between px-4 py-3 hover:bg-stone-50 transition-colors"
                >
                  <div>
                    <span class="font-medium text-stone-900">{topic.title}</span>
                    <span :if={topic.part_of_speech} class="text-stone-400 italic ml-2 text-sm">
                      {topic.part_of_speech}
                    </span>
                  </div>
                  <span class="text-xs text-stone-400">
                    {topic.definition_count} def.
                  </span>
                </.link>
              </li>
            </ul>
          </div>

          <div :if={@search_query != "" && @search_results == [] && String.length(@search_query) >= 2} class="border-t border-stone-100 px-4 py-4 text-center text-stone-500">
            No terms found for "{@search_query}"
          </div>
        </div>
      </section>

      <%!-- Quick Links --%>
      <section class="max-w-4xl mx-auto px-4 py-8">
        <div class="flex flex-wrap justify-center gap-4">
          <.link
            navigate={~p"/browse"}
            class="inline-flex items-center gap-2 px-6 py-3 bg-white border border-stone-200 rounded-lg hover:border-amber-400 hover:shadow-sm transition-all text-stone-700"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 10h16M4 14h16M4 18h16" />
            </svg>
            Browse A-Z
          </.link>
        </div>
      </section>

      <%!-- Featured Definitions --%>
      <section class="max-w-4xl mx-auto px-4 py-8">
        <h2 class="font-aristocracy text-2xl font-bold text-stone-900 mb-6 text-center">
          From the Aristocracy of the Dead
        </h2>

        <div class="grid gap-6 md:grid-cols-2">
          <.featured_card :for={def <- @featured_definitions} definition={def} />
        </div>
      </section>

      <%!-- Tier Explanation --%>
      <section class="max-w-4xl mx-auto px-4 py-12">
        <h2 class="font-aristocracy text-xl font-bold text-stone-900 mb-6 text-center">
          The Three Estates
        </h2>

        <div class="grid gap-4 md:grid-cols-3">
          <.tier_card
            emoji="👑"
            title="Aristocracy"
            description="The immortal wisdom of dead intellectuals: Bierce, Wilde, Twain, and their ilk."
            class="tier-aristocracy-frame"
          />
          <.tier_card
            emoji="📚"
            title="Middle Class"
            description="Institutional definitions from dictionaries that aspire to authority."
            class="tier-middle"
          />
          <.tier_card
            emoji="📱"
            title="The Plebs"
            description="Democratic chaos from Urban Dictionary and social media."
            class="tier-plebs-card"
          />
        </div>
      </section>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  attr :definition, :map, required: true

  defp featured_card(assigns) do
    ~H"""
    <.link navigate={~p"/define/#{@definition.topic.slug}"} class="block">
      <article class="tier-aristocracy-frame h-full hover:shadow-lg transition-shadow cursor-pointer">
        <div class="text-xs text-amber-700 uppercase tracking-wide mb-2">
          {@definition.topic.title}
        </div>
        <blockquote class="font-aristocracy text-lg italic text-stone-800 mb-4">
          "{@definition.content}"
        </blockquote>
        <footer class="text-sm text-stone-600">
          <span :if={@definition.author}>— {@definition.author.name}</span>
          <span :if={@definition.source_name} class="text-stone-400 ml-1">
            ({@definition.source_name})
          </span>
        </footer>
      </article>
    </.link>
    """
  end

  attr :emoji, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :class, :string, default: ""

  defp tier_card(assigns) do
    ~H"""
    <div class={["p-6 rounded-lg", @class]}>
      <div class="text-3xl mb-2">{@emoji}</div>
      <h3 class="font-semibold text-lg mb-2">{@title}</h3>
      <p class="text-sm opacity-80">{@description}</p>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # DATA HELPERS
  # ═══════════════════════════════════════════════════════════════════════

  defp get_featured_definitions do
    # Get a few aristocracy definitions to feature
    import Ecto.Query

    DevilsDictionary.Repo.all(
      from d in DevilsDictionary.Dictionary.Definition,
        where: d.tier == :aristocracy,
        preload: [:author, :topic],
        order_by: fragment("RANDOM()"),
        limit: 4
    )
  end
end
