defmodule DevilsDictionaryWeb.Demo do
  @moduledoc """
  The furniture fake-data mode needs and nothing else (#71 §5 W6, U3).

  The sample **cards** are not here: they render through
  `DevilsDictionaryWeb.Word.source_card/1`, which is the point — a layout
  argument about Webster 1913 is worth having only if Webster 1913 is drawn by
  the same component as Bierce. What is here is the labelling that keeps the
  fiction visible (`demo_banner/1`, `sample_badge/1`) and the one layer that
  has no component of its own yet, the evidence wall of #67.

  The wall's filter chips are drawn and inert. This is a sample of a layout,
  not a preview of a feature; a chip that filtered nothing real would be a lie
  told twice.
  """

  use DevilsDictionaryWeb, :html

  @doc "The banner that says the page is partly invented. Top of the page, impossible to miss."
  def demo_banner(assigns) do
    ~H"""
    <div
      id="demo-banner"
      class="mb-8 rounded-xl border border-dashed border-amber-600/60 bg-amber-50 px-4 py-3 text-sm/6 text-amber-950 dark:bg-amber-950/20 dark:text-amber-100"
    >
      <p>
        <span class="font-medium">SAMPLE DATA is on.</span>
        Cards and tiles marked <span class="font-medium">SAMPLE</span>
        are invented for layout — Webster 1913, EB1911, Urban Dictionary and the culture layer are
        not absorbed yet. Everything unmarked on this page is real. Drop
        <code class="font-mono">?demo=1</code>
        from the URL to see the page as it ships.
      </p>
    </div>
    """
  end

  @doc "The badge a sample card wears in its own header."
  def sample_badge(assigns) do
    ~H"""
    <span class="rounded-full border border-dashed border-amber-600/60 px-2 py-0.5 text-xs/5 font-medium tracking-wide text-amber-800 uppercase dark:text-amber-200">
      Sample — not real data
    </span>
    """
  end

  @doc """
  The evidence wall (#67): one masonry of mixed media, the culture talking back
  to the dictionary. Everything in it is invented; the tables behind it were
  written, applied, diffed and rolled back in S5 and are in `docs/sketches/`.
  """
  attr :evidence, :list, default: []

  def evidence_wall(assigns) do
    ~H"""
    <section
      :if={@evidence != []}
      id="demo-evidence"
      class="mt-10 border-t border-dashed border-amber-600/40 pt-8"
    >
      <header class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-2">
        <h2 class="text-base/8 font-medium text-mist-950 dark:text-white">
          <span aria-hidden="true" class="mr-1">🔥</span> Evidence from the culture
        </h2>
        <.sample_badge />
      </header>

      <p class="mt-1 text-sm/7 text-mist-500">
        The wall stays put while the definitions argue. Filters are drawn, not wired.
      </p>

      <div id="demo-evidence-filters" class="mt-4 flex flex-wrap gap-2" aria-hidden="true">
        <span
          :for={{label, i} <- Enum.with_index(filters(@evidence))}
          class={[
            "rounded-full px-3 py-0.5 text-sm/6",
            i == 0 && "bg-mist-950/10 font-medium text-mist-950 dark:bg-white/15 dark:text-white",
            i > 0 && "bg-mist-950/2.5 text-mist-500 dark:bg-white/5"
          ]}
        >
          <span aria-hidden="true" class="mr-1">{elem(label, 0)}</span>{elem(label, 1)}
        </span>
      </div>

      <%!-- CSS columns rather than a grid: the tiles are different heights on
      purpose (the variety is the argument), and columns reflow to one at
      375 px without a breakpoint per tile. --%>
      <div id="demo-evidence-wall" class="mt-4 gap-4 sm:columns-2 lg:columns-3">
        <.evidence_card
          :for={{tile, i} <- Enum.with_index(@evidence)}
          id={"demo-tile-#{i}"}
          tile={tile}
        />
        <div class="mb-4 flex break-inside-avoid flex-col justify-center rounded-xl border border-dashed border-mist-950/25 p-4 text-sm/6 text-mist-500 dark:border-white/20">
          <span class="text-lg/7" aria-hidden="true">＋</span> Caught one in the wild? Paste a link →
        </div>
      </div>
    </section>
    """
  end

  @doc "One tile. The pill telegraphs the type; the metric is the one its source would show."
  attr :id, :string, required: true
  attr :tile, :map, required: true

  def evidence_card(assigns) do
    ~H"""
    <figure
      id={@id}
      class="mb-4 break-inside-avoid rounded-xl border border-dashed border-mist-950/20 p-4 dark:border-white/15"
    >
      <p class="flex flex-wrap items-baseline gap-x-2 text-xs/5 tracking-wide text-mist-500 uppercase">
        <span aria-hidden="true">{glyph(@tile.kind)}</span>
        <span>{@tile.label}</span>
        <span :if={@tile.duration}>· {@tile.duration}</span>
      </p>

      <blockquote class={[
        "mt-2 text-sm/6 text-mist-950 dark:text-white",
        @tile.kind == "lyric" && "font-display text-lg/7 italic"
      ]}>
        {@tile.body}
      </blockquote>

      <figcaption class="mt-2 flex flex-wrap items-baseline justify-between gap-x-3 text-sm/6 text-mist-500">
        <span>
          <span :if={@tile.meta} class="mr-2">{@tile.meta}</span>
          <span>{@tile.handle}</span>
        </span>
        <span class="text-mist-700 dark:text-mist-400">{@tile.metric}</span>
      </figcaption>
    </figure>
    """
  end

  defp filters(evidence) do
    [{"◆", "All"}] ++ (evidence |> Enum.map(&pretty(&1.kind)) |> Enum.uniq())
  end

  defp pretty("tiktok"), do: {"🎬", "TikTok"}
  defp pretty("youtube"), do: {"📺", "YouTube"}
  defp pretty("lyric"), do: {"🎵", "Lyrics"}
  defp pretty("instagram"), do: {"📸", "Instagram"}
  defp pretty("tweet"), do: {"🐦", "Tweets"}
  defp pretty("example"), do: {"🧷", "Examples"}
  defp pretty(other), do: {"•", other}

  defp glyph("tiktok"), do: "🎬"
  defp glyph("youtube"), do: "📺"
  defp glyph("lyric"), do: "🎵"
  defp glyph("instagram"), do: "📸"
  defp glyph("tweet"), do: "🐦"
  defp glyph("example"), do: "🧷"
  defp glyph(_other), do: "•"
end
