defmodule DevilsDictionaryWeb.Examples do
  @moduledoc """
  The word's examples (#181): one section, `#examples`, in the main column
  between the definitions and the culture block — found things after asserted
  things, before searched things.

  What arrives is `%WordPage{}.examples`, already read, folded, ordered and
  counted by `DevilsDictionary.Examples` — the same contract `Word` and
  `Thing` work to — so this module draws and never decides.

  Two registers, one heading, one byline:

    * **exemplar cards** — a thing a person cites, with the why. Build 2 draws
      them first; none exist yet, so the section holds chips only and the
      card register is the empty slot above them.
    * **instance chips** — the named things a source files under a meaning,
      as one dense row: a word is solid when something has been absorbed for
      it and muted when it is a bare index row, the same affordance as the
      related words; a thing with no word links to its entity page and is
      drawn outlined, because it is a thing rather than a word.

  The byline says which source named what, once. A chip carries its sources'
  badges only when the section has more than one source, because then the
  badge is the only way to tell a chip WordNet named from one Wikidata filed;
  with one source the byline already said it, and a badge on every chip would
  be #152's two hundred mentions again. A thing both sources name carries both.

  This is a section, not a shelf: nothing is requested, there is no run and no
  content type, and it knows no source by name (promise 9) — the badges and
  names are the rows `Examples.for_page/3` composed.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionaryWeb.{SourceBadge, Word}

  # Above this, the disclosure's chips scroll inside their own box rather
  # than opening as a wall — the related block's rule and number
  # (`WordPage.scroll_cap/0`): *poet* files 145 things.
  @scroll_cap 48

  attr :examples, :map, required: true
  attr :lemma, :string, required: true
  attr :trail, :list, default: []
  attr :demo, :boolean, default: false

  def section(assigns) do
    instances = Enum.filter(assigns.examples.items, &(&1.layer == :instance))
    {shown, rest} = Enum.split(instances, assigns.examples.cap.instance)

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:rest, rest)
      |> assign(:total, assigns.examples.totals.instance)
      |> assign(:badges?, assigns.examples.sources |> Enum.uniq_by(& &1.slug) |> length() > 1)

    ~H"""
    <.slab :if={@examples.items != []} id="examples" title="Examples">
      <:meta>
        <span class="tabular-nums">{@total}</span> named by the record
      </:meta>

      <div class="py-4">
        <%!-- The exemplar cards go here, first, when build 2 gives a word any
             (#181 decision 2). Nothing is cited yet, so nothing renders. --%>
        <ul role="list" id="examples-instances" class="flex flex-wrap gap-2">
          <li :for={item <- @shown} class="max-w-full min-w-0 text-base/6 sm:text-sm/6">
            <.chip item={item} badges?={@badges?} trail={@trail} demo={@demo} />
          </li>
        </ul>

        <%!-- `min-w-0 max-w-full` for the reason `relation_group` gives:
             at 375 px a long name must wrap inside the box, not push it. --%>
        <details :if={@rest != []} id="examples-more" class="mt-3 max-w-full min-w-0">
          <summary class="w-fit cursor-pointer text-base/7 text-mist-500 underline underline-offset-4 hover:text-mist-950 sm:text-sm/7 dark:hover:text-white">
            <span class="tabular-nums">{length(@rest)}</span> more named
          </summary>
          <ul
            role="list"
            id="examples-rest"
            class={[
              "mt-2 flex flex-wrap gap-2 pt-1",
              length(@rest) > scroll_cap() && "max-h-64 overflow-y-auto overscroll-contain"
            ]}
          >
            <li :for={item <- @rest} class="max-w-full min-w-0 text-base/6 sm:text-sm/6">
              <.chip item={item} badges?={@badges?} trail={@trail} demo={@demo} />
            </li>
          </ul>
        </details>

        <.byline sources={@examples.sources} lemma={@lemma} />
      </div>
    </.slab>
    """
  end

  @doc "How many chips the disclosure opens as a wall before it scrolls instead."
  def scroll_cap, do: @scroll_cap

  attr :item, :map, required: true
  attr :badges?, :boolean, default: false
  attr :trail, :list, default: []
  attr :demo, :boolean, default: false

  defp chip(assigns) do
    subject = assigns.item.subject

    assigns =
      assigns
      |> assign(:subject, subject)
      |> assign(:href, href(subject, assigns.trail, assigns.demo))
      |> assign(:badge_sources, Enum.uniq_by(assigns.item.sources, & &1.slug))
      |> assign(:title, title(assigns.item))

    ~H"""
    <.link
      id={"examples-" <> dom_id(@item.id)}
      navigate={@href}
      title={@title}
      class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-full py-0.5 pr-3",
        if(@badges?, do: "pl-0.5", else: "pl-3"),
        @subject.kind == :entity &&
          "text-mist-700 outline-1 -outline-offset-1 outline-mist-950/15 hover:bg-mist-950/5 dark:text-mist-300 dark:outline-white/20 dark:hover:bg-white/10",
        (@subject.kind == :lexeme and @subject.enriched?) &&
          "bg-mist-950/5 font-medium text-mist-950 hover:bg-mist-950/10 dark:bg-white/10 dark:text-white dark:hover:bg-white/15",
        (@subject.kind == :lexeme and not @subject.enriched?) &&
          "bg-mist-950/2.5 text-mist-500 hover:bg-mist-950/5 dark:bg-white/5 dark:hover:bg-white/10"
      ]}
    >
      <span :if={@badges?} class="flex shrink-0 -space-x-1">
        <SourceBadge.badge
          :for={source <- @badge_sources}
          source={source}
          decorative
          class="ring-2 ring-mist-50 dark:ring-mist-900"
        />
      </span>
      <span class="min-w-0 truncate">{@subject.label}</span>
      <span :if={@badges?} class="sr-only">
        — {Enum.map_join(@badge_sources, " and ", & &1.name)}
      </span>
    </.link>
    """
  end

  # Who named what, once, from the rows: *Named under a sense of war by
  # WordNet · 16 filed as instances of War by Wikidata, 1 of them a word.*
  attr :sources, :list, required: true
  attr :lemma, :string, required: true

  defp byline(assigns) do
    ~H"""
    <ul
      role="list"
      id="examples-byline"
      class="mt-4 flex flex-col gap-1 text-base/7 text-mist-500 sm:text-sm/7"
    >
      <li :for={source <- @sources} id={"examples-by-#{source.slug}-#{source.kind}"}>
        <span class="tabular-nums">{source.count}</span>
        {named(source, @lemma)} by <span class="inline-flex items-baseline gap-1.5 text-mist-700 dark:text-mist-300">
          <SourceBadge.badge source={source} decorative class="self-center" />
          {source.name}
        </span>{words(
          source
        )}
      </li>
    </ul>
    """
  end

  defp named(%{kind: :sense}, lemma), do: "named under a sense of #{lemma}"

  defp named(%{kind: :entity, classes: classes, count: count}, _lemma),
    do:
      "filed as #{if count == 1, do: "an instance", else: "instances"} of #{Enum.join(classes, ", ")}"

  # How many of a thing-source's items are words — the rest link to entity
  # pages. Said only when some are not, and never for a word-source, whose
  # every item is a word.
  defp words(%{kind: :entity, words: n, count: count}) when n < count do
    case n do
      0 -> ", none of them a word yet"
      1 -> ", 1 of them a word"
      n -> ", #{n} of them words"
    end
  end

  defp words(_source), do: nil

  defp href(%{kind: :lexeme, slug: slug}, trail, demo), do: Word.hop(slug, trail, demo)

  defp href(%{kind: :entity, object_id: id, label: label}, _trail, _demo),
    do: "/entities/#{id}/#{Connection.slugify(label)}"

  # The chip names the thing; the tooltip says what else WordNet calls it and
  # who filed it where — the item's own reason, never a new sentence.
  defp title(%{subject: %{aliases: []}, reason: reason}), do: reason

  defp title(%{subject: %{aliases: aliases}, reason: reason}),
    do: "also #{Enum.join(aliases, ", ")}. #{reason}"

  defp dom_id(id), do: String.replace(id, ":", "-")
end
