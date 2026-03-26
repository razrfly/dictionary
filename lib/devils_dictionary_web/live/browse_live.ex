defmodule DevilsDictionaryWeb.BrowseLive do
  @moduledoc """
  LiveView for browsing all dictionary topics alphabetically.

  Displays an A-Z index allowing users to jump to topics starting
  with a specific letter, with completeness indicators showing
  which tiers have definitions for each topic.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Dictionary

  @letters_list Enum.map(?A..?Z, &<<&1>>)

  @impl true
  def mount(params, _session, socket) do
    letter = Map.get(params, "letter", "A") |> String.upcase() |> String.first()
    letter = if letter in @letters_list, do: letter, else: "A"

    {:ok,
     socket
     |> assign(:page_title, "Browse A-Z")
     |> assign(:current_letter, letter)
     |> assign(:topics, list_topics_by_letter(letter))
     |> assign(:letters, build_letter_index())}
  end

  @impl true
  def handle_params(%{"letter" => letter}, _uri, socket) do
    letter = String.upcase(letter) |> String.first()
    letter = if letter in @letters_list, do: letter, else: "A"

    {:noreply,
     socket
     |> assign(:current_letter, letter)
     |> assign(:topics, list_topics_by_letter(letter))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="browse-page min-h-screen bg-stone-50">
      <header class="bg-white border-b border-stone-200">
        <div class="max-w-6xl mx-auto px-4 py-6">
          <h1 class="font-aristocracy text-3xl font-bold text-stone-900">
            Browse the Dictionary
          </h1>
          <p class="text-stone-600 mt-1">
            An alphabetical index of cynical definitions
          </p>
        </div>
      </header>

      <nav class="bg-white border-b border-stone-200 sticky top-0 z-10">
        <div class="max-w-6xl mx-auto px-4">
          <.letter_index letters={@letters} current={@current_letter} />
        </div>
      </nav>

      <main class="max-w-6xl mx-auto px-4 py-8">
        <.topic_list topics={@topics} letter={@current_letter} />
      </main>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  attr :letters, :list, required: true
  attr :current, :string, required: true

  defp letter_index(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 py-3">
      <.link
        :for={{letter, count} <- @letters}
        patch={~p"/browse/#{String.downcase(letter)}"}
        class={[
          "w-9 h-9 flex items-center justify-center rounded text-sm font-medium transition-colors",
          letter == @current && "bg-amber-600 text-white",
          letter != @current && count > 0 && "bg-stone-100 text-stone-700 hover:bg-stone-200",
          letter != @current && count == 0 && "bg-stone-50 text-stone-300 cursor-not-allowed"
        ]}
      >
        {letter}
      </.link>
    </div>
    """
  end

  attr :topics, :list, required: true
  attr :letter, :string, required: true

  defp topic_list(assigns) do
    ~H"""
    <div>
      <h2 class="text-2xl font-aristocracy font-bold text-stone-900 mb-6 border-b-2 border-amber-600 pb-2 inline-block">
        {@letter}
      </h2>

      <div :if={@topics == []} class="text-center py-12">
        <p class="text-stone-500">No terms starting with "{@letter}" yet.</p>
      </div>

      <ul :if={@topics != []} class="space-y-2">
        <li :for={topic <- @topics}>
          <.link
            navigate={~p"/define/#{topic.slug}"}
            class="block p-4 bg-white rounded-lg border border-stone-200 hover:border-amber-400 hover:shadow-sm transition-all group"
          >
            <div class="flex items-center justify-between">
              <div>
                <span class="font-medium text-stone-900 group-hover:text-amber-700">
                  {topic.title}
                </span>
                <span :if={topic.part_of_speech} class="text-stone-400 italic ml-2">
                  {topic.part_of_speech}
                </span>
              </div>
              <div class="flex items-center gap-3">
                <.mini_completeness topic={topic} />
                <span class="text-stone-400 group-hover:text-amber-600">
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
                  </svg>
                </span>
              </div>
            </div>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # Mini version of completeness indicator for list items
  defp mini_completeness(assigns) do
    ~H"""
    <div class="flex gap-0.5" title={"#{@topic.definition_count} definition(s)"}>
      <div class={[
        "w-2 h-2 rounded-full",
        @topic.definition_count > 0 && "bg-amber-500" || "bg-stone-200"
      ]}>
      </div>
      <div class={[
        "w-2 h-2 rounded-full",
        @topic.definition_count > 1 && "bg-slate-500" || "bg-stone-200"
      ]}>
      </div>
      <div class={[
        "w-2 h-2 rounded-full",
        @topic.definition_count > 2 && "bg-indigo-500" || "bg-stone-200"
      ]}>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # DATA HELPERS
  # ═══════════════════════════════════════════════════════════════════════

  defp list_topics_by_letter(letter) do
    # Get all topics and filter by first letter
    Dictionary.list_topics()
    |> Enum.filter(fn topic ->
      String.upcase(String.first(topic.title)) == letter
    end)
    |> Enum.sort_by(& &1.title)
  end

  defp build_letter_index do
    # Count topics per letter
    topics = Dictionary.list_topics()

    counts =
      topics
      |> Enum.group_by(fn topic -> String.upcase(String.first(topic.title)) end)
      |> Enum.map(fn {letter, topics} -> {letter, length(topics)} end)
      |> Map.new()

    # Build full A-Z list with counts
    ?A..?Z
    |> Enum.map(fn char ->
      letter = <<char>>
      {letter, Map.get(counts, letter, 0)}
    end)
  end
end
