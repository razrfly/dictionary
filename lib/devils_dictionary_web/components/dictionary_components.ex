defmodule DevilsDictionaryWeb.DictionaryComponents do
  @moduledoc """
  Dictionary-specific UI components for the Devil's Dictionary.

  This module provides the visual hierarchy through tier-specific definition cards:
  - Aristocracy: Gilded frames, serif fonts, aged paper aesthetic
  - Middle Class: Clean institutional styling, professional appearance
  - Plebs: Social media aesthetic, casual and modern

  The visual treatment IS the argument - each tier's styling reinforces
  the hierarchical worldview of the dictionary.
  """

  use Phoenix.Component

  alias DevilsDictionary.Dictionary.Definition

  # ═══════════════════════════════════════════════════════════════════════
  # DEFINITION CARDS
  # ═══════════════════════════════════════════════════════════════════════

  @doc """
  Renders a definition card with tier-appropriate styling.

  Automatically dispatches to the correct tier-specific component based on
  the definition's tier attribute.

  ## Examples

      <.definition_card definition={@definition} />
  """
  attr :definition, Definition, required: true
  attr :show_topic, :boolean, default: false

  def definition_card(%{definition: %{tier: :aristocracy}} = assigns) do
    ~H"""
    <.aristocracy_definition_card definition={@definition} show_topic={@show_topic} />
    """
  end

  def definition_card(%{definition: %{tier: :middle}} = assigns) do
    ~H"""
    <.middle_definition_card definition={@definition} show_topic={@show_topic} />
    """
  end

  def definition_card(%{definition: %{tier: :plebs}} = assigns) do
    ~H"""
    <.plebs_definition_card definition={@definition} show_topic={@show_topic} />
    """
  end

  @doc """
  Renders an aristocratic definition card with gilded frames and serif typography.

  The aristocracy tier represents dead intellectuals - their words preserved
  in ornate frames befitting their eternal wisdom.
  """
  attr :definition, Definition, required: true
  attr :show_topic, :boolean, default: false

  def aristocracy_definition_card(assigns) do
    ~H"""
    <article class="definition-aristocracy tier-aristocracy-frame">
      <div class="definition-content">
        "{@definition.content}"
      </div>

      <footer class="mt-4">
        <div :if={@definition.author} class="definition-attribution">
          — {@definition.author.name}
        </div>
        <div class="definition-source">
          <span :if={@definition.source_name}>{@definition.source_name}</span>
          <span :if={@definition.source_year}>({@definition.source_year})</span>
        </div>
      </footer>

      <.tier_badge tier={:aristocracy} />
    </article>
    """
  end

  @doc """
  Renders a middle-class definition card with clean, institutional styling.

  The middle class tier represents institutional sources - dictionaries,
  encyclopedias, and academic references that aspire to authority.
  """
  attr :definition, Definition, required: true
  attr :show_topic, :boolean, default: false

  def middle_definition_card(assigns) do
    ~H"""
    <article class="definition-middle">
      <div class="definition-content">
        {@definition.content}
      </div>

      <footer class="mt-3 flex items-center justify-between">
        <div class="definition-attribution">
          <span :if={@definition.source_name} class="font-medium">
            {@definition.source_name}
          </span>
          <span :if={@definition.source_year} class="text-sm text-gray-500 ml-2">
            ({@definition.source_year})
          </span>
        </div>

        <.tier_badge tier={:middle} />
      </footer>
    </article>
    """
  end

  @doc """
  Renders a plebeian definition card with social media aesthetic.

  The plebs tier represents crowdsourced definitions - Urban Dictionary,
  social media, and user submissions. Democratic chaos.
  """
  attr :definition, Definition, required: true
  attr :show_topic, :boolean, default: false

  def plebs_definition_card(assigns) do
    ~H"""
    <article class="definition-plebs">
      <header class="definition-source-badge">
        <.source_icon source={@definition.source_name} />
        <span>{@definition.source_name || "Anonymous"}</span>
        <span :if={@definition.source_year} class="text-gray-400">
          · {@definition.source_year}
        </span>
      </header>

      <div class="definition-content">
        {@definition.content}
      </div>

      <footer class="definition-votes">
        <span class="flex items-center gap-1">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 10h4.764a2 2 0 011.789 2.894l-3.5 7A2 2 0 0115.263 21h-4.017c-.163 0-.326-.02-.485-.06L7 20m7-10V5a2 2 0 00-2-2h-.095c-.5 0-.905.405-.905.905 0 .714-.211 1.412-.608 2.006L7 11v9m7-10h-2M7 20H5a2 2 0 01-2-2v-6a2 2 0 012-2h2.5" />
          </svg>
          <span>—</span>
        </span>
        <span class="flex items-center gap-1">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14H5.236a2 2 0 01-1.789-2.894l3.5-7A2 2 0 018.736 3h4.018a2 2 0 01.485.06l3.76.94m-7 10v5a2 2 0 002 2h.096c.5 0 .905-.405.905-.904 0-.715.211-1.413.608-2.008L17 13V4m-7 10h2m5-10h2a2 2 0 012 2v6a2 2 0 01-2 2h-2.5" />
          </svg>
          <span>—</span>
        </span>
        <.tier_badge tier={:plebs} />
      </footer>
    </article>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # TIER SECTION COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  @doc """
  Renders a tier section header with appropriate styling.

  ## Examples

      <.tier_section_header tier={:aristocracy} />
  """
  attr :tier, :atom, required: true, values: [:aristocracy, :middle, :plebs]
  attr :count, :integer, default: nil

  def tier_section_header(assigns) do
    assigns = assign(assigns, :tier_info, tier_info(assigns.tier))

    ~H"""
    <header class={"tier-section-header #{@tier}"}>
      <span class="text-2xl">{@tier_info.emoji}</span>
      <h2 class="text-xl font-semibold">{@tier_info.name}</h2>
      <span :if={@count} class="text-sm opacity-60">({@count})</span>
    </header>
    """
  end

  @doc """
  Renders a small tier badge.

  ## Examples

      <.tier_badge tier={:aristocracy} />
  """
  attr :tier, :atom, required: true, values: [:aristocracy, :middle, :plebs]

  def tier_badge(assigns) do
    assigns = assign(assigns, :tier_info, tier_info(assigns.tier))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs",
      tier_badge_class(@tier)
    ]}>
      <span>{@tier_info.emoji}</span>
      <span class="hidden sm:inline">{@tier_info.label}</span>
    </span>
    """
  end

  defp tier_badge_class(:aristocracy), do: "bg-amber-100 text-amber-800 border border-amber-300"
  defp tier_badge_class(:middle), do: "bg-slate-100 text-slate-700 border border-slate-200"
  defp tier_badge_class(:plebs), do: "bg-indigo-100 text-indigo-700"

  # ═══════════════════════════════════════════════════════════════════════
  # DEFINITION LIST COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  @doc """
  Renders a grouped list of definitions organized by tier.

  Displays definitions in hierarchical order: Aristocracy → Middle → Plebs

  ## Examples

      <.definitions_by_tier definitions={@definitions} />
  """
  attr :definitions, :list, required: true

  def definitions_by_tier(assigns) do
    grouped = Enum.group_by(assigns.definitions, & &1.tier)

    assigns =
      assigns
      |> assign(:aristocracy_defs, Map.get(grouped, :aristocracy, []))
      |> assign(:middle_defs, Map.get(grouped, :middle, []))
      |> assign(:plebs_defs, Map.get(grouped, :plebs, []))

    ~H"""
    <div class="definitions-container space-y-8">
      <%!-- Aristocracy Section --%>
      <section :if={@aristocracy_defs != []} class="tier-section aristocracy">
        <.tier_section_header tier={:aristocracy} count={length(@aristocracy_defs)} />
        <div class="space-y-6">
          <.definition_card :for={def <- @aristocracy_defs} definition={def} />
        </div>
      </section>

      <%!-- Middle Class Section --%>
      <section :if={@middle_defs != []} class="tier-section middle">
        <.tier_section_header tier={:middle} count={length(@middle_defs)} />
        <div class="space-y-4">
          <.definition_card :for={def <- @middle_defs} definition={def} />
        </div>
      </section>

      <%!-- Plebs Section --%>
      <section :if={@plebs_defs != []} class="tier-section plebs">
        <.tier_section_header tier={:plebs} count={length(@plebs_defs)} />
        <div class="space-y-3">
          <.definition_card :for={def <- @plebs_defs} definition={def} />
        </div>
      </section>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # TOPIC COMPONENTS
  # ═══════════════════════════════════════════════════════════════════════

  @doc """
  Renders the topic header with title, pronunciation, and part of speech.
  """
  attr :topic, :map, required: true

  def topic_header(assigns) do
    ~H"""
    <header class="topic-header">
      <h1 class="topic-title">{@topic.title}</h1>
      <div class="flex items-center gap-4 mt-2">
        <span :if={@topic.pronunciation} class="topic-pronunciation">
          {@topic.pronunciation}
        </span>
        <span :if={@topic.part_of_speech} class="topic-part-of-speech">
          {@topic.part_of_speech}
        </span>
      </div>
      <.completeness_indicator topic={@topic} />
    </header>
    """
  end

  @doc """
  Renders a completeness indicator showing which tiers have definitions.
  """
  attr :topic, :map, required: true

  def completeness_indicator(assigns) do
    # Check which tiers have definitions (if definitions are preloaded)
    definitions = Map.get(assigns.topic, :definitions, [])

    tiers_present =
      definitions
      |> Enum.map(& &1.tier)
      |> Enum.uniq()
      |> MapSet.new()

    assigns =
      assigns
      |> assign(:has_aristocracy, MapSet.member?(tiers_present, :aristocracy))
      |> assign(:has_middle, MapSet.member?(tiers_present, :middle))
      |> assign(:has_plebs, MapSet.member?(tiers_present, :plebs))

    ~H"""
    <div class="completeness-bar" title="Definition completeness by tier">
      <div class={["segment", @has_aristocracy && "filled"]} title="Aristocracy"></div>
      <div class={["segment", @has_middle && "filled"]} title="Middle Class"></div>
      <div class={["segment", @has_plebs && "filled"]} title="Plebs"></div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════
  # HELPER FUNCTIONS
  # ═══════════════════════════════════════════════════════════════════════

  defp tier_info(:aristocracy) do
    %{
      emoji: "👑",
      name: "Aristocracy of the Dead",
      label: "Aristocracy",
      description: "The immortal wisdom of dead intellectuals"
    }
  end

  defp tier_info(:middle) do
    %{
      emoji: "📚",
      name: "The Middle Class",
      label: "Middle",
      description: "Institutional definitions that aspire to authority"
    }
  end

  defp tier_info(:plebs) do
    %{
      emoji: "📱",
      name: "The Plebs",
      label: "Plebs",
      description: "Democratic chaos from the masses"
    }
  end

  # Source icons for plebs tier
  defp source_icon(%{source: "Urban Dictionary"} = assigns) do
    ~H"""
    <span class="text-yellow-500">📖</span>
    """
  end

  defp source_icon(%{source: "Twitter"} = assigns) do
    ~H"""
    <span class="text-blue-400">𝕏</span>
    """
  end

  defp source_icon(%{source: "Reddit"} = assigns) do
    ~H"""
    <span class="text-orange-500">🔴</span>
    """
  end

  defp source_icon(%{source: "TikTok"} = assigns) do
    ~H"""
    <span>🎵</span>
    """
  end

  defp source_icon(assigns) do
    ~H"""
    <span class="text-gray-400">💬</span>
    """
  end
end
