defmodule DevilsDictionaryWeb.Examples do
  @moduledoc """
  The word's examples (#181): one section, `#examples`, in the main column
  between the definitions and the culture block — found things after asserted
  things, before searched things.

  What arrives is `%WordPage{}.examples`, already read, folded, ordered and
  counted by `DevilsDictionary.Examples` — the same contract `Word` and
  `Thing` work to — so this module draws and never decides.

  Two registers, one heading, one byline:

    * **exemplar cards** — a thing a person cites, with the why (#181 build
      2), drawn first (decision 2): who, *cited as an example of* which
      meaning, the rationale, the evidence with its links, who nominated it,
      the review state, and both vote counts. Never *is a* (#105 rule 4). A
      contributor or reviewer also sees nominations still under review,
      marked so and linked to the review form; the public sees a person's
      card only once a reviewer has accepted it (`Claims.visible/2`).
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
    exemplars = Enum.filter(assigns.examples.items, &(&1.layer == :exemplar))
    {shown, rest} = Enum.split(instances, assigns.examples.cap.instance)
    pending = Enum.count(exemplars, &pending?/1)

    assigns =
      assigns
      |> assign(:exemplars, exemplars)
      |> assign(:cited, length(exemplars) - pending)
      |> assign(:pending, pending)
      |> assign(:hidden, Enum.count(exemplars, &hidden_from_public?/1))
      |> assign(:cited_ids, cited_subjects(exemplars))
      |> assign(:shown, shown)
      |> assign(:rest, rest)
      |> assign(:total, assigns.examples.totals.instance)
      |> assign(:badges?, assigns.examples.sources |> Enum.uniq_by(& &1.slug) |> length() > 1)

    ~H"""
    <.slab :if={@examples.items != []} id="examples" title="Examples">
      <:meta>
        <span :if={@cited > 0}><span class="tabular-nums">{@cited}</span> cited</span>
        <span :if={@cited > 0 and (@pending > 0 or @total > 0)}> · </span>
        <span :if={@pending > 0}><span class="tabular-nums">{@pending}</span> under review</span>
        <span :if={@pending > 0 and @total > 0}> · </span>
        <span :if={@total > 0}><span class="tabular-nums">{@total}</span> named by the record</span>
      </:meta>

      <div class="py-4">
        <%!-- Cards first, because they are few and carry a why (#181
             decision 2); the chips beneath are the record, unchanged. --%>
        <ul
          :if={@exemplars != []}
          role="list"
          id="examples-exemplars"
          class={["flex flex-col gap-3", @shown != [] && "mb-5"]}
        >
          <li :for={item <- @exemplars} id={"examples-" <> dom_id(item.id)} class="min-w-0">
            <.card item={item} />
          </li>
        </ul>

        <ul :if={@shown != []} role="list" id="examples-instances" class="flex flex-wrap gap-2">
          <li :for={item <- @shown} class="max-w-full min-w-0 text-base/6 sm:text-sm/6">
            <.chip
              item={item}
              badges?={@badges?}
              cited?={MapSet.member?(@cited_ids, item.subject.entity_id)}
              trail={@trail}
              demo={@demo}
            />
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
              <.chip
                item={item}
                badges?={@badges?}
                cited?={MapSet.member?(@cited_ids, item.subject.entity_id)}
                trail={@trail}
                demo={@demo}
              />
            </li>
          </ul>
        </details>

        <.byline sources={@examples.sources} lemma={@lemma} />
        <p
          :if={@exemplars != []}
          id="examples-cited-byline"
          class="mt-1 text-base/7 text-mist-500 sm:text-sm/7"
        >
          Cited by people who gave a reason and evidence; the reasons are theirs, not the record's.
          <span :if={@hidden > 0}>A person's nomination is shown to contributors only until a reviewer accepts it.</span>
        </p>
      </div>
    </.slab>
    """
  end

  # A nomination nobody has decided yet — what the public never sees for a
  # person, and a contributor sees marked.
  defp pending?(%{claim: %{review_state: state}}), do: state in [:needs_review, :disputed]

  # Only a person nominated here waits out of public view (`Claims.visible/2`);
  # a pending work or artifact is public, and its card must not say otherwise.
  defp hidden_from_public?(%{subject: %{entity_kind: :person}} = item), do: pending?(item)
  defp hidden_from_public?(_item), do: false

  # A thing's page, or — for a content subject (a GIF, a quotation), which has
  # no entity page — the claim's own.
  defp subject_path(%{subject: %{kind: :content}, claim: claim}),
    do: "/connections/#{claim.assertion_id}"

  defp subject_path(%{subject: subject}),
    do: "/entities/#{subject.object_id}/#{Connection.slugify(subject.label)}"

  # The things both layers name: the chip gains a ✓ (#181 wireframe 2), and
  # the two stay two items, because their signals are different kinds of thing.
  defp cited_subjects(exemplars) do
    exemplars
    |> Enum.reject(&pending?/1)
    |> Enum.map(& &1.subject.entity_id)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  attr :item, :map, required: true

  # One exemplar: a thing someone cites for a meaning. A card because it is
  # a different kind of content from the chips beneath — a claim with a why,
  # evidence and a state — and a bordered one on the section's well rather
  # than a raised one, so it reads as an entry and not as a button.
  defp card(assigns) do
    item = assigns.item

    assigns =
      assigns
      |> assign(:subject, item.subject)
      |> assign(:claim, item.claim)
      |> assign(:signals, item.signals)
      |> assign(:pending?, pending?(item))
      |> assign(:hidden_from_public?, hidden_from_public?(item))
      |> assign(:href, subject_path(item))

    ~H"""
    <article class={[
      "rounded-xl bg-white/70 p-4 ring-1 dark:bg-white/2.5",
      if(@pending?,
        do: "ring-amber-600/30 dark:ring-amber-400/25",
        else: "ring-mist-950/10 dark:ring-white/10"
      )
    ]}>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 class="min-w-0 text-base/7 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
          <.link
            navigate={@href}
            class="break-words underline decoration-mist-950/20 underline-offset-4 hover:decoration-mist-950 dark:decoration-white/25 dark:hover:decoration-white"
          >
            {@subject.label}
          </.link>
        </h3>
        <p
          :if={@pending?}
          id={"examples-state-#{@claim.assertion_id}"}
          class="inline-flex items-center gap-1 rounded-full bg-amber-500/10 py-0.5 pr-2 pl-1 text-sm/5 font-medium text-amber-800 dark:bg-amber-400/10 dark:text-amber-300"
        >
          <.icon name="hero-clock-mini" class="size-4 shrink-0" />
          {state_label(@claim.review_state)}
        </p>
      </div>

      <p class="text-base/7 text-mist-500 sm:text-sm/6">
        {kind_line(@subject)}
      </p>

      <p class="mt-2 text-base/7 text-pretty text-mist-700 sm:text-sm/6 dark:text-mist-300">
        cited as an example of
        <span :if={@item.target.gloss} class="text-mist-950 dark:text-white">“{@item.target.gloss}”</span><span :if={
          is_nil(@item.target.gloss)
        }>this meaning</span>
      </p>

      <%!-- The rationale is the nominator's, in their words. Clamped to two
           lines on a phone and opened in place; one copy of the text, so a
           screen reader reads it once. --%>
      <details
        id={"examples-rationale-#{@claim.assertion_id}"}
        class="group mt-2 min-w-0"
      >
        <summary class="cursor-pointer list-none text-base/7 text-pretty text-mist-950 sm:cursor-auto sm:text-sm/6 dark:text-white [&::-webkit-details-marker]:hidden">
          <span class="line-clamp-2 group-open:line-clamp-none sm:line-clamp-none">
            {@claim.rationale}
          </span>
          <span class="text-mist-500 underline underline-offset-4 group-open:hidden sm:hidden">
            more
          </span>
        </summary>
      </details>

      <ul
        :if={@claim.evidence != []}
        role="list"
        id={"examples-evidence-#{@claim.assertion_id}"}
        class="mt-3 flex flex-col gap-1"
      >
        <li :for={evidence <- @claim.evidence} class="min-w-0 text-base/7 sm:text-sm/6">
          <span :if={evidence.role == :contradicts} class="text-mist-500">against · </span>
          <a
            :if={evidence.url}
            href={evidence.url}
            target="_blank"
            rel="noopener noreferrer"
            class="break-words text-mist-700 underline decoration-mist-950/20 underline-offset-4 hover:text-mist-950 hover:decoration-mist-950 dark:text-mist-300 dark:decoration-white/25 dark:hover:text-white"
          >
            {evidence.attribution || evidence.url}<span aria-hidden="true">&nbsp;↗</span>
          </a>
          <span :if={is_nil(evidence.url)} class="text-mist-700 dark:text-mist-300">
            {evidence.attribution || evidence.locator}
          </span>
        </li>
      </ul>

      <p class="mt-3 text-base/7 text-pretty text-mist-500 sm:text-sm/6">
        <span class="tabular-nums">{@claim.evidence_count}</span>
        evidence
        · nominated by {@claim.nominated_by.label}<span :if={not @pending?}> · {state_label(
          @claim.review_state
        )}</span>
        ·
        <span
          id={"examples-votes-#{@claim.assertion_id}"}
          class="whitespace-nowrap tabular-nums"
          aria-label={"#{@signals.human_up} cite, #{@signals.human_down} object"}
        >▲ {@signals.human_up} ▽ {@signals.human_down}</span>
      </p>

      <p :if={@pending?} class="mt-2 text-base/7 text-mist-500 sm:text-sm/6">
        {if(@hidden_from_public?,
          do: "Not public until a reviewer accepts it.",
          else: "Not yet reviewed."
        )}
        <.link
          navigate={"/connections/#{@claim.assertion_id}"}
          id={"examples-review-#{@claim.assertion_id}"}
          class="text-mist-700 underline underline-offset-4 hover:text-mist-950 dark:text-mist-300 dark:hover:text-white"
        >
          Review
        </.link>
      </p>
    </article>
    """
  end

  defp kind_line(%{entity_kind: kind, qid: qid}) do
    [kind && to_string(kind), qid] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp state_label(:accepted), do: "selected by a reviewer"
  defp state_label(:changed_since_review), do: "changed since review"
  defp state_label(:disputed), do: "disputed"
  defp state_label(_needs_review), do: "needs review"

  @doc "How many chips the disclosure opens as a wall before it scrolls instead."
  def scroll_cap, do: @scroll_cap

  attr :item, :map, required: true
  attr :badges?, :boolean, default: false
  attr :cited?, :boolean, default: false
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
      <span :if={@cited?} class="shrink-0 text-mist-500" title="also cited above">
        ✓<span class="sr-only">, also cited above</span>
      </span>
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
