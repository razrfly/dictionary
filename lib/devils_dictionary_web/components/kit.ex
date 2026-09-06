defmodule DevilsDictionaryWeb.Kit do
  @moduledoc """
  The Oatmeal theme, as HEEx function components.

  Ported by hand from the Tailwind Plus "Oatmeal" kit (mist palette, Instrument
  Serif + Inter), which sits git-ignored in `tmp/oatmeal-mist-instrument` and is
  never committed: its licence permits unlimited end products, including open
  source, and forbids redistributing the components separately from one. So the
  kit's React elements live here as our own components and its `@theme` tokens
  live in `assets/css/app.css` (#71 §3).

  Two deliberate departures from the kit:

    * the kit's mobile menu is built on `@tailwindplus/elements`, an npm package.
      This app has no npm step at all — Tailwind and esbuild are standalone
      binaries — so `navbar/1` uses a `<details>` disclosure instead. It needs no
      JavaScript, which also means it works in dead views, where
      `Phoenix.LiveView.JS` does not.

    * `clsx` is likewise absent, so classes merge through Phoenix's class-list
      idiom: `class={[~w(base classes), @class]}`.

  The three-tier visual treatment (#66) is a later layer on top of this; MVP-0
  commits only to the tint in `tier_class/1`.
  """
  use Phoenix.Component

  # ── elements ─────────────────────────────────────────────────────────────

  @doc "The page gutter. Every section's content sits inside one."
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def container(assigns) do
    ~H"""
    <div
      class={["mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `<main>` wrapper, isolated so sticky and z-index behave."
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def main(assigns) do
    ~H"""
    <main class={["isolate overflow-clip", @class]} {@rest}>
      {render_slot(@inner_block)}
    </main>
    """
  end

  @doc "A titled band of content."
  attr :eyebrow, :string, default: nil
  attr :headline, :string, default: nil
  attr :subheadline, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :cta
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={["py-16", @class]} {@rest}>
      <.container class="flex flex-col gap-10 sm:gap-16">
        <div :if={@headline} class="flex max-w-2xl flex-col gap-6">
          <div class="flex flex-col gap-2">
            <.eyebrow :if={@eyebrow}>{@eyebrow}</.eyebrow>
            <.subheading>{@headline}</.subheading>
          </div>
          <.text :if={@subheadline} class="text-pretty">{@subheadline}</.text>
          {render_slot(@cta)}
        </div>
        <div>{render_slot(@inner_block)}</div>
      </.container>
    </section>
    """
  end

  @doc "The small label above a heading."
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <div class={["text-sm/7 font-semibold text-mist-700 dark:text-mist-400", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The page's one `<h1>`, in Instrument Serif."
  attr :color, :string, default: "dark", values: ~w(dark light)
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def heading(assigns) do
    ~H"""
    <h1
      class={[
        "font-display text-5xl/12 tracking-tight text-balance sm:text-[5rem]/20",
        @color == "dark" && "text-mist-950 dark:text-white",
        @color == "light" && "text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </h1>
    """
  end

  @doc "A section heading."
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def subheading(assigns) do
    ~H"""
    <h2
      class={[
        "font-display text-[2rem]/10 tracking-tight text-pretty text-mist-950 sm:text-5xl/14 dark:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </h2>
    """
  end

  @doc "Body copy."
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def text(assigns) do
    ~H"""
    <div
      class={[
        @size == "md" && "text-base/7",
        @size == "lg" && "text-lg/8",
        "text-mist-700 dark:text-mist-400",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A block of rendered prose — headings, lists, links and emphasis styled from
  the outside. This is what a dead author's entry gets rendered into.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def document(assigns) do
    ~H"""
    <div
      class={[
        "space-y-4 text-sm/7 text-mist-700 dark:text-mist-400",
        "[&_a]:font-semibold [&_a]:text-mist-950 [&_a]:underline [&_a]:underline-offset-4 dark:[&_a]:text-white",
        "[&_h2]:text-base/8 [&_h2]:font-medium [&_h2]:text-mist-950 [&_h2]:not-first:mt-8 dark:[&_h2]:text-white",
        "[&_li]:pl-2 [&_ol]:list-decimal [&_ol]:pl-6",
        "[&_strong]:font-semibold [&_strong]:text-mist-950 dark:[&_strong]:text-white",
        "[&_ul]:list-[square] [&_ul]:pl-6 [&_ul]:marker:text-mist-400 dark:[&_ul]:marker:text-mist-600",
        "[&_blockquote]:border-l-2 [&_blockquote]:border-mist-300 [&_blockquote]:pl-4 [&_blockquote]:italic dark:[&_blockquote]:border-mist-700",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  An inline link in the kit's voice.

  Named `a/1` rather than `link/1` so it does not shadow `Phoenix.Component.link/1`,
  which it wraps — `navigate`, `patch` and `href` all pass straight through.
  """
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch replace method download target rel)
  slot :inner_block, required: true

  def a(assigns) do
    ~H"""
    <.link
      class={[
        "inline-flex items-center gap-2 text-sm/7 font-medium text-mist-950 hover:underline dark:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  A button. The kit ships six exports — solid, soft and plain, each as a button
  and as a link — which are this component and `button_link/1` crossed with
  `variant`.
  """
  attr :variant, :string, default: "solid", values: ~w(solid soft plain)
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :color, :string, default: "dark", values: ~w(dark light)
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value type)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type="button" class={[button_class(@variant, @size, @color), @class]} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "A button that is a link."
  attr :variant, :string, default: "solid", values: ~w(solid soft plain)
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :color, :string, default: "dark", values: ~w(dark light)
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch replace method download target rel)
  slot :inner_block, required: true

  def button_link(assigns) do
    ~H"""
    <.link class={[button_class(@variant, @size, @color), @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp button_class(variant, size, color) do
    [
      "inline-flex shrink-0 cursor-pointer items-center justify-center rounded-full text-sm/7 font-medium",
      variant == "plain" && "gap-2",
      variant != "plain" && "gap-1",
      size == "md" && "px-3 py-1",
      size == "lg" && "px-4 py-2",
      variant == "solid" && color == "dark" &&
        "bg-mist-950 text-white hover:bg-mist-800 dark:bg-mist-300 dark:text-mist-950 dark:hover:bg-mist-200",
      variant == "solid" && color == "light" &&
        "bg-white text-mist-950 hover:bg-mist-100 dark:bg-mist-100 dark:hover:bg-white",
      variant == "soft" &&
        "bg-mist-950/10 text-mist-950 hover:bg-mist-950/15 dark:bg-white/10 dark:text-white dark:hover:bg-white/20",
      variant == "plain" && color == "dark" &&
        "text-mist-950 hover:bg-mist-950/10 dark:text-white dark:hover:bg-white/10",
      variant == "plain" && color == "light" &&
        "text-white hover:bg-white/15 dark:hover:bg-white/10"
    ]
  end

  @doc "One figure and its label."
  attr :value, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def stat(assigns) do
    ~H"""
    <div class={["rounded-xl bg-mist-950/2.5 p-6 dark:bg-white/5", @class]} {@rest}>
      <div class="text-2xl/10 tracking-tight text-mist-950 dark:text-white">{@value}</div>
      <p class="mt-2 text-sm/7 text-mist-700 dark:text-mist-400">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  # ── sections ─────────────────────────────────────────────────────────────

  @doc """
  The sticky top bar: logo, left-aligned links, actions on the right.

  Its height is `--scroll-padding-top`, set in `app.css` because HEEx would read
  the kit's inline `<style>` braces as interpolation.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :logo, required: true
  slot :links, required: true
  slot :actions

  def navbar(assigns) do
    ~H"""
    <header class={["sticky top-0 z-10 bg-mist-100 dark:bg-mist-950", @class]} {@rest}>
      <nav>
        <div class="mx-auto flex h-(--scroll-padding-top) max-w-7xl items-center gap-4 px-6 lg:px-10">
          <div class="flex flex-1 items-center gap-12">
            <div class="flex items-center">{render_slot(@logo)}</div>
            <div class="flex gap-8 max-lg:hidden">{render_slot(@links)}</div>
          </div>
          <div class="flex flex-1 items-center justify-end gap-4">
            <div class="flex shrink-0 items-center gap-5">{render_slot(@actions)}</div>

            <details class="group lg:hidden">
              <summary
                class="inline-flex cursor-pointer list-none rounded-full p-1.5 text-mist-950 hover:bg-mist-950/10 [&::-webkit-details-marker]:hidden dark:text-white dark:hover:bg-white/10"
                aria-label="Toggle menu"
              >
                <svg viewBox="0 0 24 24" fill="currentColor" class="size-6 group-open:hidden">
                  <path
                    fill-rule="evenodd"
                    d="M3.748 8.248a.75.75 0 0 1 .75-.75h15a.75.75 0 0 1 0 1.5h-15a.75.75 0 0 1-.75-.75ZM3.748 15.75a.75.75 0 0 1 .75-.751h15a.75.75 0 0 1 0 1.5h-15a.75.75 0 0 1-.75-.75Z"
                    clip-rule="evenodd"
                  />
                </svg>
                <svg
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="1.5"
                  stroke="currentColor"
                  class="hidden size-6 group-open:block"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
                </svg>
              </summary>
              <div
                id="mobile-menu"
                class="fixed inset-x-0 top-(--scroll-padding-top) bottom-0 z-20 flex flex-col gap-6 overflow-y-auto bg-mist-100 px-6 py-6 dark:bg-mist-950"
              >
                {render_slot(@links)}
              </div>
            </details>
          </div>
        </div>
      </nav>
    </header>
    """
  end

  @doc "A link in the navbar. Large enough to tap in the mobile sheet."
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch replace)
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      class={[
        "group inline-flex items-center justify-between gap-2 text-3xl/10 font-medium text-mist-950 lg:text-sm/7 dark:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "The footer: categories of links, then the fine print."
  attr :class, :string, default: nil
  attr :rest, :global
  slot :links, required: true
  slot :fineprint, required: true

  def footer(assigns) do
    ~H"""
    <footer class={["pt-16", @class]} {@rest}>
      <div class="bg-mist-950/2.5 py-16 text-mist-950 dark:bg-white/5 dark:text-white">
        <.container class="flex flex-col gap-16">
          <nav class="grid grid-cols-2 gap-6 text-sm/7 sm:has-[>:last-child:nth-child(3)]:grid-cols-3 sm:has-[>:nth-child(5)]:grid-cols-3 md:has-[>:last-child:nth-child(4)]:grid-cols-4 lg:has-[>:nth-child(5)]:grid-cols-5">
            {render_slot(@links)}
          </nav>
          <div class="text-sm/7 text-mist-600 dark:text-mist-500">{render_slot(@fineprint)}</div>
        </.container>
      </div>
    </footer>
    """
  end

  @doc "One column of footer links."
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def footer_category(assigns) do
    ~H"""
    <div {@rest}>
      <h3>{@title}</h3>
      <ul role="list" class="mt-2 flex flex-col gap-2">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc "One footer link."
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch target rel)
  slot :inner_block, required: true

  def footer_link(assigns) do
    ~H"""
    <li class={["text-mist-700 hover:text-mist-950 dark:text-mist-400 dark:hover:text-white", @class]}>
      <.link {@rest}>{render_slot(@inner_block)}</.link>
    </li>
    """
  end

  # ── tier ─────────────────────────────────────────────────────────────────

  @doc """
  The tint a source's tier gets. A tint and nothing more: #66's full treatment
  (gilded / corporate / group-chat) is the layer after MVP-0, and #69 decision 7
  says the tier is a theme, not the core.
  """
  def tier_class(:aristocracy), do: "text-amber-700 dark:text-amber-400"
  def tier_class(:middle), do: "text-mist-700 dark:text-mist-400"
  def tier_class(:plebs), do: "text-mist-500 dark:text-mist-500"
  def tier_class(nil), do: "text-mist-500 dark:text-mist-500"

  @doc "The glyph #69 §6 uses for a tier in coverage badges."
  def tier_glyph(:aristocracy), do: "👑"
  def tier_glyph(:middle), do: "📚"
  def tier_glyph(:plebs), do: "📱"
  def tier_glyph(nil), do: "•"
end
