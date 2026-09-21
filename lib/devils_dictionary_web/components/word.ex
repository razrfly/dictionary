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

  @doc """
  The word itself: the lemma, how it sounds, and every part of speech the
  index holds.

  Forms and origins left this block for the rail's disclosure in #131 Phase 2.
  They are facts about the word rather than definitions of it, and whole they
  put the first definition below the fold — `little` has 66 forms and `dog`'s
  etymology is 1,615 characters.
  """
  attr :headword, :map, required: true

  attr :choices, :list,
    default: [],
    doc: "the other words this slug names, each with an address of its own"

  attr :thing, :map, default: nil
  attr :thing_info, :string, default: nil
  attr :demo, :boolean, default: false

  def headword(assigns) do
    assigns = assign(assigns, :other, Map.new(assigns.choices, &{&1.object_id, &1}))

    ~H"""
    <div id="headword">
      <h1 class="font-display text-5xl/none text-mist-950 sm:text-6xl/none dark:text-white">
        {@headword.lemma}
      </h1>

      <%!-- One entrance to the pronunciations, not two (#133 R5). The headword
           showed three spellings and a `+9 variants` link, and the rail showed
           an "All 12 pronunciations recorded" disclosure holding the same list:
           the link was the label of a control four hundred pixels away. Now the
           label *is* the control, and it sits under the IPA it counts. A `div`
           rather than a `p` because a `details` inside a paragraph is markup a
           browser will silently take apart. --%>
      <div
        :if={@headword.pronunciations != []}
        id="pronunciations"
        class="mt-2 flex flex-wrap items-baseline gap-x-3 gap-y-1 text-lg/7 text-mist-500"
      >
        <span :for={p <- @headword.pronunciations} class="font-mono">{p.ipa}</span>
        <.pronunciation_list headword={@headword} />
      </div>

      <%!-- A slug is a label, not an identity: `love`, `Love` and `LoVe` are
           three words under one address (ADR decision 10). The page shows them
           together, and this line is where it says so — each other word is
           its own lemma, linked to its canonical address, in the place its
           part of speech already held. What was a boxed paragraph above the
           rail is a run of links in a line the page already had. --%>
      <p id="parts-of-speech" class="mt-3 text-base/7 text-mist-700 sm:text-sm/7 dark:text-mist-400">
        <span :for={{lexeme, i} <- Enum.with_index(@headword.parts)}>
          <span :if={i > 0} aria-hidden="true">·</span>
          <%= if other = other_word(@other, lexeme, @headword.lemma) do %>
            <.link
              id={"disambiguation-#{other.object_id}"}
              navigate={~p"/words/#{other.object_id}/#{other.slug}"}
              class="font-medium text-mist-950 hover:underline dark:text-white"
            >
              {other.lemma}
            </.link>
            <span class="text-mist-500">{lexeme.pos}</span>
          <% else %>
            <span class={[not lexeme.enriched? && "text-mist-500"]}>{lexeme.pos}</span>
          <% end %>
        </span>
        <span :if={@choices != []} id="disambiguation" class="sr-only">
          “{@headword.slug}” is the slug of more than one word; each linked word has an address of its own.
        </span>
      </p>

      <%!-- The one-line answer, where a reader looks for one. Wikidata's
           description of the concept the word refers to — per concept, not
           per source, and carrying a QID — was the last thing on the page.
           A source's first gloss would be a choice of source; this is not. --%>
      <p
        :if={@thing && @thing.concept.description}
        id="quick-definition"
        class="mt-3 max-w-[40ch] text-base/7 text-mist-950 text-pretty sm:text-sm/7 dark:text-white"
      >
        {@thing.concept.description}
        <span class="whitespace-nowrap text-mist-500">
          <.link
            :if={@thing.wikidata_url}
            href={@thing.wikidata_url}
            target="_blank"
            rel="noopener"
            class="hover:underline"
          >
            Wikidata <span aria-hidden="true">↗</span>
          </.link>
          <.info_link
            :if={@thing_info}
            id="quick-definition-info"
            path={@thing_info}
            label="Wikidata"
          />
        </span>
      </p>

      <p
        :if={@headword.via in [:canonical, :form]}
        id="redirected-from"
        class="mt-3 text-base/7 text-mist-500 sm:text-sm/7"
      >
        redirected from “{@headword.matched}”
      </p>

      <p
        :if={@headword.also != []}
        id="also-a-form-of"
        class="mt-2 text-base/7 text-mist-500 sm:text-sm/7"
      >
        also listed as a form of
        <.link
          :for={other <- @headword.also}
          navigate={hop(other.slug, [], @demo)}
          class="underline underline-offset-4"
        >
          {other.lemma}
        </.link>
      </p>
    </div>
    """
  end

  # The other word a lexeme is, when it is one: a choice whose lemma differs
  # from the page's. The page's own lexemes stay plain parts of speech.
  defp other_word(other, lexeme, lemma) do
    case other[lexeme.id] do
      %{lemma: ^lemma} -> nil
      choice -> choice
    end
  end

  @doc """
  Who has defined the word (#71 §2.7, W5), and how thin that makes the page.

  This was `scope_line/1`, and it said *in Animals* or *not in Animals or
  Culture or Emotions*. #77 §1 removed both halves: a scope is an operational
  selection with an internal name, so naming one in public copy is a leak, and
  the names linked a reader's word page at what is now an ops surface.

  What survives is the half a reader can act on. #71 U2 asked the sparse states
  to say *why* a page is thin rather than just be thin, and one source is the
  commonest reason — *quark* is the case it was written for: real, enriched, and
  carrying whatever the general sources happened to hold. So a single source is
  named, and several are counted, with the cards below giving the detail.
  """
  attr :sources, :list, default: []

  def source_line(assigns) do
    ~H"""
    <p
      :if={@sources != []}
      id="sources"
      class="text-base/7 font-medium text-mist-700 sm:text-sm/7 dark:text-mist-400"
    >
      <span :if={length(@sources) > 1}>Defined here by {count(@sources, "source")}</span>
      <span :if={match?([_one], @sources)} id="one-source">
        One source so far · {Enum.join(@sources, " · ")}
      </span>
    </p>
    """
  end

  defp count([_one], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

  @doc """
  A word the index knows and no source has been asked about yet (#71 §2.7).

  There are 1.3 million of these, which is the point: the lexicon is complete
  from day one and enrichment arrives scope by scope, so a bare row is a
  promise rather than a mistake.
  """
  attr :lemma, :string, required: true

  def bare_row(assigns) do
    assigns = assign(assigns, :wiktionary_url, wiktionary_url(assigns.lemma))

    ~H"""
    <div id="bare-row" class="mt-8">
      <.text class="text-mist-500">
        This word is in the index, but no definition or sense content has been absorbed for it yet.
        The page is incomplete; the index entry alone is not a definition.
      </.text>
      <div class="mt-4 flex flex-wrap gap-4">
        <.a href={@wiktionary_url} target="_blank" rel="noreferrer">
          Check Wiktionary
          <.icon
            name="hero-arrow-top-right-on-square"
            class="size-4 h-lh shrink-0 stroke-current"
          />
        </.a>
        <.a navigate={~p"/"}>Search for another word</.a>
      </div>
    </div>
    """
  end

  defp wiktionary_url(lemma),
    do: "https://en.wiktionary.org/wiki/" <> URI.encode(lemma, &URI.char_unreserved?/1)

  @doc "The trigram's nearest answers to a word the index does not hold."
  attr :suggestions, :list, default: []
  attr :demo, :boolean, default: false

  def did_you_mean(assigns) do
    ~H"""
    <p :if={@suggestions != []} id="did-you-mean" class="mt-6 text-sm/7 text-mist-500">
      did you mean
      <.link
        :for={suggestion <- @suggestions}
        id={"suggestion-#{suggestion.slug}"}
        navigate={hop(suggestion.slug, [], @demo)}
        class="mr-2 rounded-full bg-mist-950/5 px-3 py-1 text-mist-950 hover:bg-mist-950/10 dark:bg-white/10 dark:text-white dark:hover:bg-white/20"
      >
        {suggestion.lemma}
      </.link>
    </p>
    """
  end

  @doc """
  The ⓘ that opens the provenance drawer. A patch link, not a button: it works
  in the dead render, it can be right-clicked, and the URL it writes is the
  whole of the drawer's state (#71 §4).
  """
  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  def info_link(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@path}
      title={"where this came from — #{@label}"}
      class="text-sm/7 text-mist-500 hover:text-mist-950 dark:hover:text-white"
    >
      <span aria-hidden="true">ⓘ</span>
      <span class="sr-only">where this came from — {@label}</span>
    </.link>
    """
  end

  @doc """
  One source's say on the word. A 👑 author's entry renders as prose; an
  institution's senses render as a list, one block per synset where the source
  has them.
  """
  attr :card, :map, required: true
  attr :trail, :list, default: []
  attr :info, :string, default: nil
  attr :demo, :boolean, default: false

  def source_card(assigns) do
    assigns = assign(assigns, :sample?, Map.get(assigns.card, :sample?, false))

    ~H"""
    <section
      id={@card.id}
      class={[
        "rounded-xl py-6 pl-6",
        @sample? && "border-l-2 border-dashed border-amber-600/60",
        not @sample? && "border-l-2",
        not @sample? && @card.tier == :aristocracy &&
          "border-amber-600/50 bg-amber-50/40 dark:bg-amber-950/10",
        not @sample? && @card.tier != :aristocracy && "border-mist-950/10 dark:border-white/10"
      ]}
    >
      <header class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 class={["text-base/8 font-medium", tier_class(@card.tier)]}>
          <span aria-hidden="true" class="mr-1">{tier_glyph(@card.tier)}</span>
          {@card.source.name}
          <span :if={@card.year} class="font-normal text-mist-500">· {@card.year}</span>
          <span :if={@card.pos} class="font-normal text-mist-500">· {@card.pos}</span>
          <DevilsDictionaryWeb.Demo.sample_badge :if={@sample?} />
        </h2>
        <span class="flex items-baseline gap-3">
          <.link_out id={"#{@card.id}-out"} href={@card.url} label={@card.source.name} />
          <.info_link :if={@info} id={"#{@card.id}-info"} path={@info} label={@card.source.name} />
        </span>
      </header>

      <div :if={@card.thumbnail_url} class="mt-4">
        <img
          src={@card.thumbnail_url}
          alt=""
          loading="lazy"
          class="max-h-48 w-auto rounded-lg border border-mist-950/10 dark:border-white/10"
        />
      </div>

      <div :for={entry <- @card.entries} class="mt-4">
        <.document>{Phoenix.HTML.raw(entry.body_html)}</.document>
        <p :if={Map.get(entry, :authors, []) != []} class="mt-3 text-sm text-mist-500">
          By
          <.link
            :for={author <- Map.get(entry, :authors, [])}
            id={"#{@card.id}-author-#{author.id}"}
            navigate={"/entities/#{author.id}/#{DevilsDictionary.Claims.Connection.slugify(author.label)}"}
            class="mr-2 underline underline-offset-4 hover:text-amber-700"
          >
            {author.label}
          </.link>
        </p>
      </div>

      <.sense_group
        :for={{group, i} <- Enum.with_index(@card.groups)}
        card_id={@card.id}
        group={group}
        index={i}
        trail={@trail}
        demo={@demo}
      />
    </section>
    """
  end

  @doc """
  The word itself, as a column: what the page knows the size of before it
  renders anything.

  #131's sorting rule. A headword, its sound, its parts of speech, its forms,
  its origin and the index of its sources are all bounded — one line at nine
  parts of speech, eight forms and a count, one sentence and a disclosure —
  and they are the same shape on every page in the index. What a *source*
  decides the size of goes in the column beside this one.

  Not sticky, deliberately. The field pins a rail only when the rail is
  navigation; this one carries facts, and every measured site that does the
  same lets it scroll (#131 Phase 1, `docs/discovery/issue-131-how-others-do-it.md`).
  """
  attr :page, :map, required: true
  attr :sources, :list, default: []
  attr :choices, :list, default: []
  attr :thing_info, :string, default: nil
  attr :class, :string, default: nil
  attr :demo, :boolean, default: false

  def rail(assigns) do
    ~H"""
    <aside id="word-rail" class={@class}>
      <.headword
        headword={@page.headword}
        choices={@choices}
        thing={@page.thing}
        thing_info={@thing_info}
        demo={@demo}
      />
      <.stats page={@page} sources={@sources} />

      <%!-- On screen, not behind a summary (#133 R5). The Wikimedia A/B #131
           read says ~60% of readers never expand a collapsed section, and the
           origin is the most interesting thing the rail holds. What keeps it
           from pushing the source list down is the clause cut `build/2` applies
           to each one, and a cap of two open: `set` files five origins. --%>
      <div
        :if={facts?(@page.headword)}
        id="word-facts"
        class="mt-5 border-t border-mist-950/10 pt-4 dark:border-white/10"
      >
        <.forms forms={@page.headword.forms} />
        <.origin
          :for={
            {etymology, i} <-
              Enum.with_index(Enum.take(@page.headword.etymologies, WordPage.origin_cap()))
          }
          etymology={etymology}
          index={i}
        />
        <details
          :if={length(@page.headword.etymologies) > WordPage.origin_cap()}
          id="more-origins"
          class="mt-2"
        >
          <summary class="w-fit cursor-pointer text-base/7 text-mist-500 underline underline-offset-4 hover:text-mist-950 sm:text-sm/7 dark:hover:text-white">
            {length(@page.headword.etymologies) - WordPage.origin_cap()} more origins
          </summary>
          <.origin
            :for={
              {etymology, i} <-
                Enum.with_index(Enum.drop(@page.headword.etymologies, WordPage.origin_cap()))
            }
            etymology={etymology}
            index={i + WordPage.origin_cap()}
          />
        </details>
      </div>

      <nav
        :if={@page.cards != []}
        aria-label="Sources"
        class="mt-5 border-t border-mist-950/10 pt-4 dark:border-white/10"
      >
        <.source_line sources={@sources} />
        <%!-- One row per source, never one per entry (#133 R2). `build/2` did
             the grouping; this list walks `source_groups` and links the name to
             the source's first card and each part of speech to its own. Nine
             entries on *love* stay one click away under five names. --%>
        <ul role="list" class="mt-2 space-y-1 text-base/7 sm:text-sm/7">
          <li
            :for={group <- @page.source_groups}
            id={"rail-#{group.slug}"}
            class="flex flex-wrap items-baseline justify-between gap-x-2"
          >
            <%!-- No `min-w-0`: `truncate` makes the name unshrinkable, so a row
                 that cannot hold both wraps its parts of speech onto a second
                 line instead of cutting the name to "Wiktionary (Engli…". Five
                 parts of speech and a 31-character source name is `set`. --%>
            <a
              href={"#" <> group.card_id}
              class={[
                "truncate hover:underline",
                group.tier == :aristocracy && "text-amber-700 dark:text-amber-400",
                group.tier != :aristocracy && "text-mist-600 dark:text-mist-400"
              ]}
            >
              <span aria-hidden="true" class="mr-1">{tier_glyph(group.tier)}</span>{author(
                group.source
              )}
            </a>
            <%!-- The parts of speech are separate links, so the reader reaches
                 Johnson's verb without first reaching his noun. Each carries
                 the source in its accessible name: "verb" alone tells a screen
                 reader whose verb it is not. --%>
            <span class="shrink-0 text-mist-400">
              <span :for={{part, i} <- Enum.with_index(group.parts)}>
                <span :if={i > 0} aria-hidden="true">·</span>
                <a
                  id={"rail-#{part.card_id}"}
                  href={"#" <> part.card_id}
                  aria-label={"#{author(group.source)} · #{part.label}"}
                  class="hover:text-mist-950 hover:underline dark:hover:text-white"
                >
                  {part.label}
                </a>
              </span>
            </span>
          </li>
        </ul>
      </nav>
    </aside>
    """
  end

  # Pronunciations left this block for the headword, so a word with an accent
  # and nothing else no longer grows an empty one.
  defp facts?(headword),
    do: headword.forms != [] or headword.etymologies != []

  @doc """
  The three things this page can count before it renders: how many sources have
  spoken, how many senses they filed between them, and how much of the world
  came back. The kit's `stat/1` shape, at the kit's own scale.
  """
  attr :page, :map, required: true
  attr :sources, :list, default: []

  def stats(assigns) do
    assigns =
      assigns
      |> assign(:senses, Enum.reduce(assigns.page.cards, 0, &(&2 + &1.senses)))
      # A source that filed a noun and a verb is one source with two entries,
      # and a page that says "9 sources" over five names is miscounting.
      |> assign(:count, length(assigns.sources))

    ~H"""
    <div :if={@page.cards != []} id="word-stats" class="mt-5 grid grid-cols-2 gap-2">
      <div class="rounded-xl bg-mist-950/2.5 p-4 dark:bg-white/5">
        <div class="text-2xl/8 tracking-tight tabular-nums text-mist-950 dark:text-white">
          {@count}
        </div>
        <p class="mt-1 text-base/6 text-mist-700 sm:text-sm/6 dark:text-mist-400">
          {if @count == 1, do: "source", else: "sources"}
        </p>
      </div>
      <div class="rounded-xl bg-mist-950/2.5 p-4 dark:bg-white/5">
        <div class="text-2xl/8 tracking-tight tabular-nums text-mist-950 dark:text-white">
          {@senses}
        </div>
        <p class="mt-1 text-base/6 text-mist-700 sm:text-sm/6 dark:text-mist-400">
          {if @senses == 1, do: "sense", else: "senses"}
        </p>
      </div>
    </div>
    """
  end

  @doc "The forms the headword shows inline, and the disclosure holding the rest."
  attr :forms, :list, default: []

  def forms(assigns) do
    assigns =
      assigns
      |> assign(:shown, Enum.take(assigns.forms, WordPage.form_cap()))
      |> assign(:rest, Enum.drop(assigns.forms, WordPage.form_cap()))

    ~H"""
    <%!-- One line. The `+N` was a second line reading "All 12 forms", which
         spent a whole line of the rail restating the count on the line above
         it (#133 R5). `open:basis-full` gives the remainder its own line when
         it arrives rather than squeezing it into the flex track it opened
         from — `little` has 66 forms. --%>
    <div :if={@forms != []} id="forms" class="mt-2 text-base/7 text-mist-500 sm:text-sm/7">
      <span class="text-mist-700 dark:text-mist-400">forms</span>
      {Enum.join(@shown, " · ")}
      <%!-- An inline `details`, so the `+N` sits at the end of the run of forms
           and the rest continues it rather than opening a block underneath.
           A flex row cannot do this: the forms would be one unbreakable item
           and `set`'s eight of them wrapped the whole run below its label. --%>
      <details :if={@rest != []} id="form-list" class="inline">
        <summary class="inline cursor-pointer list-none underline underline-offset-4 hover:text-mist-950 dark:hover:text-white [&::-webkit-details-marker]:hidden">
          +{length(@rest)}
        </summary>
        {" · " <> Enum.join(@rest, " · ")}
      </details>
    </div>
    """
  end

  @doc """
  One origin: its first sentence, and a disclosure that says how much more
  there is. `dog`'s is 1,615 characters and `set` has five of them, so an
  origin that renders whole is a paragraph between the reader and the first
  definition.
  """
  attr :etymology, :map, required: true
  attr :index, :integer, required: true

  def origin(assigns) do
    ~H"""
    <p
      :if={@etymology.rest == nil}
      id={"etymology-#{@index}"}
      class="mt-2 max-w-2xl text-base/7 text-mist-500 sm:text-sm/7"
    >
      <span class="text-mist-700 dark:text-mist-400">origin ({Enum.join(@etymology.parts, ", ")})</span>
      {@etymology.text}
      <span :if={@etymology.source} class="text-mist-400">— {@etymology.source}</span>
    </p>
    <details :if={@etymology.rest} id={"etymology-#{@index}"} class="mt-2 max-w-2xl">
      <summary class="cursor-pointer list-none text-base/7 text-mist-500 sm:text-sm/7 [&::-webkit-details-marker]:hidden">
        <span class="text-mist-700 dark:text-mist-400">origin ({Enum.join(@etymology.parts, ", ")})</span>
        {@etymology.first}
        <span class="whitespace-nowrap text-mist-400 underline underline-offset-4">
          … {number(String.length(@etymology.rest))} more
        </span>
      </summary>
      <p class="mt-2 text-base/7 text-mist-500 sm:text-sm/7">
        {@etymology.rest}
        <span :if={@etymology.source} class="text-mist-400">— {@etymology.source}</span>
      </p>
    </details>
    """
  end

  @doc """
  Every pronunciation the word carries, with the regional tags the page has
  always built and never rendered. `love` holds nine spellings and three
  recordings; the headword shows three. A cap that says nothing is worse than
  no cap — the reader cannot tell a word with one accent from a page showing
  one.
  """
  attr :headword, :map, required: true

  def pronunciation_list(assigns) do
    ~H"""
    <details
      :if={@headword.pronunciations_all != []}
      id="pronunciation-variants"
      class="min-w-0 max-w-full text-base/7 sm:text-sm/7 open:basis-full"
    >
      <summary class="w-fit cursor-pointer list-none underline underline-offset-4 hover:text-mist-950 dark:hover:text-white [&::-webkit-details-marker]:hidden">
        +{length(@headword.pronunciations_all) - length(@headword.pronunciations)} variants
      </summary>
      <ul role="list" class="mt-2 space-y-1 text-base/7 text-mist-500 sm:text-sm/7">
        <li :for={p <- @headword.pronunciations_all} class="flex flex-wrap items-baseline gap-x-3">
          <span class="font-mono text-mist-700 dark:text-mist-400">{p.ipa || "recording"}</span>
          <span :if={p.tags != []} class="text-mist-400">{Enum.join(p.tags, ", ")}</span>
        </li>
      </ul>
    </details>
    """
  end

  @doc """
  One source, as a row that opens.

  `name="sources"` makes these an **exclusive accordion** — the HTML
  attribute, no JavaScript — so opening one closes the last. Johnson files two
  entries for `set` totalling 39,955 characters, and before this each of them
  could be open at once.

  What the row says closed is what it takes to choose it: who wrote it, when,
  how much there is, and the source's own opening words. Never *Show more*: a
  scanning reader takes in about two words, and nine identical labels carry no
  scent at all.
  """
  attr :card, :map, required: true
  attr :open, :boolean, default: false

  attr :continues, :boolean,
    default: false,
    doc:
      "whether the row above is the same source — then only the part of speech and the size are new"

  attr :trail, :list, default: []
  attr :info, :string, default: nil
  attr :demo, :boolean, default: false

  def source_row(assigns) do
    assigns = assign(assigns, :sample?, Map.get(assigns.card, :sample?, false))

    ~H"""
    <details
      id={@card.id}
      name="sources"
      open={@open}
      class={[
        "group/row",
        @sample? && "border-l-2 border-dashed border-amber-600/60 pl-4"
      ]}
    >
      <summary class={[
        "flex cursor-pointer list-none items-start justify-between gap-4 [&::-webkit-details-marker]:hidden",
        @continues && "py-3 pl-6",
        not @continues && "py-4"
      ]}>
        <div class="min-w-0 flex-1">
          <%!-- Johnson filed a noun and a verb for *love* and three entries
               for *set*. His name once, and the rows that follow it say only
               what is new about them — a screen reader still hears whose. --%>
          <h2 :if={not @continues} class={["text-base/7 font-medium", tier_class(@card.tier)]}>
            <span aria-hidden="true" class="mr-1">{tier_glyph(@card.tier)}</span>{author(@card.source)}
            <DevilsDictionaryWeb.Demo.sample_badge :if={@sample?} />
          </h2>
          <p class={[
            "text-base/6 tabular-nums text-mist-500 sm:text-sm/6",
            not @continues && "mt-0.5",
            @continues && "font-medium text-mist-700 dark:text-mist-400"
          ]}>
            <span :if={@continues} class="sr-only">{author(@card.source)} · </span>
            <span :if={not @continues and period(@card)}>{period(@card)} · </span>
            <span :if={not @continues and @card.year}>{@card.year} · </span>
            <span :if={@card.pos}>{@card.pos} · </span>
            {size(@card)}
          </p>
          <p
            :if={@card.opening}
            class="mt-1 line-clamp-1 max-w-[47rem] text-base/7 text-mist-500 group-open/row:hidden sm:text-sm/7"
          >
            {@card.opening}
          </p>
        </div>
        <span class="relative size-4 h-lh shrink-0 text-mist-400" aria-hidden="true">
          <span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 bg-current"></span>
          <span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 rotate-90 bg-current group-open/row:hidden"></span>
        </span>
      </summary>

      <div class="pb-5">
        <div :if={@card.thumbnail_url} class="mb-4">
          <img
            src={@card.thumbnail_url}
            alt=""
            loading="lazy"
            class="max-h-48 w-auto rounded-lg outline-1 -outline-offset-1 outline-mist-950/10 dark:outline-white/10"
          />
        </div>

        <.entry
          :for={{entry, i} <- Enum.with_index(@card.entries)}
          id={"#{@card.id}-entry-#{i}"}
          card_id={@card.id}
          entry={entry}
        />

        <.sense_group
          :for={{group, i} <- Enum.with_index(Enum.take(@card.groups, WordPage.group_cap()))}
          card_id={@card.id}
          group={group}
          index={i}
          trail={@trail}
          demo={@demo}
        />

        <details
          :if={length(@card.groups) > WordPage.group_cap()}
          id={"#{@card.id}-more-groups"}
          class="mt-3"
        >
          <summary class="w-fit cursor-pointer text-base/7 text-mist-500 underline underline-offset-4 hover:text-mist-950 sm:text-sm/7 dark:hover:text-white">
            {length(@card.groups) - WordPage.group_cap()} more from this source · {rest_senses(@card)} senses
          </summary>
          <.sense_group
            :for={{group, i} <- Enum.with_index(Enum.drop(@card.groups, WordPage.group_cap()))}
            card_id={@card.id}
            group={group}
            index={i + WordPage.group_cap()}
            trail={@trail}
            demo={@demo}
          />
        </details>

        <p class="mt-4 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-base/7 sm:text-sm/7">
          <.link
            :if={@card.url}
            id={"#{@card.id}-out"}
            href={@card.url}
            target="_blank"
            rel="noopener"
            class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
          >
            Read this at {author(@card.source)} <span aria-hidden="true">↗</span>
          </.link>
          <.info_link :if={@info} id={"#{@card.id}-info"} path={@info} label={@card.source.name} />
        </p>
      </div>
    </details>
    """
  end

  defp rest_senses(card) do
    card.groups |> Enum.drop(WordPage.group_cap()) |> Enum.reduce(0, &(&2 + length(&1.senses)))
  end

  # How much is behind the row. A count, never "more".
  defp size(%{senses: n}) when n > 0, do: "#{n} #{if n == 1, do: "sense", else: "senses"}"
  defp size(%{chars: n}) when n > 0, do: "#{number(n)} characters"
  defp size(_card), do: ""

  # A period, for a source old enough that its date is a warning as much as a
  # fact. Le Robert heads its 1690 Furetière *17e siècle*; the reader learns
  # what kind of text is coming before reading a word of it, which is the
  # cheapest guard against reading an archaic sense as the current one.
  defp period(%{year: year, tier: :aristocracy}) when is_integer(year) and year < 2000 do
    century = div(year - 1, 100) + 1

    suffix =
      case {rem(century, 10), rem(century, 100)} do
        {1, n} when n != 11 -> "st"
        {2, n} when n != 12 -> "nd"
        {3, n} when n != 13 -> "rd"
        _ -> "th"
      end

    "#{century}#{suffix} century"
  end

  defp period(_card), do: nil

  @doc "One prose entry: its opening, and the disclosure holding the rest of the original."
  attr :id, :string, required: true
  attr :card_id, :string, required: true
  attr :entry, :map, required: true

  def entry(assigns) do
    ~H"""
    <div id={@id} class="mt-4 max-w-[47rem] first:mt-0">
      <.document>{Phoenix.HTML.raw(@entry.preview_html)}</.document>
      <details :if={@entry.rest_html} id={"#{@id}-rest"} class="group/entry mt-2">
        <summary class="w-fit cursor-pointer list-none text-base/7 text-mist-500 hover:text-mist-950 sm:text-sm/7 dark:hover:text-white [&::-webkit-details-marker]:hidden">
          <span class="underline underline-offset-4 group-open/entry:hidden">
            Read the rest of this entry · {number(@entry.rest_chars)} characters
          </span>
          <span class="underline underline-offset-4 not-group-open/entry:hidden">Fold this entry</span>
        </summary>
        <.document class="mt-4">{Phoenix.HTML.raw(@entry.rest_html)}</.document>
      </details>
      <p :if={Map.get(@entry, :authors, []) != []} class="mt-3 text-base/7 text-mist-500 sm:text-sm">
        By
        <.link
          :for={author <- Map.get(@entry, :authors, [])}
          id={"#{@card_id}-author-#{author.id}"}
          navigate={"/entities/#{author.id}/#{DevilsDictionary.Claims.Connection.slugify(author.label)}"}
          class="mr-2 underline underline-offset-4 hover:text-amber-700"
        >
          {author.label}
        </.link>
      </p>
    </div>
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
  attr :demo, :boolean, default: false

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
          demo={@demo}
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
            demo={@demo}
          />
        </ol>
      </details>

      <.chain
        :if={@group.chain != []}
        id={"#{@id}-chain"}
        chain={@group.chain}
        trail={@trail}
        demo={@demo}
      />
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
  attr :demo, :boolean, default: false

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
          demo={@demo}
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
  attr :demo, :boolean, default: false

  def chain(assigns) do
    ~H"""
    <p id={@id} class="mt-2 flex flex-wrap items-center gap-x-2 text-sm/7">
      <span class="text-mist-500">broader</span>
      <span :for={{step, i} <- Enum.with_index(@chain)} class="flex items-center gap-x-2">
        <span :if={i > 0} aria-hidden="true" class="text-mist-400">›</span>
        <.link
          navigate={hop(step.slug, @trail, @demo)}
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
  attr :demo, :boolean, default: false

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
        demo={@demo}
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
            demo={@demo}
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
  attr :demo, :boolean, default: false

  def chip(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={hop(@chip.slug, @trail, @demo)}
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
  attr :demo, :boolean, default: false

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
          navigate={hop(step.slug, Enum.take(@trail, i), @demo)}
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
  attr :demo, :boolean, default: false

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
        demo={@demo}
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
  def hop(slug, trail, demo? \\ false) do
    trail |> query(demo?) |> to_path(slug)
  end

  @doc """
  The path that opens the ⓘ drawer for `ref` — the same word, the same trail,
  one parameter more — or closes it when `ref` is `nil`.

  The slug is the one in the address bar rather than the canonical one: a
  reader who typed *oysters* stays on *oysters*, keeps the *redirected from*
  line, and gets a URL that reproduces exactly what they are looking at.
  """
  def info_path(slug, trail, ref \\ nil, demo? \\ false) do
    trail |> query(demo?, ref) |> to_path(slug)
  end

  # `?demo=1` rides along with the trail rather than being dropped at the first
  # click. A mode that survives one navigation is not a mode — and the drawer's
  # own close link would have been the thing that turned it off.
  defp query(trail, demo?, ref \\ nil) do
    [
      trail: trail != [] && Enum.map_join(trail, ",", & &1.slug),
      provenance: ref,
      demo: demo? && "1"
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, false, ""] end)
  end

  defp to_path([], slug), do: ~p"/define/#{slug}"
  defp to_path(query, slug), do: ~p"/define/#{slug}?#{query}"
end
