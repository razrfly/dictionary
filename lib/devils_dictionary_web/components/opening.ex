defmodule DevilsDictionaryWeb.Opening do
  @moduledoc """
  The curated opening section (#156): a sourced lead quoted large, up to three
  highlights, and a disclosure saying how they were chosen. It renders a
  `DevilsDictionary.Curation.Opening` and decides nothing — no query, no
  selection, no provider name. It branches on the lead's `policy`, each
  item's `register` and `kind`, each reason's `kind` and each credit's
  `required?`, which are data.

  The #159 V1 *epigraph* sketch, made honest about what it shows and compact
  enough to leave the Definitions in reach:

    * **What is on the page by default** is the source's own words (the lead
      and every quotation in the display serif with hanging quotation marks,
      verbatim), what kind of text they are (*Satire*, *Sourced definition*,
      *Sourced quotation*), who made them and where, the continuation to the
      whole entry, every credit a source's terms require, and — at the top —
      that a development fixture was selected by an AI model and not
      reviewed by a person.
    * **What is one step away**, in a disclosure named for its question (*Why
      this leads*, *Why this is here*), is everything said *about* an item:
      its intended meaning, the editorial preference or source record behind
      it, an AI-generated or human note with its author and review state, and
      locators that no licence requires on the page. Each disclosure is one
      level deep; none is nested.
    * **How this was chosen** holds the provenance: who selected it, whether
      anyone reviewed it, the curation configuration (none, for a fixture —
      so no panel ran and no votes exist), anything withheld, and every exact
      revision linked to its evidence.
    * **Nothing is promised that is not there.** No heading on screen (the
      headword is the heading), no empty slots, no loading state. The
      highlights take one, two or three columns by how many there are.
    * **An exemplar is someone's claim, accepted** (#212). Its tile names the
      subject and the meaning it was cited for; its disclosure holds the
      nominator's reason and the six stages the examples card shows
      (`DevilsDictionaryWeb.ExampleProvenance.rows/1`), so the two cannot
      disagree about one claim.

  Disclosures keep their `open` state across LiveView patches with
  `JS.ignore_attributes/1`. The section is placed by `WordLive`: in the column
  above the Definitions on a desktop, directly after the headword — in the
  document, not only on screen — on a phone.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Curation.Opening, as: Composition
  alias DevilsDictionaryWeb.{ExampleProvenance, Quotation, SourceBadge}

  attr :opening, Composition, required: true
  attr :class, :any, default: nil
  attr :mode, :atom, default: :public, doc: "the reading mode, for subject links"

  def section(assigns) do
    ~H"""
    <section
      id="opening"
      aria-labelledby="opening-heading"
      class={["flex min-w-0 flex-col gap-8", @class]}
    >
      <h2 id="opening-heading" class="sr-only">Selected for this word</h2>

      <p
        :if={@opening.origin == :fixture}
        id="opening-fixture"
        class="-mb-3 w-fit rounded-lg border border-dashed border-amber-600/60 px-3 py-0.5 text-base/6 text-pretty text-amber-800 sm:text-sm/6 dark:text-amber-200"
      >
        Development fixture · {fixture_status(@opening.review)} · not published
      </p>

      <.lead :if={@opening.lead} lead={@opening.lead} />

      <div :if={@opening.highlights != []} class="@container">
        <ul
          id="opening-highlights"
          role="list"
          class={[
            "grid grid-cols-1 gap-8",
            length(@opening.highlights) == 2 && "@xl:grid-cols-2 @xl:gap-6",
            length(@opening.highlights) == 3 && "@2xl:grid-cols-3 @2xl:gap-6"
          ]}
        >
          <.highlight
            :for={highlight <- @opening.highlights}
            highlight={highlight}
            stacked={length(@opening.highlights) > 1}
            mode={@mode}
          />
        </ul>
      </div>

      <.about opening={@opening} mode={@mode} />
    </section>
    """
  end

  # ── the lead ─────────────────────────────────────────────────────────────

  attr :lead, :map, required: true

  defp lead(assigns) do
    ~H"""
    <div id="opening-lead" class="flex flex-col gap-4">
      <figure class="flex max-w-[44rem] flex-col gap-4">
        <blockquote
          cite={@lead.links[:source]}
          class="font-display text-3xl/10 text-pretty text-mist-950 sm:text-4xl/12 dark:text-white"
        >
          <p
            id="opening-lead-text"
            class="relative before:absolute before:-translate-x-full before:content-['\201C'] after:content-['\201D']"
            phx-no-format
          >{raw(@lead.excerpt.html)}</p>
        </blockquote>
        <figcaption class="flex flex-wrap items-center gap-x-3 gap-y-2 text-base/7 sm:text-sm/7">
          <.register id="opening-lead-register" register={@lead.register} />
          <span class={["inline-flex items-center gap-2 font-medium", tier_text(@lead.source.tier)]}>
            <SourceBadge.badge source={@lead.source} decorative />{@lead.author}
          </span>
          <cite :if={@lead.work} class="text-mist-600 dark:text-mist-400">{@lead.work}</cite>
          <span :if={@lead.entry[:year]} class="text-mist-600 tabular-nums dark:text-mist-400">
            {@lead.entry.year}
          </span>
          <.link
            :if={@lead.links[:card_id]}
            id="opening-lead-entry"
            href={"#" <> @lead.links.card_id}
            phx-click={open_card(@lead.links.card_id)}
            class="rounded-sm text-mist-600 underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:text-mist-400 dark:hover:text-white dark:focus-visible:outline-white"
          >
            <%= if @lead.excerpt.clipped? do %>
              Read the whole entry
              <span class="tabular-nums">· {number(@lead.excerpt.chars)} characters</span>
            <% else %>
              The entry among the definitions
            <% end %>
            <span aria-hidden="true">↓</span>
          </.link>
        </figcaption>
      </figure>

      <.credit_line id="opening-lead-credits" credits={@lead.credits} class="max-w-[44rem]" />

      <.why id="opening-lead-why" summary="Why this leads" reasons={@lead.reasons}>
        <.particulars
          id="opening-lead"
          meaning={@lead.meaning}
          register={@lead.register}
          reasons={@lead.reasons}
          credits={@lead.credits}
        />
      </.why>
    </div>
    """
  end

  # ── highlights ───────────────────────────────────────────────────────────

  attr :highlight, :map, required: true
  attr :mode, :atom, default: :public

  attr :stacked, :boolean,
    default: true,
    doc: "whether the tile may stack its picture above its text when its column is wide"

  defp highlight(%{highlight: %{kind: :artwork}} = assigns) do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">Artwork: {@highlight.title}</h3>
      <div class={["flex gap-4", @stacked && "@2xl:flex-col @2xl:gap-3"]}>
        <div class={[
          "w-24 shrink-0 self-start overflow-hidden rounded-lg bg-mist-950/5 outline-1 -outline-offset-1 outline-black/5 dark:bg-white/5 dark:outline-white/10",
          @stacked && "@2xl:w-full",
          not @stacked && "@xl:w-40"
        ]}>
          <img
            src={@highlight.image.url}
            alt={@highlight.image.alt}
            decoding="async"
            class={["aspect-4/5 w-full object-contain", @stacked && "@2xl:aspect-square"]}
          />
        </div>
        <div class="min-w-0">
          <p aria-hidden="true" class="text-base/6 text-mist-500 sm:text-sm/6">Artwork</p>
          <p class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
            <.link
              id={"#{@id}-title"}
              navigate={entity_path(@highlight, @mode)}
              class="rounded-sm hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:focus-visible:outline-white"
            >
              {@highlight.title}
            </.link>
          </p>
          <p
            :if={@highlight.creator || @highlight.date}
            class="text-base/6 text-mist-600 sm:text-sm/6 dark:text-mist-400"
          >
            {Enum.join(Enum.reject([@highlight.creator, @highlight.date], &is_nil/1), " · ")}
          </p>
        </div>
      </div>

      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />

      <.why id={"#{@id}-why"} summary="Why this is here" reasons={@highlight.reasons}>
        <.particulars
          id={@id}
          meaning={@highlight.meaning}
          register={@highlight.register}
          reasons={@highlight.reasons}
          credits={@highlight.credits}
        />
      </.why>
    </li>
    """
  end

  defp highlight(%{highlight: %{kind: :quotation}} = assigns) do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">Quotation: {@highlight.quotation.citation}</h3>
      <figure class="flex flex-col gap-3 rounded-xl bg-mist-950/2.5 p-5 dark:bg-white/5">
        <p class="flex flex-wrap items-center gap-2">
          <.register id={"#{@id}-register"} register={@highlight.register} />
          <span
            :if={@highlight.quotation.provenance}
            id={"#{@id}-provenance"}
            class={[
              "rounded-full px-2 py-0.5 text-sm/5",
              provenance_class(@highlight.quotation.provenance)
            ]}
          >
            {Quotation.label(@highlight.quotation.provenance)}
          </span>
        </p>
        <blockquote class="font-display text-2xl/8 text-pretty text-mist-950 dark:text-white">
          <p
            id={"#{@id}-text"}
            class="relative before:absolute before:-translate-x-full before:content-['\201C'] after:content-['\201D']"
            phx-no-format
          >{verse(@highlight.quotation.text)}</p>
        </blockquote>
        <figcaption
          :if={@highlight.quotation.citation}
          id={"#{@id}-citation"}
          class="text-base/6 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400"
        >
          {@highlight.quotation.citation}
        </figcaption>
      </figure>

      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />

      <.why id={"#{@id}-why"} summary="Why this is here" reasons={@highlight.reasons}>
        <.particulars
          id={@id}
          meaning={@highlight.meaning}
          register={@highlight.register}
          reasons={@highlight.reasons}
          credits={@highlight.credits}
        />
      </.why>
    </li>
    """
  end

  # An exemplar (#212): the subject someone cited, and the meaning they cited
  # it for. Everything said *about* it — the nominator's reason, who
  # nominated and reviewed it, how it came to be here — is one step away,
  # in the stages the examples card draws for the same claim.
  defp highlight(%{highlight: %{kind: :exemplar}} = assigns) do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">Example: {@highlight.title}, {example_noun(@highlight.subject)}</h3>
      <div class="min-w-0">
        <p aria-hidden="true" class="text-base/6 text-mist-500 sm:text-sm/6">
          {example_kind(@highlight.subject)}
        </p>
        <p class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
          <.link
            id={"#{@id}-title"}
            navigate={subject_path(@highlight, @mode)}
            class="rounded-sm hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:focus-visible:outline-white"
          >
            {@highlight.title}
          </.link>
        </p>
        <p
          id={"#{@id}-cited"}
          class="text-base/6 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400"
        >
          cited as an example of <.meaning meaning={@highlight.meaning} />
        </p>
      </div>

      <%!-- A quotation or passage is shown by the words its claim was
           accepted on. They are a source's, so they are quoted under the
           quotation register, with the credit and licence its terms
           require, as the quotation tile quotes. --%>
      <figure
        :if={@highlight.subject.html}
        class="flex flex-col gap-3 rounded-xl bg-mist-950/2.5 p-5 dark:bg-white/5"
      >
        <p class="flex flex-wrap items-center gap-2">
          <.register id={"#{@id}-register"} register={@highlight.register} />
        </p>
        <blockquote
          id={"#{@id}-text"}
          cite={@highlight.links[:source]}
          class="flex flex-col gap-3 font-display text-2xl/8 text-pretty text-mist-950 dark:text-white"
        >
          {raw(@highlight.subject.html)}
        </blockquote>
      </figure>

      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />

      <.why id={"#{@id}-why"} summary="Why this is here" reasons={@highlight.reasons}>
        <div class="flex flex-col gap-3">
          <.particulars
            id={@id}
            meaning={@highlight.meaning}
            register={@highlight.register}
            reasons={@highlight.reasons}
            credits={@highlight.credits}
          />
          <dl id={"#{@id}-stages"} class="flex flex-col gap-2 text-base/6 sm:text-sm/6">
            <div id={"#{@id}-rationale"}>
              <dt class="inline font-medium text-mist-950 dark:text-white">Reason given</dt>
              <dd class="inline text-pretty text-mist-700 dark:text-mist-300">
                “{@highlight.claim.rationale}”
              </dd>
            </div>
            <div
              :for={{key, label, text} <- ExampleProvenance.rows(@highlight.provenance)}
              id={"#{@id}-stage-#{key}"}
            >
              <dt class="inline font-medium text-mist-950 dark:text-white">{label}</dt>
              <dd class="inline text-pretty text-mist-700 dark:text-mist-300">{text}</dd>
            </div>
          </dl>
        </div>
      </.why>
    </li>
    """
  end

  # ── credits, the disclosure, and what is in it ───────────────────────────

  attr :id, :string, required: true
  attr :credits, :list, default: []
  attr :class, :any, default: nil

  # The credits a source's terms require, on the page: one run of text, every
  # credit whole and unclamped, linked where its source names a page.
  defp credit_line(assigns) do
    assigns = assign(assigns, :required, Enum.filter(assigns.credits, & &1.required?))

    ~H"""
    <dl
      :if={@required != []}
      id={@id}
      class={["text-base/6 text-mist-600 sm:text-sm/6 dark:text-mist-400", @class]}
    >
      <div
        :for={credit <- @required}
        class="inline after:mx-1.5 after:content-['·'] last:after:content-none"
      >
        <dt class="inline font-medium text-mist-700 dark:text-mist-300">{credit.label}</dt>
        <dd class="inline break-words">
          <.credit_text credit={credit} />
        </dd>
      </div>
    </dl>
    """
  end

  attr :credit, :map, required: true

  defp credit_text(%{credit: %{href: href}} = assigns) when is_binary(href) do
    ~H"""
    <a
      href={@credit.href}
      target="_blank"
      rel="noreferrer"
      class="rounded-sm underline decoration-mist-950/20 underline-offset-4 hover:text-mist-950 hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:decoration-white/20 dark:hover:text-white dark:focus-visible:outline-white"
    >{@credit.text}<span class="sr-only"> (opens in a new tab)</span></a>
    """
  end

  defp credit_text(assigns), do: ~H"<span>{@credit.text}</span>"

  attr :id, :string, required: true
  attr :summary, :string, required: true
  attr :reasons, :list, default: []
  slot :inner_block, required: true

  # One disclosure per item, named for the question it answers. A reader who
  # does not open it still learns that an AI-generated note is inside. On a
  # phone its summary is a 44 px tap target, as the examples card's is.
  defp why(assigns) do
    assigns = assign(assigns, :generated?, Enum.any?(assigns.reasons, &generated?/1))

    ~H"""
    <details id={@id} phx-mounted={JS.ignore_attributes(["open"])} class="group/why">
      <summary class="flex min-h-11 w-fit cursor-pointer list-none flex-wrap items-center gap-x-2 rounded-sm text-base/7 text-mist-600 hover:text-mist-950 sm:min-h-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 sm:text-sm/7 dark:text-mist-400 dark:hover:text-white dark:focus-visible:outline-white [&::-webkit-details-marker]:hidden">
        <span class="underline decoration-mist-950/20 underline-offset-4 dark:decoration-white/20">
          {@summary}
        </span>
        <span :if={@generated?} class="text-mist-500">· includes an AI-generated note</span>
        <.icon
          name="hero-chevron-down-mini"
          class="size-5 text-mist-400 group-open/why:rotate-180 sm:size-4"
        />
      </summary>
      <div class="mt-3 border-l-2 border-mist-950/10 pl-4 dark:border-white/10">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :meaning, :map, required: true
  attr :register, :atom, default: nil
  attr :reasons, :list, default: []
  attr :credits, :list, default: []

  defp particulars(assigns) do
    assigns =
      assigns
      |> assign(:stated, Enum.reject(assigns.reasons, &(&1.kind == :editorial)))
      |> assign(:notes, Enum.filter(assigns.reasons, &(&1.kind == :editorial)))
      |> assign(:details, Enum.reject(assigns.credits, & &1.required?))

    ~H"""
    <div class="flex flex-col gap-3 text-base/6 sm:text-sm/6">
      <dl class="flex flex-col gap-2">
        <div id={"#{@id}-meaning"}>
          <dt class="inline font-medium text-mist-950 dark:text-white">Meaning</dt>
          <dd class="inline text-mist-700 dark:text-mist-300">
            <.meaning meaning={@meaning} />
          </dd>
        </div>
        <div :if={@register} id={"#{@id}-register-note"}>
          <dt class="inline font-medium text-mist-950 dark:text-white">Kind of text</dt>
          <dd class="inline text-mist-700 text-pretty dark:text-mist-300">
            {register_note(@register)}
          </dd>
        </div>
        <div :for={{reason, i} <- Enum.with_index(@stated)} id={"#{@id}-reason-#{i}"}>
          <dt class="inline font-medium text-mist-950 dark:text-white">{reason_label(reason)}</dt>
          <dd class="inline text-mist-700 text-pretty dark:text-mist-300">{reason.text}</dd>
        </div>
        <div :for={credit <- @details} id={"#{@id}-detail-#{credit.role}"}>
          <dt class="inline font-medium text-mist-950 dark:text-white">{credit.label}</dt>
          <dd class="inline break-words text-mist-700 dark:text-mist-300">
            <.credit_text credit={credit} />
          </dd>
        </div>
      </dl>

      <div
        :for={{note, i} <- Enum.with_index(@notes)}
        id={"#{@id}-note-#{i}"}
        class="flex flex-col gap-1 rounded-lg bg-amber-50 px-3 py-2 dark:bg-amber-400/10"
      >
        <p class="font-medium text-mist-950 dark:text-white">{reason_label(note)}</p>
        <p class="text-mist-700 text-pretty dark:text-mist-300">{note.text}</p>
        <p id={"#{@id}-note-#{i}-author"} class="text-mist-600 dark:text-mist-400">
          {attribution(note)}
        </p>
      </div>
    </div>
    """
  end

  attr :meaning, :map, required: true

  # A sense's gloss is its source's words, so it is quoted; a word and part
  # of speech is ours, so it is not. Either links to where the page shows it,
  # and opens the card it is in.
  defp meaning(%{meaning: %{kind: :sense}} = assigns) do
    ~H"""
    <.meaning_link anchor={@meaning.anchor}>“{@meaning.label}”</.meaning_link><span :if={
      @meaning.source
    }> · {@meaning.source.name}</span>
    """
  end

  defp meaning(assigns) do
    ~H"""
    <.meaning_link anchor={@meaning.anchor}><em>{@meaning.label}</em></.meaning_link><span :if={
      @meaning.part_of_speech
    }>, {@meaning.part_of_speech}</span>
    """
  end

  attr :anchor, :string, default: nil
  slot :inner_block, required: true

  defp meaning_link(%{anchor: "#" <> card_id} = assigns) do
    assigns = assign(assigns, :card_id, card_id)

    ~H"""
    <a
      href={@anchor}
      phx-click={open_card(@card_id)}
      class="rounded-sm underline decoration-mist-950/20 underline-offset-4 hover:text-mist-950 hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:decoration-white/20 dark:hover:text-white dark:focus-visible:outline-white"
    >{render_slot(@inner_block)}</a>
    """
  end

  defp meaning_link(assigns), do: ~H"<span>{render_slot(@inner_block)}</span>"

  attr :id, :string, required: true
  attr :register, :atom, default: nil

  # What kind of text this is, on the page: satire is labelled satire.
  defp register(%{register: nil} = assigns), do: ~H""

  defp register(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "rounded-full px-2 py-0.5 text-sm/5",
        @register == :satire &&
          "bg-amber-100 text-amber-900 dark:bg-amber-400/15 dark:text-amber-200",
        @register != :satire && "bg-mist-950/5 text-mist-700 dark:bg-white/10 dark:text-mist-300"
      ]}
    >
      {register_label(@register)}
    </span>
    """
  end

  # ── how it was chosen ────────────────────────────────────────────────────

  attr :opening, Composition, required: true
  attr :mode, :atom, default: :public

  defp about(assigns) do
    ~H"""
    <details
      id="opening-about"
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group/about border-t border-mist-950/10 pt-4 dark:border-white/10"
    >
      <summary class="flex cursor-pointer list-none items-start justify-between gap-4 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-mist-950 dark:focus-visible:outline-white [&::-webkit-details-marker]:hidden">
        <span class="flex min-w-0 flex-col">
          <span class="text-base/7 font-medium text-mist-950 sm:text-sm/7 dark:text-white">
            How this was chosen
          </span>
          <span
            id="opening-about-summary"
            class="text-base/6 text-mist-600 sm:text-sm/6 dark:text-mist-400"
          >
            {summary(@opening)}
          </span>
        </span>
        <span class="relative mt-1.5 size-4 shrink-0 text-mist-400" aria-hidden="true">
          <span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 bg-current"></span>
          <span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 rotate-90 bg-current group-open/about:hidden"></span>
        </span>
      </summary>

      <div class="mt-4 flex flex-col gap-6 pb-2 text-base/6 sm:text-sm/6">
        <dl class="flex flex-col gap-3">
          <.about_row id="opening-about-selection" label="Selection">
            {selection(@opening)}
          </.about_row>
          <.about_row id="opening-about-selected" label="Selected by">
            {selector(@opening.review.selected_by)}{if @opening.review.selected_on,
              do: " · #{date(@opening.review.selected_on)}"}
          </.about_row>
          <.about_row id="opening-about-reviewed" label="Reviewed by">
            <%= if @opening.review.reviewed_by do %>
              {@opening.review.reviewed_by}{if @opening.review.reviewed_on,
                do: " · #{date(@opening.review.reviewed_on)}"}
            <% else %>
              Nobody yet. No person has reviewed this selection.
            <% end %>
          </.about_row>
          <.about_row id="opening-about-configuration" label="Configuration">
            <%= if configuration = @opening.configuration do %>
              {configuration.slug}, version {configuration.version} · resolved as {configuration.resolution_reason} under resolution policy {configuration.resolution_policy_version}
            <% else %>
              None. A development fixture resolves no curation configuration, so no persona panel ran and there are no votes or panel decisions to show.
            <% end %>
          </.about_row>
          <.about_row id="opening-about-withheld" label="Withheld">
            <%= if @opening.withheld == [] do %>
              Nothing. Every selected item is still eligible.
            <% else %>
              <ul role="list" class="flex flex-col gap-1">
                <li :for={item <- @opening.withheld}>
                  {withheld_label(item)}: {withheld_reason(item.reason)}. Nothing was put in its place.
                </li>
              </ul>
            <% end %>
          </.about_row>
        </dl>

        <div>
          <h3 class="font-medium text-mist-950 dark:text-white">Exact revisions</h3>
          <ul
            id="opening-about-revisions"
            role="list"
            class="mt-2 flex flex-col gap-1 text-mist-700 dark:text-mist-300"
          >
            <li :if={@opening.lead} id="opening-about-revision-lead">
              Lead · {reference(@opening.lead.reference)} ·
              <.link
                navigate={evidence_path(@opening.lead.reference)}
                class="rounded-sm underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
              >
                evidence
              </.link>
            </li>
            <li
              :for={highlight <- @opening.highlights}
              id={"opening-about-revision-#{highlight.position}"}
            >
              Highlight {highlight.position} · {reference(highlight.reference)} ·
              <.link
                navigate={inspect_path(highlight, @mode)}
                class="rounded-sm underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
              >
                {inspect_label(highlight.kind)}
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp about_row(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-x-6 gap-y-0.5 sm:grid-cols-[9rem_minmax(0,1fr)]">
      <dt class="font-medium text-mist-950 dark:text-white">{@label}</dt>
      <dd id={@id} class="text-mist-700 text-pretty dark:text-mist-300">
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The card's `open` is DOM state inside an ignored slab, so the page cannot
  # re-render it open; the continuation opens it where it stands, and the
  # anchor then scrolls to it. `name="sources"` closes whichever was open.
  defp open_card(card_id), do: JS.set_attribute({"open", ""}, to: "#" <> card_id)

  defp tier_text(:aristocracy), do: "text-amber-700 dark:text-amber-400"
  defp tier_text(_tier), do: "text-mist-700 dark:text-mist-300"

  defp register_label(:satire), do: "Satire"
  defp register_label(:definition), do: "Sourced definition"
  defp register_label(:quotation), do: "Sourced quotation"

  defp register_note(:satire),
    do:
      "Satire, quoted exactly. Exact quotation shows the source says this; it does not make it literally true."

  defp register_note(:definition), do: "A sourced definition, quoted exactly from its source."

  defp register_note(:quotation),
    do:
      "A sourced quotation, quoted exactly as its source cites it. Accurate quotation is not evidence that what it says is true."

  defp reason_label(%{kind: :policy}), do: "Editorial preference"
  defp reason_label(%{kind: :source_match}), do: "Source record"
  defp reason_label(%{kind: :editorial, author: %{kind: :model}}), do: "AI-generated note"
  defp reason_label(%{kind: :editorial, author: %{kind: :human}}), do: "Editorial note"
  defp reason_label(_reason), do: "Note"

  defp generated?(%{kind: :editorial, author: %{kind: :model}}), do: true
  defp generated?(_reason), do: false

  defp attribution(%{author: author, reviewed_by: reviewed_by}) do
    review = if reviewed_by, do: "reviewed by #{reviewed_by}", else: "not reviewed by a person"
    "#{by(author)} · #{review}"
  end

  # Who wrote or chose something, saying what they are: a model's work is
  # labelled generated wherever its name appears (#156, #193).
  defp by(%{kind: :model, label: label}), do: "Generated by #{label}, an AI model"
  defp by(%{kind: :human, label: label}), do: "Written by #{label}"
  defp by(%{label: label}), do: "Written for a development fixture by #{label}"
  defp by(_none), do: "Author not recorded"

  defp selector(%{kind: :model, label: label}), do: "#{label}, an AI model"
  defp selector(%{label: label}), do: label
  defp selector(_none), do: "Not recorded"

  # What the fixture label says about who chose it. Visible on the page, not
  # only in a disclosure, because it is the one thing a reader must not miss.
  defp fixture_status(%{selected_by: %{kind: :model}, reviewed_by: nil}),
    do: "AI-selected, not reviewed by a person"

  defp fixture_status(%{reviewed_by: reviewer}) when is_binary(reviewer),
    do: "reviewed by #{reviewer}"

  defp fixture_status(_review), do: "not reviewed by a person"

  defp summary(%{review: review} = opening) do
    selected =
      if review.selected_by,
        do: "Selected by #{selector(review.selected_by)}",
        else: "Selector not recorded"

    reviewed =
      case review.state do
        :approved -> "approved by #{review.reviewed_by}"
        :reviewed -> "reviewed by #{review.reviewed_by}"
        _ -> "not reviewed"
      end

    origin = if opening.origin == :fixture, do: " · development fixture", else: ""
    "#{selected} · #{reviewed}#{origin}"
  end

  defp selection(%{composition: nil, origin: origin}),
    do: if(origin == :fixture, do: "An unnamed development fixture", else: "Unnamed")

  defp selection(%{composition: %{id: id, version: version}, origin: :fixture}),
    do: "#{id}, version #{version}: a development fixture, not a published composition"

  defp selection(%{composition: %{id: id, version: version}}),
    do: "Composition #{id}, version #{version}"

  defp withheld_label(%{role: :lead}), do: "The lead"
  defp withheld_label(%{role: :highlight, position: position}), do: "Highlight #{position}"

  defp withheld_reason(:revision_not_current),
    do: "its exact source revision is no longer current"

  defp withheld_reason(:revision_inactive), do: "its source revision was withdrawn"
  defp withheld_reason(:excerpt_changed), do: "the words it quotes have changed since selection"
  defp withheld_reason(:excerpt_unpinned), do: "the selection does not pin the words it quotes"
  defp withheld_reason(:display_not_allowed), do: "its source may not be displayed"
  defp withheld_reason(:source_inactive), do: "its source is switched off"
  defp withheld_reason(:object_inactive), do: "it has left the registry"
  defp withheld_reason(:catalog_changed), do: "its catalog has changed since it was selected"

  defp withheld_reason(:catalog_drift),
    do: "what would be shown no longer matches the catalog row that was selected"

  defp withheld_reason(:priority_source_available),
    do: "a Devil’s Dictionary entry applies here, and only that entry may lead"

  defp withheld_reason(:priority_source_missing),
    do: "a Devil’s Dictionary entry applies here, and the selection names no lead"

  defp withheld_reason(:not_on_page), do: "it is not among this page’s definitions"
  defp withheld_reason(:over_limit), do: "an opening shows at most three highlights"
  defp withheld_reason(:duplicate), do: "it repeats an earlier highlight"
  defp withheld_reason(:meaning_off_page), do: "its meaning is not on this page"

  defp withheld_reason(:meaning_mismatch),
    do: "it no longer publicly defines the meaning it was selected for"

  defp withheld_reason(:quotation_not_found), do: "its line is no longer filed under that meaning"
  defp withheld_reason(:no_image), do: "its image is no longer available"

  # An exemplar's claim (#212). One sentence for every way a claim falls
  # short, so a withheld nomination is never described: not whom it names,
  # not that it waits for review, not that a reviewer turned it down.
  defp withheld_reason(reason)
       when reason in [
              :claim_not_found,
              :claim_not_accepted,
              :claim_not_visible,
              :claim_not_current,
              :claim_deleted
            ],
       do: "it is not an example a reviewer has accepted"

  defp withheld_reason(:claim_context_changed),
    do: "what it shows has changed since a reviewer accepted it"

  defp withheld_reason(:meaning_off_scope),
    do: "its meaning is not one of the words it was selected for"

  defp withheld_reason(:object_retired), do: "it has left the registry"

  defp withheld_reason(:unsupported_subject),
    do: "the opening does not show that kind of example yet"

  defp withheld_reason(_reason), do: "it could not be resolved"

  # An exemplar names the claim it shows as well as the thing.
  defp reference(%{assertion_revision_id: claim} = ref) when is_integer(claim) do
    words = if ref.content_revision_id, do: ", revision #{ref.content_revision_id}", else: ""
    "#{ref.object_kind} #{ref.object_id}#{words}, claim revision #{claim}"
  end

  defp reference(%{object_kind: :content} = ref),
    do: "content #{ref.object_id}, revision #{ref.content_revision_id}#{locator(ref.locator)}"

  defp reference(%{object_kind: :sense} = ref),
    do: "sense #{ref.object_id}, revision #{ref.sense_revision_id}#{locator(ref.locator)}"

  defp reference(
         %{object_kind: :entity, catalog: %{manifest: manifest, checksum: checksum}} = ref
       ),
       do: "work #{ref.object_id}, catalog #{manifest} @ #{String.slice(checksum, 0, 12)}"

  defp reference(ref), do: "#{ref.object_kind} #{ref.object_id}"

  defp locator(%{kind: :sentences, count: 1}), do: ", first sentence"
  defp locator(%{kind: :sentences, count: n}), do: ", first #{n} sentences"
  defp locator(%{kind: :quotation, fingerprint: fp}), do: ", line #{String.slice(fp, 0, 12)}"
  defp locator(_locator), do: ""

  defp inspect_label(:artwork), do: "work"
  defp inspect_label(:exemplar), do: "claim"
  defp inspect_label(_kind), do: "evidence"

  defp example_kind(subject), do: "Example · #{example_noun(subject)}"

  # What the example is, in words: a quotation or passage, or the entity's
  # kind as the registry records it.
  defp example_noun(%{kind: :content, content_kind: kind}) when not is_nil(kind),
    do: humanize(kind)

  defp example_noun(%{entity_kind: kind}) when kind not in [nil, :other], do: humanize(kind)
  defp example_noun(_subject), do: "thing"

  defp humanize(kind), do: kind |> to_string() |> String.replace("_", " ")

  defp evidence_path(%{object_kind: :content, content_revision_id: id}) when is_integer(id),
    do: ~p"/evidence/content/#{id}"

  defp evidence_path(%{object_kind: :sense, sense_revision_id: id}) when is_integer(id),
    do: ~p"/evidence/sense/#{id}"

  defp inspect_path(%{kind: :artwork} = highlight, mode), do: entity_path(highlight, mode)

  defp inspect_path(%{kind: :exemplar, claim: %{assertion_id: id}}, _mode),
    do: ~p"/connections/#{id}"

  defp inspect_path(highlight, _mode), do: evidence_path(highlight.reference)

  # An exemplar's subject: an entity's page, or a passage's pinned words on
  # their evidence page.
  defp subject_path(%{subject: %{kind: :content}, reference: ref}, _mode), do: evidence_path(ref)
  defp subject_path(highlight, mode), do: entity_path(highlight, mode)

  # A subject link goes through the one link helper (#219).
  defp entity_path(%{reference: %{object_id: id}, title: title}, mode),
    do: DevilsDictionary.Routing.Links.path(id, title || "work", mode)

  # A line of verse as its source broke it: Wiktionary marks some breaks with
  # a newline, which becomes a `<br>`; the ` / ` it uses elsewhere is its own
  # text and stays. Escaped line by line before any markup is added.
  defp verse(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()))
    |> Enum.join("<br />")
    |> raw()
  end

  defp provenance_class("verified"),
    do: "bg-emerald-100 text-emerald-900 dark:bg-emerald-400/20 dark:text-emerald-100"

  defp provenance_class("disputed"),
    do: "bg-amber-100 text-amber-900 dark:bg-amber-400/20 dark:text-amber-100"

  defp provenance_class("apocryphal"),
    do: "bg-rose-100 text-rose-900 dark:bg-rose-400/20 dark:text-rose-100"

  defp provenance_class(_plausible),
    do: "bg-mist-950/5 text-mist-700 dark:bg-white/10 dark:text-mist-300"

  defp date(%Date{} = date), do: Calendar.strftime(date, "%-d %B %Y")
end
