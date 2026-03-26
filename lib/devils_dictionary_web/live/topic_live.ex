defmodule DevilsDictionaryWeb.TopicLive do
  @moduledoc """
  LiveView for displaying a topic page with definitions organized by tier.

  The topic page is the heart of the Devil's Dictionary - it displays
  definitions from all three tiers in hierarchical order:
  1. Aristocracy (dead intellectuals) - gilded and elevated
  2. Middle Class (institutional) - clean and professional
  3. Plebs (crowdsourced) - social media aesthetic
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Dictionary

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Dictionary.get_topic_with_definitions(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Topic not found")
         |> push_navigate(to: ~p"/")}

      topic ->
        {:ok,
         socket
         |> assign(:page_title, topic.title)
         |> assign(:topic, topic)
         |> assign(:definitions, topic.definitions)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="topic-page min-h-screen bg-stone-50">
      <.topic_header topic={@topic} />

      <main class="max-w-4xl mx-auto px-4 py-8">
        <.definitions_by_tier definitions={@definitions} />

        <.empty_state :if={@definitions == []} />

        <aside class="mt-12">
          <.related_topics topic={@topic} />
        </aside>
      </main>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # PRIVATE COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  defp empty_state(assigns) do
    ~H"""
    <div class="text-center py-16">
      <div class="text-6xl mb-4">📖</div>
      <h2 class="text-xl font-semibold text-gray-600 mb-2">
        No definitions yet
      </h2>
      <p class="text-gray-500 max-w-md mx-auto">
        This term awaits its cynical interpretation.
        Perhaps you'd like to contribute one?
      </p>
    </div>
    """
  end

  defp related_topics(assigns) do
    # For now, show placeholder - will implement relationships later
    relationships = Dictionary.get_topic_relationships(assigns.topic.id)
    assigns = assign(assigns, :relationships, relationships)

    ~H"""
    <div :if={@relationships != []} class="border-t border-gray-200 pt-8">
      <h3 class="text-lg font-semibold text-gray-700 mb-4">See Also</h3>
      <div class="flex flex-wrap gap-2">
        <.link
          :for={rel <- @relationships}
          navigate={~p"/define/#{rel.related_topic.slug}"}
          class="px-3 py-1 bg-stone-100 hover:bg-stone-200 rounded-full text-sm text-stone-700 transition-colors"
        >
          {rel.related_topic.title}
        </.link>
      </div>
    </div>
    """
  end
end
