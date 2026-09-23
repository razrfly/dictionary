defmodule DevilsDictionaryWeb.SourceBadge do
  @moduledoc """
  One identity per source, drawn the same way everywhere (#152).

  Measured on `/define/love` before this: fifteen sources put something on
  the page and the reader was told who they were about two hundred times —
  *Source ↗* on 68 cards, the Spotify wordmark on twelve, names in four
  sizes of grey, an emoji for the tier — and nowhere in one place. The badge
  is the one way a source is identified from now on: a round mark beside the
  name in a block's header, once; and the stack is the one place that lists
  every source on the page.

  Two rules the components keep:

    * **A badge knows no provider by name** (promise 9 of
      `docs/discovery/README.md`). What it draws is the source row's `logo`
      when the row has one — a local asset this app ships, never a hotlink,
      the same rule as a licence mark — and otherwise a monogram computed
      from the name, on a tint chosen by the slug. Nothing here branches on
      who the source is.
    * **A badge is never the only place a name lives.** In a header the name
      is beside it and the badge is decorative; in the stack the name is the
      link's accessible text and the tooltip, and `title` on top for the
      pointer. Touch has no hover, and a licence credit that only some
      readers see is not met.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Discovery.Shelf

  # The tints a monogram can take, chosen by slug so a source keeps its colour
  # from page to page. A 👑 source is always amber: that is the tier's colour
  # everywhere else on the page, and the ring says so too. Every class is
  # written out in full because Tailwind reads this file, not the runtime.
  @tints [
    "bg-sky-100 text-sky-900 dark:bg-sky-400/20 dark:text-sky-100",
    "bg-emerald-100 text-emerald-900 dark:bg-emerald-400/20 dark:text-emerald-100",
    "bg-violet-100 text-violet-900 dark:bg-violet-400/20 dark:text-violet-100",
    "bg-rose-100 text-rose-900 dark:bg-rose-400/20 dark:text-rose-100",
    "bg-teal-100 text-teal-900 dark:bg-teal-400/20 dark:text-teal-100",
    "bg-orange-100 text-orange-900 dark:bg-orange-400/20 dark:text-orange-100",
    "bg-indigo-100 text-indigo-900 dark:bg-indigo-400/20 dark:text-indigo-100",
    "bg-lime-100 text-lime-900 dark:bg-lime-400/20 dark:text-lime-100"
  ]

  @aristocracy "bg-amber-100 text-amber-900 dark:bg-amber-400/20 dark:text-amber-100"

  @doc """
  The mark. `source` is anything with a `name`, a `slug` and a `tier` — a
  `Sources.Source` row, or the map a shelf state or a browser config carries.
  `logo`, when present and a local path, is drawn instead of the monogram.

  `decorative` is for a header where the name is printed beside it: the
  badge is then hidden from the accessibility tree rather than read twice.
  """
  attr :source, :map, required: true
  attr :size, :string, default: "sm", values: ~w(sm md)
  attr :decorative, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  def badge(assigns) do
    source = assigns.source

    assigns =
      assigns
      |> assign(:logo, logo(Map.get(source, :logo)))
      |> assign(:name, Map.get(source, :name) || Map.get(source, :slug) || "")
      |> assign(:initials, initials(Map.get(source, :name)))
      |> assign(:tint, tint(source))

    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full font-medium uppercase select-none",
        "outline-1 -outline-offset-1 outline-mist-950/10 dark:outline-white/10",
        @size == "sm" && "size-5 text-[0.5625rem]/5",
        @size == "md" && "size-7 text-[0.6875rem]/7",
        is_nil(@logo) && @tint,
        @logo && "bg-white dark:bg-mist-900",
        @class
      ]}
      aria-hidden={@decorative}
      role={if @decorative, do: nil, else: "img"}
      aria-label={if @decorative, do: nil, else: @name}
      {@rest}
    >
      <img :if={@logo} src={@logo} alt="" class="size-full object-cover" />
      <span :if={!@logo} aria-hidden="true">{@initials}</span>
    </span>
    """
  end

  @doc """
  Every source on the page, as overlapping badges (#152 rule 3).

  `sources` is a list of `%{slug, name, tier, logo, anchor}` already composed
  by the caller — tier then slug, one per slug — so this draws and never
  decides. Each badge is a link to the block it stands for, which works in
  the dead render and can be tabbed to; the name is the link's accessible
  text, its `title`, and a tooltip on hover and focus.
  """
  attr :id, :string, required: true
  attr :sources, :list, required: true
  attr :class, :any, default: nil

  attr :cap, :integer,
    default: 12,
    doc: "how many badges the row shows before the rest fold behind a +N"

  def stack(assigns) do
    {shown, rest} = Enum.split(assigns.sources, assigns.cap)

    assigns =
      assigns
      |> assign(:count, length(assigns.sources))
      |> assign(:shown, shown)
      |> assign(:rest, rest)
      |> assign(:shown_count, length(shown))

    ~H"""
    <section :if={@sources != []} id={@id} class={@class} aria-labelledby={"#{@id}-heading"}>
      <h2 id={"#{@id}-heading"} class="text-base/8 font-medium text-mist-950 dark:text-white">
        Sources
      </h2>
      <%!-- A ring in the page's own colour is what makes the overlap read as
           a stack rather than a smear; `-space-x-1.5` is the overlap. Twelve
           on the row and the rest behind a +N (#162): `oyster` holds
           seventeen, which wraps in the 22.5 rem rail and would wrap at
           fifteen on a phone. The +N is a `<details>` summary, so it opens
           without JavaScript and in the dead render, and its title lists
           who is folded for a pointer that only hovers. Tier then slug is
           the order already, so the fold takes the tail of the 📱 sources. --%>
      <ul role="list" class="mt-2 flex flex-wrap items-center gap-y-2 pl-1 -space-x-1.5">
        <li :for={{source, index} <- Enum.with_index(@shown)} class="group/badge relative">
          <a
            id={"#{@id}-#{source.slug}"}
            href={source.anchor}
            title={source.name}
            class="block rounded-full ring-2 ring-mist-50 transition-transform hover:z-10 hover:scale-110 focus-visible:z-10 focus-visible:outline-2 focus-visible:outline-offset-2 dark:ring-mist-950"
          >
            <.badge source={source} size="md" decorative />
            <span class="sr-only">{source.name}</span>
          </a>
          <%!-- Anchored to the badge's left edge on the first half of the row
               and to its right on the second, so a tooltip never runs off
               the rail's edge: centred, the first badge's was clipped at the
               viewport. The short name here (*Samuel Johnson*, as the rail
               calls him); the full one is the link's title and its text. --%>
          <span
            role="tooltip"
            class={[
              "pointer-events-none absolute bottom-full z-20 mb-2 rounded-md bg-mist-950 px-2 py-1 text-xs whitespace-nowrap text-white opacity-0 group-focus-within/badge:opacity-100 group-hover/badge:opacity-100 dark:bg-white dark:text-mist-950",
              index < div(@shown_count + 1, 2) && "left-0",
              index >= div(@shown_count + 1, 2) && "right-0"
            ]}
          >
            <span :if={source.tier} aria-hidden="true" class="mr-1">{tier_glyph(source.tier)}</span>{short_name(
              source.name
            )}
          </span>
        </li>
        <li :if={@rest != []} class="relative">
          <details id={"#{@id}-more"} class="group/more">
            <%!-- Anchored to its right edge and opening upward. The +N is the
                 last badge on the row, so a panel that grows leftward stays
                 inside the rail on a phone where one that grew rightward
                 would leave the viewport; and it opens upward because the
                 stack is the last thing in the rail and the kit's main is
                 overflow-clip — a panel that opened downward was cut off at
                 the footer on a phone. --%>
            <summary
              id={"#{@id}-more-summary"}
              title={Enum.map_join(@rest, ", ", &short_name(&1.name))}
              class="block cursor-pointer list-none rounded-full ring-2 ring-mist-50 transition-transform hover:z-10 hover:scale-110 focus-visible:z-10 focus-visible:outline-2 focus-visible:outline-offset-2 dark:ring-mist-950 [&::-webkit-details-marker]:hidden"
            >
              <span class="inline-flex size-7 items-center justify-center rounded-full bg-mist-950/5 text-[0.6875rem]/7 font-medium tabular-nums text-mist-700 outline-1 -outline-offset-1 outline-mist-950/10 select-none group-open/more:bg-mist-950/10 dark:bg-white/10 dark:text-mist-200 dark:outline-white/10">
                +{length(@rest)}
              </span>
              <span class="sr-only">{length(@rest)} more sources</span>
            </summary>
            <ul
              role="list"
              class="absolute right-0 bottom-full z-20 mb-2 w-56 rounded-lg bg-mist-50 p-1.5 shadow-lg outline-1 -outline-offset-1 outline-mist-950/10 dark:bg-mist-900 dark:shadow-none dark:outline-white/10"
            >
              <li :for={source <- @rest}>
                <a
                  id={"#{@id}-#{source.slug}"}
                  href={source.anchor}
                  title={source.name}
                  class="flex items-center gap-2 rounded-md px-2 py-1 text-base/7 text-mist-950 hover:bg-mist-950/5 sm:text-sm/7 dark:text-white dark:hover:bg-white/10"
                >
                  <.badge source={source} decorative />
                  <span class="truncate">{short_name(source.name)}</span>
                </a>
              </li>
            </ul>
          </details>
        </li>
      </ul>
      <p id={"#{@id}-count"} class="mt-2 text-base/7 tabular-nums text-mist-500 sm:text-sm/7">
        {@count} {if @count == 1, do: "source", else: "sources"} on this page
      </p>
    </section>
    """
  end

  @doc """
  The stack's order: tier, then slug — the same turns a shelf takes — with
  one entry per slug, the first seen kept. Wikidata reaches `love` twice, as
  the thing's source and as a catalog corpus, and is one badge.
  """
  def compose(sources) do
    sources
    |> Enum.uniq_by(& &1.slug)
    |> Enum.sort_by(&{Shelf.tier_rank(&1.tier), &1.slug})
  end

  @doc """
  The monogram: the initials of the name's first two significant words.
  *Samuel Johnson, A Dictionary of the English Language* is SJ; *Open
  Library* is OL; *Wiktionary (English) via Kaikki* is W, because a
  parenthetical, a *via* and a year are not the name.
  """
  def initials(nil), do: "?"

  def initials(name) when is_binary(name) do
    name
    |> String.split(",", parts: 2)
    |> hd()
    |> String.replace(~r/\(.*?\)/, " ")
    |> String.replace(~r/\bvia\b.*$/i, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.downcase(&1) in ~w(the a an of) or Regex.match?(~r/^\d+$/, &1)))
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  @doc """
  The name before its comma: *Samuel Johnson, A Dictionary of the English
  Language* is a book, and the tooltip wants the man — the same cut the
  rail's rows make.
  """
  def short_name(nil), do: ""
  def short_name(name), do: name |> String.split(",", parts: 2) |> hd() |> String.trim()

  # A local asset or nothing — the same rule `Culture.mark/1` keeps for a
  # licence mark, for the same reason: a hotlink is a provider's server
  # deciding what our page shows, and a broken image is worse than a monogram.
  defp logo(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path
  end

  defp logo(_other), do: nil

  defp tint(%{tier: :aristocracy}), do: @aristocracy

  defp tint(source) do
    key = Map.get(source, :slug) || Map.get(source, :name) || ""
    Enum.at(@tints, :erlang.phash2(key, length(@tints)))
  end
end
