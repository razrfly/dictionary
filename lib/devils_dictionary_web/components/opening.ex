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
      subject, who nominated it and when it was accepted, and the meaning it
      was cited for; its disclosure holds
      the nominator's reason and the six stages the examples card shows
      (`DevilsDictionaryWeb.ExampleProvenance.rows/1`), so the two cannot
      disagree about one claim.
    * **A poem or a book is its catalog row** (#257): title, author, what the
      row records (a poem's length, a book's year and public-domain basis),
      the link the row names and the licence. A poem's row pins its lines by
      digest and does not hold them, so the tile quotes none.

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

  attr :reviewer?, :boolean, default: false, doc: "verified signed-in reviewer capability"

  def section(assigns) do
    assigns =
      assigns
      |> assign(:slots, slots(assigns.opening))
      |> assign(:withheld_lead, withheld_lead(assigns.opening))

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
      <.withheld :if={@withheld_lead} id="opening-withheld-lead" item={@withheld_lead} tag="div" />

      <div :if={@slots != []} class="@container">
        <ul
          id="opening-highlights"
          role="list"
          class={[
            "grid grid-cols-1 gap-8",
            length(@slots) == 2 && "@xl:grid-cols-2 @xl:gap-6",
            length(@slots) == 3 && "@2xl:grid-cols-3 @2xl:gap-6"
          ]}
        >
          <%= for slot <- @slots do %>
            <.highlight
              :if={slot.highlight}
              highlight={slot.highlight}
              shares_row={length(@slots) > 1}
              mode={@mode}
            />
            <.withheld
              :if={slot.withheld}
              id={"opening-withheld-highlight-#{slot.position}"}
              item={slot.withheld}
            />
          <% end %>
        </ul>
      </div>

      <.about opening={@opening} mode={@mode} reviewer?={@reviewer?} />
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
          class="font-display text-3xl/10 text-pretty text-mist-950 dark:text-white"
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
            class="flex min-h-11 items-center gap-x-1.5 rounded-sm text-mist-600 underline underline-offset-4 hover:text-mist-950 sm:min-h-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:text-mist-400 dark:hover:text-white dark:focus-visible:outline-white"
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

      <.choice_receipt id="opening-lead" choice={@lead} />
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

  attr :shares_row, :boolean,
    default: true,
    doc: "whether the tile shares its row with other highlights, and keeps its picture small"

  # The picture stays beside the text when the tile shares its row: stacked
  # full width above it, a square artwork alone pushed the Definitions a
  # quarter of a screen down (#257, measured on /on/war at 1280 × 900).
  defp highlight(%{highlight: %{kind: kind}} = assigns) when kind in [:shelf, :linked_claim] do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3 rounded-xl bg-mist-950/2.5 p-5 dark:bg-white/5">
      <p class="text-sm font-medium text-mist-600 dark:text-mist-400">
        {if @highlight.kind == :shelf,
          do: "Selected from provider metadata",
          else: "Selected public linked claim"}
      </p>
      <img
        :if={@highlight.image}
        id={"#{@id}-image"}
        src={@highlight.image.url}
        alt={@highlight.image.alt}
        class="max-h-80 w-full rounded-lg object-contain"
        loading="lazy"
      />
      <h3 id={"#{@id}-title"} class="font-display text-2xl/8">{@highlight.title}</h3>
      <p :if={@highlight.current_label} id={"#{@id}-now"}>Now: {@highlight.current_label}</p>
      <p :if={@highlight.creator}>{@highlight.creator}</p>
      <p
        :if={@highlight.kind == :shelf && @highlight.work.credit_parts != []}
        id={"#{@id}-attribution"}
        class="text-sm/6 text-pretty"
      >
        <%= for part <- @highlight.work.credit_parts do %>
          <a
            :if={part.url}
            href={part.url}
            target="_blank"
            rel="noreferrer"
            class="underline underline-offset-4"
          >{part.text}</a><span :if={is_nil(part.url)}>{part.text}</span>
        <% end %>
      </p>
      <DevilsDictionaryWeb.Culture.attribution_mark
        :if={@highlight.kind == :shelf && @highlight.work.mark}
        id={"#{@id}-provider-mark"}
        mark={@highlight.work.mark}
        provider={@highlight.source.slug}
      />
      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />
      <.link
        :if={@highlight.links[:source]}
        href={@highlight.links.source}
        target="_blank"
        rel="noreferrer"
        class="w-fit underline underline-offset-4"
      >Source</.link>
      <.choice_receipt id={@id} choice={@highlight} />
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

  defp highlight(%{highlight: %{kind: :artwork}} = assigns) do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">Artwork: {@highlight.title}</h3>
      <div class="flex gap-4">
        <div class={[
          "w-24 shrink-0 self-start overflow-hidden rounded-lg bg-mist-950/5 outline-1 -outline-offset-1 outline-black/5 dark:bg-white/5 dark:outline-white/10",
          not @shares_row && "@xl:w-40"
        ]}>
          <img
            src={@highlight.image.url}
            alt={@highlight.image.alt}
            decoding="async"
            class="aspect-4/5 w-full object-contain"
          />
        </div>
        <div class="min-w-0">
          <p aria-hidden="true" class="text-base/6 text-mist-500 sm:text-sm/6">Artwork</p>
          <p class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
            <.work_title id={"#{@id}-title"} highlight={@highlight} mode={@mode} />
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

      <.choice_receipt id={@id} choice={@highlight} />
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

      <.choice_receipt id={@id} choice={@highlight} />
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

  # A poem or a book from a committed catalog (#257): the row's title, its
  # author, what the row records, and the link the row names. The text stays
  # at the provider; a poem's lines are not in its row, so none are quoted.
  defp highlight(%{highlight: %{kind: kind}} = assigns) when kind in [:poem, :book] do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">{work_noun(@highlight.kind)}: {@highlight.title}</h3>
      <div class="flex flex-col gap-1 rounded-xl bg-mist-950/2.5 p-5 dark:bg-white/5">
        <p aria-hidden="true" class="text-base/6 text-mist-500 sm:text-sm/6">
          {work_noun(@highlight.kind)}
        </p>
        <p class="font-display text-xl/7 text-pretty text-mist-950 dark:text-white">
          <.work_title id={"#{@id}-title"} highlight={@highlight} mode={@mode} />
        </p>
        <p
          :if={@highlight.creator || @highlight.date || work_facts(@highlight) != []}
          id={"#{@id}-byline"}
          class="text-base/6 text-mist-600 sm:text-sm/6 dark:text-mist-400"
        >
          {Enum.join(Enum.reject([@highlight.creator, @highlight.date], &is_nil/1), " · ")}<span
            :if={work_facts(@highlight) != []}
            id={"#{@id}-facts"}
            class="tabular-nums"
          ><span :if={@highlight.creator || @highlight.date}> · </span>{Enum.join(
            work_facts(@highlight),
            " · "
          )}</span>
        </p>
        <a
          :if={@highlight.links[:source]}
          id={"#{@id}-source"}
          href={@highlight.links.source}
          target="_blank"
          rel="noreferrer"
          class="mt-1 flex min-h-11 w-fit items-center gap-x-1.5 rounded-sm text-base/6 text-mist-600 underline underline-offset-4 hover:text-mist-950 sm:min-h-0 sm:text-sm/6 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:text-mist-400 dark:hover:text-white dark:focus-visible:outline-white"
        >
          {work_link(@highlight)} <span aria-hidden="true">↗</span>
          <span class="sr-only"> (opens in a new tab)</span>
        </a>
      </div>

      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />

      <.choice_receipt id={@id} choice={@highlight} />
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

  # Another sourced definition on the page (#255): the opening of its exact
  # revision, quoted as the lead is, and the card that holds the rest.
  defp highlight(%{highlight: %{kind: :definition}} = assigns) do
    assigns = assign(assigns, :id, "opening-highlight-#{assigns.highlight.position}")

    ~H"""
    <li id={@id} class="flex min-w-0 flex-col gap-3">
      <h3 class="sr-only">Definition: {@highlight.creator}, {@highlight.title}</h3>
      <figure class="flex flex-col gap-3 rounded-xl bg-mist-950/2.5 p-5 dark:bg-white/5">
        <blockquote
          cite={@highlight.links[:source]}
          class="font-display text-2xl/8 text-pretty text-mist-950 dark:text-white"
        >
          <p
            id={"#{@id}-text"}
            class="relative before:absolute before:-translate-x-full before:content-['\201C'] after:content-['\201D']"
            phx-no-format
          >{raw(@highlight.excerpt.html)}</p>
        </blockquote>
        <figcaption
          id={"#{@id}-citation"}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 text-base/6 text-mist-600 sm:text-sm/6 dark:text-mist-400"
        >
          <.register id={"#{@id}-register"} register={@highlight.register} />
          <span class={[
            "inline-flex items-center gap-2 font-medium",
            tier_text(@highlight.source.tier)
          ]}>
            <SourceBadge.badge source={@highlight.source} decorative />{@highlight.creator}
          </span>
          <span :if={@highlight.date} class="tabular-nums">{@highlight.date}</span>
          <span :if={@highlight.title}>{@highlight.title}</span>
          <.link
            :if={@highlight.links[:card_id]}
            id={"#{@id}-entry"}
            href={"#" <> @highlight.links.card_id}
            phx-click={open_card(@highlight.links.card_id)}
            class="flex min-h-11 items-center gap-x-1.5 rounded-sm underline underline-offset-4 hover:text-mist-950 sm:min-h-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
          >
            <%= if @highlight.excerpt.clipped? do %>
              Read the whole entry
              <span class="tabular-nums">· {number(@highlight.excerpt.chars)} characters</span>
            <% else %>
              The entry among the definitions
            <% end %>
            <span aria-hidden="true">↓</span>
          </.link>
        </figcaption>
      </figure>

      <.credit_line id={"#{@id}-credits"} credits={@highlight.credits} />

      <.choice_receipt id={@id} choice={@highlight} />
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
        <p
          :if={named = exemplar_attribution(@highlight.provenance)}
          id={"#{@id}-named"}
          class="text-base/6 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400"
        >
          {named}
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

      <.choice_receipt id={@id} choice={@highlight} />
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

  attr :id, :string, required: true
  attr :choice, :map, required: true

  defp choice_receipt(assigns) do
    ~H"""
    <div
      :if={@choice.date_info}
      id={"#{@id}-receipt"}
      class="flex flex-col gap-1 text-sm/6 text-mist-600 dark:text-mist-400"
    >
      <p>Content date: {DevilsDictionary.Curation.ContentDate.text(@choice.date_info)}</p>
      <p :if={@choice.source_edition}>Source edition: {@choice.source_edition}</p>
      <p :if={@choice.basis && @choice.basis.origin == "model"}>
        The editor was given only: {@choice.basis.evidence_kind} · {@choice.basis.fields_version}.
      </p>
      <p :if={@choice.basis && @choice.basis.origin == "owner"}>
        Chosen on the curation screen, which lists {@choice.basis.evidence_kind} and links to the source.
      </p>
      <p :if={is_nil(@choice.basis) or @choice.basis.origin == "legacy_unknown"}>
        Basis not recorded.
      </p>
      <.link
        :if={@choice.receipt_path}
        navigate={@choice.receipt_path}
        class="w-fit underline underline-offset-4"
      >Exact choice, chooser and evidence</.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :highlight, :map, required: true
  attr :mode, :atom, default: :public

  # A work's title, linked to its registry page when the registry holds it.
  # A catalog-only work has no page of its own (#253 D5).
  defp work_title(%{highlight: %{reference: %{object_id: id}}} = assigns) when is_integer(id) do
    ~H"""
    <.link
      id={@id}
      navigate={entity_path(@highlight, @mode)}
      class="rounded-sm hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:focus-visible:outline-white"
    >
      {@highlight.title}
    </.link>
    """
  end

  defp work_title(assigns), do: ~H"<span id={@id}>{@highlight.title}</span>"

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :tag, :string, default: "li"

  # A published item withheld at read time (#255 §2.3), in its own place: why,
  # and that nothing took its place. Never what it showed.
  defp withheld(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={@id}
      class="min-w-0 self-start rounded-xl border border-dashed border-mist-950/15 px-5 py-4 text-base/6 text-pretty text-mist-600 sm:text-sm/6 dark:border-white/15 dark:text-mist-400"
    >
      <span class="font-medium text-mist-950 dark:text-white">Withheld:</span>
      {withheld_reason(@item.reason)}. Nothing was put in its place.
    </.dynamic_tag>
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

  attr :reviewer?, :boolean, default: false

  defp about(assigns) do
    ~H"""
    <details
      id="opening-about"
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group/about border-t border-mist-950/10 pt-4 dark:border-white/10"
    >
      <summary class="flex cursor-pointer list-none items-start justify-between gap-4 rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-mist-950 dark:focus-visible:outline-white [&::-webkit-details-marker]:hidden">
        <%!-- A published summary shares the title's line (#255 §2.1), which
             keeps the Definitions a line nearer. --%>
        <span class={[
          "flex min-w-0",
          @opening.origin == :published && "flex-row flex-wrap items-baseline gap-x-2",
          @opening.origin != :published && "flex-col"
        ]}>
          <span class="text-base/7 font-medium text-mist-950 sm:text-sm/7 dark:text-white">
            {if @opening.origin == :published, do: "How this was curated", else: "How this was chosen"}
          </span>
          <span :if={@opening.origin == :published} aria-hidden="true" class="text-mist-400">·</span>
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
        <%!-- A published composition's provenance is its records'
             (#255 §2.2): the configuration it was published under, its
             author, its receipt, and no panel. Then its refresh clock
             (#259 §2.1), five dates in five words: published (above), last
             assessed, checked, inputs changed, next assessment. A P5 check
             looks at the inputs and does not judge them, and says so. The
             screen's preview of an unsaved selection has no clock. --%>
        <dl :if={@opening.origin == :published} class="flex flex-col gap-3">
          <.about_row id="opening-about-configuration" label="Configuration">
            {configuration(@opening.configuration)}
          </.about_row>
          <.about_row id="opening-about-selected" label="Selected by">
            <%= if taken = taken(@opening.review.selected_by) do %>
              {selector(@opening.review.selected_by)},
              <.attempt
                id="opening-about-selected-attempt"
                attempt_id={taken.attempt_id}
                mode={@mode}
                reviewer?={@reviewer?}
              />
              · {if taken.edited?, do: "edited and published", else: "taken"} by {taken.taken_by}{if taken.taken_on,
                do: " on #{date(taken.taken_on)}"}
            <% else %>
              {operator(@opening.review.selected_by)}{if @opening.review.selected_on,
                do: " · #{date(@opening.review.selected_on)}"}
            <% end %>
          </.about_row>
          <.about_row id="opening-about-published" label="Published by">
            {publication(@opening)}
          </.about_row>
          <.about_row id="opening-about-panel" label="Panel">
            None: published by the operator.
          </.about_row>
          <.withheld_row withheld={@opening.withheld} />
          <.about_row id="opening-about-composition" label="Composition">
            {selection(@opening)}
          </.about_row>
          <.about_row
            :if={@opening.review.assessment != :preview}
            id="opening-about-assessed"
            label="Last assessed"
          >
            {assessed(@opening.review.assessment)}
          </.about_row>
          <.about_row
            :if={@opening.review.assessment != :preview}
            id="opening-about-checked"
            label="Checked"
          >
            Just now, against the record.
          </.about_row>
          <.about_row
            :if={@opening.review.assessment != :preview}
            id="opening-about-changed"
            label="Inputs changed"
          >
            {inputs_changed(@opening.review.assessment)}
          </.about_row>
          <.about_row
            :if={@opening.review.assessment != :preview}
            id="opening-about-next"
            label="Next assessment"
          >
            {next_assessment(@opening.review.assessment)}
          </.about_row>
        </dl>

        <dl :if={@opening.origin != :published} class="flex flex-col gap-3">
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
          <.withheld_row withheld={@opening.withheld} />
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
              <span :if={attempt_id = attempt_of(@opening.lead.reasons)}>
                ·
                <.attempt
                  id="opening-about-revision-lead-attempt"
                  attempt_id={attempt_id}
                  mode={@mode}
                  reviewer?={@reviewer?}
                />
              </span>
            </li>
            <li
              :for={highlight <- @opening.highlights}
              id={"opening-about-revision-#{highlight.position}"}
            >
              Highlight {highlight.position} · {reference(highlight.reference)}
              <.inspect_link highlight={highlight} mode={@mode} />
              <span :if={attempt_id = attempt_of(highlight.reasons)}>
                ·
                <.attempt
                  id={"opening-about-revision-#{highlight.position}-attempt"}
                  attempt_id={attempt_id}
                  mode={@mode}
                  reviewer?={@reviewer?}
                />
              </span>
            </li>
          </ul>
        </div>
      </div>
    </details>
    """
  end

  attr :highlight, :map, required: true
  attr :mode, :atom, default: :public

  # Where a highlight is inspected: a registry page by live navigation, or,
  # for a catalog work the registry does not hold, the catalog's own record
  # in a new tab. Nothing when there is neither.
  defp inspect_link(assigns) do
    assigns = assign(assigns, :path, inspect_path(assigns.highlight, assigns.mode))

    ~H"""
    <%= cond do %>
      <% is_nil(@path) -> %>
      <% String.starts_with?(@path, "/") -> %>
        ·
        <.link
          navigate={@path}
          class="rounded-sm underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
        >
          {inspect_label(@highlight.kind)}
        </.link>
      <% true -> %>
        ·
        <a
          href={@path}
          target="_blank"
          rel="noreferrer"
          class="rounded-sm underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
        >
          {inspect_label(@highlight.kind)}<span class="sr-only"> (opens in a new tab)</span>
        </a>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :attempt_id, :integer, required: true
  attr :mode, :atom, default: :public

  attr :reviewer?, :boolean, default: false

  # The attempt an editor's choice came from (#253 D9): its text for every
  # reader, a link to the reviewer-only attempt page only where the reader
  # is an authenticated reviewer reading internally (the page is 404 through
  # the tunnel like all of `/ops`).
  defp attempt(assigns) do
    ~H"""
    <%= if @mode == :internal and @reviewer? do %>
      <.link
        id={@id}
        navigate={~p"/ops/curation/attempts/#{@attempt_id}"}
        class="rounded-sm underline underline-offset-4 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:hover:text-white dark:focus-visible:outline-white"
      >
        attempt {"##{@attempt_id}"}
      </.link>
    <% else %>
      <span id={@id}>attempt {"##{@attempt_id}"}</span>
    <% end %>
    """
  end

  # A taken proposal's selector carries who took it (#264 R14.4).
  defp taken(%{taken_by: _taken_by, attempt_id: id} = selector) when is_integer(id), do: selector
  defp taken(_selector), do: nil

  defp attempt_of(reasons) do
    Enum.find_value(reasons || [], fn
      %{kind: :editorial, author: %{kind: :model, attempt_id: id}} when is_integer(id) -> id
      _other -> nil
    end)
  end

  attr :withheld, :list, required: true

  defp withheld_row(assigns) do
    ~H"""
    <.about_row id="opening-about-withheld" label="Withheld">
      <%= if @withheld == [] do %>
        Nothing. Every selected item is still eligible.
      <% else %>
        <ul role="list" class="flex flex-col gap-1">
          <li :for={item <- @withheld}>
            {withheld_label(item)}: {withheld_reason(item.reason)}. Nothing was put in its place.
          </li>
        </ul>
      <% end %>
    </.about_row>
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

  # The highlight places, in position order. A published item withheld at
  # read time keeps its place and says why (#255 §2.3); a fixture's does not,
  # as it never has.
  defp slots(%{origin: :published} = opening) do
    shown = Enum.map(opening.highlights, &%{position: &1.position, highlight: &1, withheld: nil})

    held =
      for %{role: :highlight} = item <- opening.withheld,
          do: %{position: item.position, highlight: nil, withheld: item}

    Enum.sort_by(shown ++ held, & &1.position)
  end

  defp slots(opening),
    do: Enum.map(opening.highlights, &%{position: &1.position, highlight: &1, withheld: nil})

  defp withheld_lead(%{origin: :published, lead: nil, withheld: withheld}),
    do: Enum.find(withheld, &(&1.role == :lead))

  defp withheld_lead(_opening), do: nil

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
  defp by(%{kind: :model, label: label, attempt_id: id}) when is_integer(id),
    do: "Generated by #{label}, an AI model, attempt ##{id}"

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

  # The published summary is the record's: when, and under which
  # configuration (#255 §2.1).
  defp summary(%{origin: :published, review: review, configuration: configuration}) do
    [
      if(review.published_on, do: "Published #{date(review.published_on)}", else: "Published"),
      configuration && "#{configuration.slug} v#{configuration.version}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

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

  # A selection not yet saved (the operator screen's preview, #257) has no
  # id, and says so.
  defp selection(%{composition: %{id: id, version: version}}),
    do: "##{id || "—"}, version #{version}"

  # A published opening's configuration row: what it is and the lead rule it
  # carries, as the configuration version records them.
  defp configuration(%{slug: slug, version: version} = configuration) do
    rule = configuration.lead_rule && " · lead rule #{configuration.lead_rule}"
    "#{slug}, version #{version}#{rule}"
  end

  defp configuration(_none), do: "Not recorded"

  # Who acted on the operator path: a person, published by hand. A model is
  # named as one wherever it appears.
  defp operator(%{kind: :model, label: label}), do: "#{label}, an AI model"
  defp operator(%{label: label}), do: "#{label} (operator)"
  defp operator(_none), do: "Not recorded"

  defp publication(%{review: review, composition: composition}) do
    [
      operator(review.published_by),
      review.published_on && date(review.published_on),
      composition && "version #{composition.version}",
      review.receipt_id && "receipt ##{review.receipt_id}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp withheld_label(%{role: :lead}), do: "The lead"
  defp withheld_label(%{role: :highlight, position: position}), do: "Highlight #{position}"

  @doc """
  Why an item was withheld, as the page says it: a clause that follows
  "Withheld:" or "Highlight 2:". It covers every reason the fixture reader,
  `Curation.Eligibility`, `Curation.LeadRule`, `Curation.Published` and
  `Curation.PublishedReader` give, and answers a plain fallback for any
  other, so an unmapped reason never raises on a public page.
  """
  def withheld_reason({:publication_withheld, reasons}) when is_list(reasons),
    do: Enum.map_join(reasons, "; ", &withheld_reason/1)

  def withheld_reason(:retention_expired),
    do: "the selected observation's retention window has expired"

  def withheld_reason(:payload_redacted),
    do: "the selected source payload was redacted under its retention policy"

  def withheld_reason(:revision_mismatch),
    do: "The selected observation no longer matches its exact source revision."

  def withheld_reason(:observation_unbound),
    do: "the exact observed revision cannot be established"

  def withheld_reason(:claim_not_current), do: "the selected claim is no longer current"
  def withheld_reason(:claim_unlinked), do: "the claim's public scope link no longer stands"

  def withheld_reason(:revision_not_current),
    do: "its exact source revision is no longer current"

  def withheld_reason(:revision_inactive), do: "its source revision was withdrawn"
  def withheld_reason(:excerpt_changed), do: "the words it quotes have changed since selection"
  def withheld_reason(:excerpt_unpinned), do: "the selection does not pin the words it quotes"
  def withheld_reason(:display_not_allowed), do: "its source may not be displayed"
  def withheld_reason(:source_inactive), do: "its source is switched off"
  def withheld_reason(:object_inactive), do: "it has left the registry"
  def withheld_reason(:catalog_changed), do: "its catalog has changed since it was selected"

  def withheld_reason(:catalog_drift),
    do: "what would be shown no longer matches the catalog row that was selected"

  def withheld_reason(:priority_source_available),
    do: "a Devil’s Dictionary entry applies here, and only that entry may lead"

  def withheld_reason(:priority_source_missing),
    do: "a Devil’s Dictionary entry applies here, and the selection names no lead"

  def withheld_reason(:not_on_page), do: "it is not among this page’s definitions"
  def withheld_reason(:over_limit), do: "an opening shows at most three highlights"
  def withheld_reason(:duplicate), do: "it repeats an earlier highlight"
  def withheld_reason(:meaning_off_page), do: "its meaning is not on this page"

  def withheld_reason(:meaning_mismatch),
    do: "it no longer publicly defines the meaning it was selected for"

  def withheld_reason(:quotation_not_found), do: "its line is no longer filed under that meaning"
  def withheld_reason(:no_image), do: "its image is no longer available"

  # An exemplar's claim (#212). One sentence for every way a claim falls
  # short, so a withheld nomination is never described: not whom it names,
  # not that it waits for review, not that a reviewer turned it down.
  def withheld_reason(reason)
      when reason in [
             :claim_not_found,
             :claim_not_accepted,
             :claim_not_visible,
             :claim_not_current,
             :claim_deleted
           ],
      do: "it is not an example a reviewer has accepted"

  def withheld_reason(:claim_context_changed),
    do: "what it shows has changed since a reviewer accepted it"

  def withheld_reason(:meaning_off_scope),
    do: "its meaning is not one of the words it was selected for"

  def withheld_reason(:object_retired), do: "it has left the registry"

  def withheld_reason(:unsupported_subject),
    do: "the opening does not show that kind of example yet"

  # A published composition's items (#255), as `Curation.Eligibility` and
  # `Curation.LeadRule` name them at read time.
  def withheld_reason(:revision_superseded),
    do: "its source revision was superseded since selection"

  def withheld_reason(:revision_withdrawn), do: "its source revision was withdrawn"
  def withheld_reason(:revision_deleted), do: "its source revision was deleted"
  def withheld_reason(:object_deleted), do: "what it showed was deleted from the registry"
  def withheld_reason(:object_missing), do: "what it showed is no longer recorded"

  def withheld_reason(:meaning_deleted),
    do: "the meaning it was selected for is no longer current"

  def withheld_reason(:display_restricted), do: "its source may not be displayed"

  def withheld_reason(:claim_not_about_object),
    do: "the claim it relies on is not about what it shows"

  def withheld_reason(:catalog_row_missing), do: "its catalog no longer lists it"

  def withheld_reason(:work_identity_mismatch),
    do: "its record no longer identifies the work it shows"

  def withheld_reason(:words_changed),
    do: "the words at its place in the source have changed since selection"

  def withheld_reason(:lead_not_on_scope), do: "it is not among this page’s definitions"

  def withheld_reason(:unsupported_item),
    do: "the opening does not show that kind of item yet"

  def withheld_reason(reason) when reason in [:empty, :no_prose_opening, :no_sentence_boundary],
    do: "its entry has no opening sentence to quote"

  # A version withheld as a whole (`Curation.Published`) draws no opening at
  # all, so these are never on a page; they are named for completeness.
  def withheld_reason(:composition_retired), do: "its composition was retired"

  def withheld_reason(:configuration_changed),
    do: "its curation configuration has changed since it was published"

  def withheld_reason(:scope_changed), do: "the words it was made for have changed"
  def withheld_reason(:approval_withdrawn), do: "its approval was withdrawn"
  def withheld_reason(:stale_eligibility), do: "what it was approved on has changed"

  def withheld_reason(_reason), do: "it could not be resolved"

  # An exemplar names the claim it shows as well as the thing.
  defp reference(%{shelf_citation_id: id, source_record_revision_id: revision})
       when is_integer(id), do: "shelf citation #{id}, source revision #{revision}"

  defp reference(%{assertion_revision_id: claim} = ref) when is_integer(claim) do
    words = if ref.content_revision_id, do: ", revision #{ref.content_revision_id}", else: ""
    "#{ref.object_kind} #{ref.object_id}#{words}, claim revision #{claim}"
  end

  defp reference(%{object_kind: :content} = ref),
    do: "content #{ref.object_id}, revision #{ref.content_revision_id}#{locator(ref.locator)}"

  defp reference(%{object_kind: :sense} = ref),
    do: "sense #{ref.object_id}, revision #{ref.sense_revision_id}#{locator(ref.locator)}"

  defp reference(
         %{object_kind: :entity, catalog: %{manifest: manifest, checksum: checksum} = catalog} =
           ref
       ) do
    work = if ref.object_id, do: "work #{ref.object_id}, ", else: ""
    row = if catalog[:identity], do: " row #{catalog.identity}", else: ""
    "#{work}catalog #{manifest}#{row} @ #{String.slice(checksum, 0, 12)}"
  end

  defp reference(ref), do: "#{ref.object_kind} #{ref.object_id}"

  defp locator(%{kind: :sentences, count: 1}), do: ", first sentence"
  defp locator(%{kind: :sentences, count: n}), do: ", first #{n} sentences"
  defp locator(%{kind: :quotation, fingerprint: fp}), do: ", line #{String.slice(fp, 0, 12)}"
  defp locator(_locator), do: ""

  defp inspect_label(kind) when kind in [:artwork, :poem, :book], do: "work"
  defp inspect_label(:linked_claim), do: "claim"
  defp inspect_label(:shelf), do: "exact choice"
  defp inspect_label(:exemplar), do: "claim"
  defp inspect_label(_kind), do: "evidence"

  defp work_noun(:poem), do: "Poem"
  defp work_noun(:book), do: "Book"

  # What a poem's or a book's row records beyond its title and byline.
  defp work_facts(%{kind: :poem, work: %{line_count: n}}) when is_integer(n),
    do: ["#{number(n)} #{if n == 1, do: "line", else: "lines"}"]

  defp work_facts(%{kind: :book, work: %{public_domain: basis}}) when is_binary(basis),
    do: ["Public domain"]

  defp work_facts(_highlight), do: []

  # The row's locator is the PoetryDB query it came from (the poet's poems),
  # not a page of its own: the link says it finds the poem there.
  defp work_link(%{kind: :poem, source: %{name: name}}) when is_binary(name),
    do: "Find it at #{name}"

  defp work_link(%{kind: :book, source: %{name: name}}) when is_binary(name),
    do: "Open at #{name}"

  defp work_link(_highlight), do: "Source"

  # Who put the example on the record, on the tile (#257 §5.2): who
  # nominated it and when a reviewer accepted it. An exemplar is always a
  # nomination; a thing a source names under a meaning is an instance, which
  # is not an exemplar. The stages in the disclosure say the rest.
  defp exemplar_attribution(%{nomination: %{by: %{label: label}}, review: review})
       when is_binary(label) do
    case review do
      %{state: :accepted, decided_at: at} when not is_nil(at) ->
        "Nominated by #{label} · accepted #{ExampleProvenance.date(at)}"

      _review ->
        "Nominated by #{label}"
    end
  end

  defp exemplar_attribution(_provenance), do: nil

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

  defp inspect_path(%{kind: :linked_claim, links: %{connection: id}}, _mode),
    do: ~p"/connections/#{id}"

  defp inspect_path(%{kind: :shelf, receipt_path: path, links: links}, _mode),
    do: path || links[:source]

  defp inspect_path(%{kind: kind, reference: %{object_id: id}} = highlight, mode)
       when kind in [:artwork, :poem, :book] and is_integer(id),
       do: entity_path(highlight, mode)

  defp inspect_path(%{kind: kind, links: links}, _mode)
       when kind in [:artwork, :poem, :book],
       do: links[:source]

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
  defp date(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> date()

  # ── the refresh clock (#259 §2.1) ─────────────────────────────────────────

  # When the inputs were last checked, and what the check found. A check
  # looks at the inputs; it does not judge them, and the row says so. An
  # editor's assessment does judge them, and says that instead (#264 R14.3,
  # OD-7).
  defp assessed(nil), do: "Never."

  defp assessed(%{last_completed_at: nil, state: state}) when state in [:queued, :running],
    do: "Never · queued on your visit."

  defp assessed(%{last_completed_at: nil, state: :deferred}),
    do: "Never · the first check failed and will be retried."

  defp assessed(%{last_completed_at: nil}), do: "Never."

  defp assessed(%{last_completed_at: at, last_outcome: outcome} = assessment)
       when outcome in [:proposed, :abstained, :no_change] do
    judged =
      case outcome do
        :proposed -> "it proposed a change, which waits for the owner's review"
        :abstained -> "the candidates were too thin to choose from, so it proposed nothing"
        :no_change -> "nothing to change"
      end

    queued = if assessment.state in [:queued, :running], do: " Another check is queued."
    "#{date(at)} · judged by the editor: #{judged}.#{queued}"
  end

  defp assessed(%{last_completed_at: at} = assessment) do
    found =
      case assessment do
        %{last_outcome: :needs_editor, last_outcome_reason: "packet_refused:" <> reason} ->
          "an editor is needed, but no packet could be built (#{reason})"

        %{last_outcome: :unchanged, last_outcome_reason: "accepted"} ->
          "nothing has changed since this version was accepted"

        %{last_outcome: :unchanged} ->
          "nothing has changed since the last check"

        %{last_outcome: :needs_editor, last_outcome_reason: reason} ->
          "an editor is needed (#{editor_needed(reason)})"
      end

    queued = if assessment.state in [:queued, :running], do: " Another check is queued."
    "#{date(at)} · the inputs were checked, not judged: #{found}.#{queued}"
  end

  defp editor_needed("due"), do: "the periodic re-assessment came due"
  defp editor_needed("fingerprint_version"), do: "the inputs are now identified differently"
  defp editor_needed("nothing_accepted"), do: "nothing has been accepted yet"
  defp editor_needed("requested"), do: "the owner requested a proposal"
  defp editor_needed(_changed), do: "the inputs changed"

  # When an input last changed: history, kept after the check that saw it.
  defp inputs_changed(nil), do: "Not recorded yet."

  defp inputs_changed(%{inputs_last_changed_at: nil, last_completed_at: nil}),
    do: "Not recorded yet."

  defp inputs_changed(%{inputs_last_changed_at: nil, last_outcome_reason: reason})
       when reason in ["accepted", "nothing_accepted"],
       do: "Not since this version was accepted."

  defp inputs_changed(%{inputs_last_changed_at: nil}), do: "Not since the last check."

  defp inputs_changed(%{inputs_last_changed_at: at} = assessment) do
    pending = if assessment.dirty_at, do: " Not checked yet."
    reason = DevilsDictionary.Curation.Refresh.change_label(assessment.inputs_last_changed_reason)
    "#{date(at)} (#{reason}).#{pending}"
  end

  # When the next check is due.
  defp next_assessment(nil), do: "On the next visit."

  defp next_assessment(%{state: state}) when state in [:queued, :running], do: "Queued now."

  defp next_assessment(%{state: :deferred, next_retry_at: at}),
    do: "After #{date(at)}: the last check failed and will be retried."

  defp next_assessment(%{last_completed_at: nil}), do: "On the next visit."

  defp next_assessment(%{dirty_at: %DateTime{}, dirty_reason: reason}),
    do: "On the next visit: #{DevilsDictionary.Curation.Refresh.change_label(reason)}."

  defp next_assessment(%{refresh_after: at}),
    do: "After #{date(at)}, or sooner if an input changes."
end
