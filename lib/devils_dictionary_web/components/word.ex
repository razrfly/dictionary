defmodule DevilsDictionaryWeb.Word do
  @moduledoc """
  The word page's own components (#71 §8a.4). Everything here renders what
  `Lexicon.WordPage.build/2` already decided: no queries, no grouping, no
  capping, no markdown. A component that computes something is a component that
  will compute it differently from the query module.

  Two rules from the audits are load-bearing:

    * **Never `phx-value-value`.** LiveView's client reads `phx-value-*` into
      the event's metadata and then overwrites `meta.value` with the element's
      own DOM `.value`, so a button carrying `phx-value-value` silently sends
      an empty string. That is what killed the browse page's chips in S4b, and
      `render_click/1` does not catch it because it skips client JS. Chips here
      are links, and carry their target in the href.
    * **Every element has a stable id.** `#headword`, `#card-bierce`,
      `#related-noun`, `#chip-broader-bivalve` — so a test asserts about the
      element rather than about a word that happens to appear elsewhere on the
      page.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Lexicon.WordPage

  @doc "The word itself: every part of speech the index holds, forms, sound, origin."
  attr :headword, :map, required: true

  def headword(assigns) do
    ~H"""
    <div id="headword" class="border-b border-mist-950/10 pb-8 dark:border-white/10">
      <div class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="font-display text-5xl/none text-mist-950 sm:text-6xl/none dark:text-white">
          {@headword.lemma}
        </h1>
        <p :if={@headword.pronunciations != []} id="pronunciations" class="text-lg/7 text-mist-500">
          <span :for={p <- @headword.pronunciations} class="mr-3 font-mono">{p.ipa}</span>
        </p>
      </div>

      <p id="parts-of-speech" class="mt-3 text-sm/7 text-mist-700 dark:text-mist-400">
        <span :for={{lexeme, i} <- Enum.with_index(@headword.lexemes)}>
          <span :if={i > 0} aria-hidden="true">·</span>
          <span class={[not lexeme.enriched? && "text-mist-500"]}>{lexeme.pos}</span>
        </span>
      </p>

      <p :if={@headword.forms != []} id="forms" class="mt-2 text-sm/7 text-mist-500">
        <span class="text-mist-700 dark:text-mist-400">forms</span>
        {Enum.join(@headword.forms, " · ")}
      </p>

      <p
        :for={{etymology, i} <- Enum.with_index(@headword.etymologies)}
        id={"etymology-#{i}"}
        class="mt-2 max-w-2xl text-sm/7 text-mist-500"
      >
        <span class="text-mist-700 dark:text-mist-400">
          origin ({Enum.join(etymology.parts, ", ")})
        </span>
        {etymology.text}
        <span :if={etymology.source} class="text-mist-400">— {etymology.source}</span>
      </p>

      <p
        :if={@headword.via in [:canonical, :form]}
        id="redirected-from"
        class="mt-4 text-sm/7 text-mist-500"
      >
        redirected from “{@headword.matched}”
      </p>

      <p :if={@headword.also != []} id="also-a-form-of" class="mt-2 text-sm/7 text-mist-500">
        also listed as a form of
        <.link
          :for={other <- @headword.also}
          navigate={~p"/define/#{other.slug}"}
          class="underline underline-offset-4"
        >
          {other.lemma}
        </.link>
      </p>
    </div>
    """
  end

  @doc """
  One source's say on the word. A 👑 author's entry renders as prose; an
  institution's senses render as a list, one block per synset where the source
  has them.
  """
  attr :card, :map, required: true
  attr :trail, :list, default: []

  def source_card(assigns) do
    ~H"""
    <section
      id={@card.id}
      class={[
        "rounded-xl border-l-2 py-6 pl-6",
        @card.tier == :aristocracy && "border-amber-600/50 bg-amber-50/40 dark:bg-amber-950/10",
        @card.tier != :aristocracy && "border-mist-950/10 dark:border-white/10"
      ]}
    >
      <header class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 class={["text-base/8 font-medium", tier_class(@card.tier)]}>
          <span aria-hidden="true" class="mr-1">{tier_glyph(@card.tier)}</span>
          {@card.source.name}
          <span :if={@card.year} class="font-normal text-mist-500">· {@card.year}</span>
          <span :if={@card.pos} class="font-normal text-mist-500">· {@card.pos}</span>
        </h2>
        <.link_out id={"#{@card.id}-out"} href={@card.url} label={@card.source.name} />
      </header>

      <div :if={@card.thumbnail_url} class="mt-4">
        <img
          src={@card.thumbnail_url}
          alt=""
          loading="lazy"
          class="max-h-48 w-auto rounded-lg border border-mist-950/10 dark:border-white/10"
        />
      </div>

      <.document :for={entry <- @card.entries} class="mt-4">
        {Phoenix.HTML.raw(entry.body_html)}
      </.document>

      <.sense_group
        :for={{group, i} <- Enum.with_index(@card.groups)}
        card_id={@card.id}
        group={group}
        index={i}
        trail={@trail}
      />
    </section>
    """
  end

  @doc """
  A synset, or — where the source has no synsets — the whole numbered list of
  its glosses. The relations that hang off these senses render here rather than
  in the page-level block: that is the per-sense rule, and it is what keeps
  *tracked vehicle* off *cat*'s animal sense.

  Each sense carries its own chips, under its own gloss. A Wiktionary card is
  one group holding every sense it has, so chips rendered at group level pool
  the whole card's synonyms into one row — U1a's remaining half-kept rule.
  """
  attr :card_id, :string, required: true
  attr :group, :map, required: true
  attr :index, :integer, required: true
  attr :trail, :list, default: []

  def sense_group(assigns) do
    assigns = assign(assigns, :id, "#{assigns.card_id}-group-#{assigns.index}")

    ~H"""
    <div id={@id} class="mt-4">
      <ol class="space-y-1 text-sm/7 text-mist-700 dark:text-mist-400">
        <.sense_line
          :for={{sense, i} <- Enum.with_index(Enum.take(@group.senses, WordPage.gloss_cap()))}
          id={"#{@id}-sense-#{sense.id}"}
          sense={sense}
          marker={if @group.group_key, do: "●", else: "#{i + 1}"}
          trail={@trail}
        />
      </ol>

      <details :if={length(@group.senses) > WordPage.gloss_cap()} id={"#{@id}-more"} class="mt-1">
        <summary class="cursor-pointer text-sm/7 text-mist-500 hover:text-mist-950 dark:hover:text-white">
          show {length(@group.senses) - WordPage.gloss_cap()} more
        </summary>
        <ol class="mt-1 space-y-1 text-sm/7 text-mist-700 dark:text-mist-400">
          <.sense_line
            :for={{sense, i} <- Enum.with_index(Enum.drop(@group.senses, WordPage.gloss_cap()))}
            id={"#{@id}-sense-#{sense.id}"}
            sense={sense}
            marker={if @group.group_key, do: "●", else: "#{i + WordPage.gloss_cap() + 1}"}
            trail={@trail}
          />
        </ol>
      </details>

      <.chain :if={@group.chain != []} id={"#{@id}-chain"} chain={@group.chain} trail={@trail} />
    </div>
    """
  end

  @doc """
  One numbered gloss with the relations that belong to it and to nothing else.
  """
  attr :id, :string, required: true
  attr :sense, :map, required: true
  attr :marker, :string, required: true
  attr :trail, :list, default: []

  def sense_line(assigns) do
    ~H"""
    <li id={@id} class="flex gap-3">
      <span class="shrink-0 text-mist-400">{@marker}</span>
      <div class="min-w-0">
        <span>
          {@sense.gloss}
          <span :if={@sense.tags != []} class="text-mist-400">
            ({Enum.join(@sense.tags, ", ")})
          </span>
        </span>
        <.relation_group
          :for={{group, chips} <- ordered(@sense.relations)}
          id={"#{@id}-#{group_slug(group)}"}
          group={group}
          chips={chips}
          trail={@trail}
        />
      </div>
    </li>
    """
  end

  @doc """
  The walk upward from one synset — *bivalve › mollusk › invertebrate ›
  animal*. Each step is a word with a page of its own.
  """
  attr :id, :string, required: true
  attr :chain, :list, required: true
  attr :trail, :list, default: []

  def chain(assigns) do
    ~H"""
    <p id={@id} class="mt-2 flex flex-wrap items-center gap-x-2 text-sm/7">
      <span class="text-mist-500">broader</span>
      <span :for={{step, i} <- Enum.with_index(@chain)} class="flex items-center gap-x-2">
        <span :if={i > 0} aria-hidden="true" class="text-mist-400">›</span>
        <.link
          navigate={hop(step.slug, @trail)}
          class={[
            "hover:underline",
            step.enriched? && "text-mist-950 dark:text-white",
            not step.enriched? && "text-mist-500"
          ]}
        >
          {step.lemma}
        </.link>
      </span>
    </p>
    """
  end

  @doc "One named row of chips — *similar*, *broader*, *family* — capped, with its “+N”."
  attr :id, :string, required: true
  attr :group, :any, required: true
  attr :chips, :map, required: true
  attr :trail, :list, default: []

  def relation_group(assigns) do
    ~H"""
    <div id={@id} class="mt-2 flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <span class="w-20 shrink-0 text-sm/7 text-mist-500">{label_for(@group)}</span>
      <.chip
        :for={chip <- @chips.shown}
        id={"#{@id}-#{chip.slug}"}
        group={@group}
        chip={chip}
        trail={@trail}
      />
      <%!-- `max-w-full min-w-0` is load-bearing at 375 px: a flex item sizes to
      its widest child by default, so a long lemma like *murrumbidgee oyster*
      pushed the expander past the viewport instead of wrapping inside it. --%>
      <details :if={@chips.rest != []} class="min-w-0 max-w-full">
        <summary class="cursor-pointer text-sm/7 text-mist-500 hover:text-mist-950 dark:hover:text-white">
          +{length(@chips.rest)}
        </summary>
        <span class="mt-1 flex flex-wrap gap-1 pt-1">
          <.chip
            :for={chip <- @chips.rest}
            id={"#{@id}-#{chip.slug}"}
            group={@group}
            chip={chip}
            trail={@trail}
          />
        </span>
      </details>
    </div>
    """
  end

  @doc """
  One hop. Bold is a word something has been absorbed for; muted is a bare
  index row, which still has a page — that is the promise in #71 §1, and it is
  why a chip is never a dead end.

  The id is the containing group's, not the chip's own: one word can be broader
  than two of *cat*'s eight synsets, and `#chip-broader-carnivore` twice on a
  page is a duplicate id.
  """
  attr :id, :string, required: true
  attr :group, :any, required: true
  attr :chip, :map, required: true
  attr :trail, :list, default: []

  def chip(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={hop(@chip.slug, @trail)}
      title={"#{label_for(@group)} · #{@chip.pos}"}
      class={[
        "rounded-full px-3 py-0.5 text-sm/6",
        @chip.enriched? &&
          "bg-mist-950/5 font-medium text-mist-950 hover:bg-mist-950/10 dark:bg-white/10 dark:text-white dark:hover:bg-white/15",
        not @chip.enriched? &&
          "bg-mist-950/2.5 text-mist-500 hover:bg-mist-950/5 dark:bg-white/5 dark:hover:bg-white/10"
      ]}
    >
      {@chip.lemma}
    </.link>
    """
  end

  @doc "The words walked to get here, kept in the URL so the walk can be pasted."
  attr :trail, :list, required: true
  attr :current, :string, default: nil

  def trail(assigns) do
    ~H"""
    <nav
      :if={@trail != []}
      id="trail"
      aria-label="trail"
      class="flex flex-wrap items-center gap-x-2 text-sm/7"
    >
      <span :for={{step, i} <- Enum.with_index(@trail)} class="flex items-center gap-x-2">
        <span :if={i > 0} aria-hidden="true" class="text-mist-400">›</span>
        <.link
          id={"trail-#{step.slug}"}
          navigate={hop(step.slug, Enum.take(@trail, i))}
          class="text-mist-500 hover:text-mist-950 hover:underline dark:hover:text-white"
        >
          {step.lemma}
        </.link>
      </span>
      <span aria-hidden="true" class="text-mist-400">›</span>
      <span class="text-mist-950 dark:text-white">{@current}</span>
    </nav>
    """
  end

  @doc "The ↗ every card carries. U6 says a card without one is a bug, not a missing icon."
  attr :id, :string, required: true
  attr :href, :string, default: nil
  attr :label, :string, required: true

  def link_out(assigns) do
    ~H"""
    <.link
      :if={@href}
      id={@id}
      href={@href}
      target="_blank"
      rel="noopener"
      title={"read this at #{@label}"}
      class="text-sm/7 text-mist-500 hover:text-mist-950 dark:hover:text-white"
    >
      <span aria-hidden="true">↗</span>
      <span class="sr-only">read this at {@label}</span>
    </.link>
    """
  end

  @doc """
  The relation groups of one part of speech, in #71 §7's order. These are the
  edges the source hung off the word rather than off a sense.
  """
  attr :related, :map, required: true
  attr :trail, :list, default: []

  def related_block(assigns) do
    ~H"""
    <section id={"related-#{@related.pos || "x"}"} class="mt-8">
      <h2 class="text-base/8 font-medium text-mist-950 dark:text-white">
        Related words
        <span :if={@related.pos} class="font-normal text-mist-500">· {@related.pos}</span>
      </h2>
      <.relation_group
        :for={{group, chips} <- ordered(@related.groups)}
        id={"related-#{@related.pos || "x"}-#{group_slug(group)}"}
        group={group}
        chips={chips}
        trail={@trail}
      />
    </section>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # #71 §7's order, and the `see_also` groups — which are `{:says_see, source}`
  # rather than a bare atom, because one per author is the point — sorted among
  # them by where `:says_see` sits.
  defp ordered(groups) do
    Enum.sort_by(groups, fn {group, _chips} ->
      {Enum.find_index(WordPage.group_order(), &(&1 == key_of(group))), name_of(group)}
    end)
  end

  defp key_of({:says_see, _source}), do: :says_see
  defp key_of(group), do: group

  defp name_of({:says_see, source}), do: source.slug
  defp name_of(_group), do: ""

  defp label_for({:says_see, source}), do: "#{author(source)} says see"
  defp label_for(group), do: WordPage.group_label(group)

  # "Samuel Johnson, A Dictionary of the English Language" is a book; the label
  # wants the man.
  defp author(source), do: source.name |> String.split(",") |> hd()

  defp group_slug({:says_see, source}), do: "says-see-#{source.slug}"
  defp group_slug(group), do: group |> Atom.to_string() |> String.replace("_", "-")

  @doc """
  The href a hop takes: the target word, with the word being left appended to
  the trail, so the URL carries the walk. Public because the thing side hops
  through the same trail.
  """
  def hop(slug, []), do: ~p"/define/#{slug}"
  def hop(slug, trail), do: ~p"/define/#{slug}?#{[trail: Enum.map_join(trail, ",", & &1.slug)]}"
end
