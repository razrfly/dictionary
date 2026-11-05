defmodule DevilsDictionaryWeb.CuratedArticle do
  @moduledoc """
  The curated page (#309): `/on/:slug` read as an article that an editor
  made, phone first. One document order at every width, and nothing on it
  for one screen size only:

    1. **The masthead.** The view switch (*This editor's selection* ·
       *Everything this page holds*), the headword, and the byline: who
       selected it, whether a person reviewed it, when, which version, and
       the receipt.
    2. **The selection** (`DevilsDictionaryWeb.Opening.article/1`): the lead
       with its reason on the page, *In the news* directly after it, then
       Definitions, Quotations, Examples and In culture, every published item
       drawn with its reason and one disclosure.
    3. **The editor's take**: who the editor is, in the page's voice, never
       the persona's; what the page holds and what the editor chose; anything
       withheld. On a desktop it is the rail beside the selection; on a phone
       it follows In culture. Then the related words.
    4. **About this version**: the version, the instruction, the model, the
       configuration version, the receipt and the earlier versions.

  With nothing to show, the page says which state it is in (D1 rows 20–23):
  a selection withheld as a whole, an editor that assessed the words and
  chose not to select, or no assessment yet; then what the page holds.

  Every label is the D1 table's (#309 c6637566629). The editor's own words on
  the page are only its stored reasons. It renders what it is given: no
  query, no selection.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionaryWeb.{Opening, Word}

  # D1 row 17a: one sentence per persona, in the page's voice, written from
  # each dossier's `selection` field; fixed here until the reviewed curator
  # summaries (#299, #304) are on main. Row 17b: the dossier's disclosure,
  # verbatim.
  @personas %{
    "Voltaire" => %{
      sentence:
        "Looks for sourced material that tests a confident claim against its consequences.",
      disclosure:
        "An AI selection lens inspired by Voltaire; not his voice or an assertion of his opinions about modern events."
    },
    "Christopher Hitchens" => %{
      sentence:
        "Looks for sourced material whose own evidence tests whether the word fits a real case."
    },
    "Ambrose Bierce" => %{
      sentence:
        "Looks for sourced material that sets a professed principle beside the interest behind it."
    }
  }

  @generic "Chooses the clearest sourced record for each meaning, with no persona lens."

  defp link_class,
    do:
      "rounded-sm underline decoration-mist-950/30 underline-offset-4 hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:decoration-white/30 dark:focus-visible:outline-white"

  defp muted, do: "text-mist-600 dark:text-mist-400"

  attr :page, :map, required: true
  attr :opening, :map, default: nil

  attr :state, :map,
    default: nil,
    doc: "`Curation.PageState.for_page/1`, when there is no opening"

  attr :base, :string, required: true, doc: "the page's own path"
  attr :curated_path, :string, required: true
  attr :record_path, :string, required: true
  attr :card_sources, :list, default: []
  attr :choices, :list, default: []
  attr :thing_info, :string, default: nil
  attr :demo, :boolean, default: false
  attr :mode, :atom, default: :public
  attr :reviewer?, :boolean, default: false
  attr :earlier, :list, default: []
  attr :chosen, :map, default: nil, doc: "`Curation.PageState.chosen/2`: the version's items"

  attr :trail, :list,
    default: [],
    doc: "the walk so far, this word included, for the related words' hops"

  slot :extra, doc: "an authored overview and its subjects, where these words have one"

  def article(assigns) do
    assigns =
      assigns
      |> assign(:lemma, assigns.page.headword.lemma)
      |> assign(:receipt, receipt(assigns.base, assigns.opening))

    ~H"""
    <article id="curated-page" class="min-w-0">
      <%!-- The headword's links in a line, 44 px targets on the article
           (#309 review 5), Wikidata's on a line of its own so the
           description keeps its spacing (review 6); the shared headword is
           unchanged elsewhere. --%>
      <header
        id="curated-masthead"
        class="flex flex-col gap-5 pb-6 [&_#parts-of-speech_a]:inline-flex [&_#parts-of-speech_a]:min-h-11 [&_#parts-of-speech_a]:items-center [&_#quick-definition_a]:inline-flex [&_#quick-definition_a]:min-h-11 [&_#quick-definition_a]:items-center [&_#quick-definition>span]:block"
      >
        <nav
          id="entry-views"
          aria-label="Entry views"
          class="grid grid-cols-2 rounded-xl bg-mist-950/5 p-1 text-base/5 sm:w-fit sm:text-sm/5 dark:bg-white/10"
        >
          <.link
            id="entry-curated"
            patch={@curated_path}
            aria-current="page"
            class="flex min-h-11 items-center justify-center rounded-lg bg-white px-3 py-2 text-center font-medium text-mist-950 shadow-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:bg-mist-700 dark:text-white dark:focus-visible:outline-white"
          >
            This editor’s selection
          </.link>
          <.link
            id="entry-records"
            patch={@record_path}
            class="flex min-h-11 items-center justify-center rounded-lg px-3 py-2 text-center text-mist-700 hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:text-mist-300 dark:hover:text-white dark:focus-visible:outline-white"
          >
            Everything this page holds
          </.link>
        </nav>
        <div>
          <p id="on-title" class="mb-1 text-base/7 font-semibold text-mist-700 dark:text-mist-400">
            On {@lemma}
          </p>
          <Word.headword
            headword={@page.headword}
            choices={@choices}
            thing={@page.thing}
            thing_info={@thing_info}
            demo={@demo}
          />
        </div>
        <.byline :if={@opening} opening={@opening} receipt={@receipt} />
      </header>

      <%= if @opening do %>
        <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-x-16">
          <div id="curated-column" class="min-w-0">
            <Opening.article opening={@opening} mode={@mode} record_path={@record_path} />
            {render_slot(@extra)}
          </div>
          <aside
            id="curated-rail"
            aria-label="The editor and related words"
            class="min-w-0 lg:border-t lg:border-mist-950/10 lg:pt-8 dark:lg:border-white/10"
          >
            <.editor
              opening={@opening}
              chosen={@chosen}
              page={@page}
              card_sources={@card_sources}
              record_path={@record_path}
            />
            <.related page={@page} trail={@trail} demo={@demo} record_path={@record_path} />
          </aside>
        </div>
        <.provenance
          opening={@opening}
          receipt={@receipt}
          base={@base}
          earlier={@earlier}
          mode={@mode}
          reviewer?={@reviewer?}
        />
      <% else %>
        <%!-- An authored overview leads; the state follows it (#309 review 3). --%>
        {render_slot(@extra)}
        <.state
          state={@state || %{kind: :none}}
          base={@base}
          lemma={@lemma}
          page={@page}
          card_sources={@card_sources}
          record_path={@record_path}
        />
        <.related page={@page} trail={@trail} demo={@demo} record_path={@record_path} />
      <% end %>
    </article>
    """
  end

  # ── the byline (D1 rows 3–5) ─────────────────────────────────────────────

  attr :opening, :map, required: true
  attr :receipt, :string, default: nil

  defp byline(assigns) do
    review = assigns.opening.review
    selector = review.selected_by || %{}

    assigns =
      assigns
      |> assign(:review, review)
      |> assign(:model?, selector[:kind] == :model)
      |> assign(:editor, editor_phrase(selector))

    ~H"""
    <div id="curated-byline" class="flex gap-3 text-base/7">
      <Opening.ai_mark :if={@model?} class="mt-0.5 size-7 text-[0.6875rem]" />
      <div class="flex min-w-0 flex-col items-start gap-2">
        <%!-- The editor's link is a 44 px box at every width (#309 review 6). --%>
        <p id="curation-summary" class="text-pretty">
          Selected by
          <.link
            :if={@receipt}
            navigate={@receipt}
            class={["inline-flex min-h-11 max-w-full items-center font-medium", link_class()]}
          >{@editor}</.link>
          <span :if={!@receipt} class="font-medium">{@editor}</span>
        </p>
        <span
          :if={@model? or @review.reviewed_by}
          id="curated-status"
          class="rounded-full bg-amber-100 px-3 py-0.5 text-sm/6 font-medium text-amber-900 dark:bg-amber-400/15 dark:text-amber-200"
        >
          {status(@review)}
        </span>
        <p :if={@opening.origin == :fixture} id="opening-fixture" class={muted()}>
          Development fixture · not published
        </p>
        <p :if={@review.published_on} id="curated-version" class={muted()}>
          {date(@review.published_on)} · version {@opening.composition[:version]}
        </p>
        <.link
          :if={@receipt}
          id="curated-how"
          navigate={@receipt}
          class={["-mt-2 flex min-h-11 items-center", link_class()]}
        >
          How this page was curated →
        </.link>
      </div>
    </div>
    """
  end

  # ── the editor's take (D1 row 17) ────────────────────────────────────────

  attr :opening, :map, required: true
  attr :chosen, :map, default: nil
  attr :page, :map, required: true
  attr :card_sources, :list, default: []
  attr :record_path, :string, required: true

  defp editor(assigns) do
    selector = assigns.opening.review.selected_by || %{}
    persona = persona(selector)
    # What the version holds, shown or withheld; a lead the lead rule finds
    # missing is withheld too, but the editor never chose it (#309 review R2).
    withheld =
      case assigns.chosen do
        %{lead?: false} -> Enum.reject(assigns.opening.withheld, &(&1.role == :lead))
        _ -> assigns.opening.withheld
      end

    shown = length(List.wrap(assigns.opening.lead)) + length(assigns.opening.highlights)

    assigns =
      assigns
      |> assign(:model?, selector[:kind] == :model)
      |> assign(:editor, editor_phrase(selector))
      |> assign(:about, Map.get(@personas, persona, %{}))
      |> assign(:lens, lens(selector, persona))
      |> assign(:chose, (assigns.chosen && assigns.chosen.items) || shown + length(withheld))
      |> assign(:withheld, withheld)
      # A withheld lead says so in its own place; the rest are listed here.
      |> assign(:withheld_items, Enum.reject(withheld, &(&1.role == :lead)))

    ~H"""
    <section
      id="curated-editor"
      aria-labelledby="curated-editor-heading"
      class="flex flex-col gap-4 border-t border-mist-950/10 py-8 lg:border-t-0 lg:pt-0 dark:border-white/10"
    >
      <h2 id="curated-editor-heading" class="font-display text-3xl/9 tracking-tight">The editor</h2>
      <p class="flex items-center gap-3 text-base/7 font-medium">
        <Opening.ai_mark :if={@model?} />{capitalize_first(@editor)}
      </p>
      <p :if={@lens} id="curated-editor-lens" class="text-lg/7 text-pretty">{@lens}</p>
      <p
        :if={@about[:disclosure]}
        id="curated-editor-disclosure"
        class={["text-base/6 text-pretty", muted()]}
      >
        “{@about.disclosure}”
      </p>
      <p id="curated-holdings" class="text-base/7 text-pretty">
        This page holds {holdings(@page, @card_sources)}. The editor chose {@chose}{if @withheld != [],
                                                                                       do:
                                                                                         ", and #{length(@withheld)} #{if length(@withheld) == 1, do: "is", else: "are"} withheld"}.
      </p>
      <ul :if={@withheld_items != []} id="curated-withheld" role="list" class="flex flex-col gap-2">
        <li
          :for={item <- @withheld_items}
          id={"curated-withheld-#{item.position}"}
          class={["text-base/6 text-pretty", muted()]}
        >
          <span class="font-medium text-mist-950 dark:text-white">Withheld:</span>
          {Opening.withheld_reason(item.reason)}. Nothing was put in its place.
        </li>
      </ul>
      <.link
        id="record-inventory-link"
        patch={@record_path}
        class={["flex min-h-11 w-fit items-center font-medium", link_class()]}
      >
        Everything this page holds →
      </.link>
    </section>
    """
  end

  # ── related words (D1 row 18) ────────────────────────────────────────────

  @related_shown 8

  attr :page, :map, required: true
  attr :trail, :list, default: []
  attr :demo, :boolean, default: false
  attr :record_path, :string, required: true

  # The way out of the word, short: the first chips of the groups in their
  # order, and every relation on the source records (#309 audit default 2).
  defp related(assigns) do
    chips = related_chips(assigns.page.related)

    assigns =
      assigns
      |> assign(:chips, Enum.take(chips, @related_shown))
      |> assign(:more?, length(chips) > @related_shown)

    ~H"""
    <section
      :if={@chips != []}
      id="curated-related"
      aria-labelledby="curated-related-heading"
      class="flex flex-col gap-4 border-t border-mist-950/10 py-8 dark:border-white/10"
    >
      <h2 id="curated-related-heading" class="font-display text-3xl/9 tracking-tight">
        Related words
      </h2>
      <ul role="list" class="flex flex-wrap gap-2">
        <li :for={{_group, chip} <- @chips}>
          <.link
            id={"curated-related-word-#{chip.slug}"}
            navigate={Word.hop(chip.slug, @trail, @demo)}
            class="flex min-h-11 items-center rounded-full bg-mist-950/5 px-3 text-base/6 hover:bg-mist-950/10 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:bg-white/10 dark:hover:bg-white/15 dark:focus-visible:outline-white"
          >
            {chip.lemma}
          </.link>
        </li>
      </ul>
      <.link
        :if={@more?}
        id="curated-related-all"
        href={@record_path <> "#related"}
        class={["flex min-h-11 w-fit items-center", link_class()]}
      >
        All related words →
      </.link>
    </section>
    """
  end

  defp related_chips(%{groups: groups}) when is_map(groups) do
    order = DevilsDictionary.Lexicon.WordPage.group_order()
    key = fn {group, _chips} -> if is_tuple(group), do: elem(group, 0), else: group end

    groups
    |> Enum.sort_by(&(Enum.find_index(order, fn k -> k == key.(&1) end) || length(order)))
    |> Enum.flat_map(fn {group, chips} ->
      Enum.map((chips[:shown] || []) ++ (chips[:rest] || []), &{group, &1})
    end)
    |> Enum.uniq_by(fn {_group, chip} -> chip.slug end)
  end

  defp related_chips(_related), do: []

  # ── about this version (D1 row 19) ───────────────────────────────────────

  attr :opening, :map, required: true
  attr :receipt, :string, default: nil
  attr :base, :string, required: true
  attr :earlier, :list, default: []
  attr :mode, :atom, default: :public
  attr :reviewer?, :boolean, default: false

  defp provenance(assigns) do
    {instruction, model} = technical(assigns.opening.review.selected_by)

    assigns =
      assigns
      |> assign(:instruction, instruction)
      |> assign(:model, model)

    ~H"""
    <footer
      id="curated-provenance"
      class={[
        "flex flex-col gap-3 border-t border-mist-950/10 pt-8 text-base/7 dark:border-white/10",
        "[&_#opening-about-revisions_a]:inline-flex [&_#opening-about-revisions_a]:min-h-11 [&_#opening-about-revisions_a]:items-center",
        muted()
      ]}
    >
      <h2 class="font-semibold text-mist-950 dark:text-white">About this version</h2>
      <p id="curated-provenance-line" class="text-pretty">
        Version {@opening.composition[:version]}<span :if={@opening.review.published_on}> · published {date(
          @opening.review.published_on
        )}</span><span :if={@instruction}> · instruction <span class="font-mono text-sm">{@instruction}</span></span><span :if={
          @model
        }> · model <span class="font-mono text-sm">{@model}</span></span><span :if={
          @opening.configuration
        }> · configuration version {@opening.configuration.version}</span>
      </p>
      <p class="flex flex-wrap items-center gap-x-5">
        <.link :if={@receipt} navigate={@receipt} class={["flex min-h-11 items-center", link_class()]}>
          How this page was curated →
        </.link>
        <span :if={@earlier != []} id="curated-earlier">
          Earlier versions: <%!-- Each a 44 px target, not a one-digit link (#309 review 2). --%>
          <.link
            :for={version <- @earlier}
            navigate={"#{@base}/receipt/#{version}"}
            aria-label={"Version #{version}"}
            class={["inline-flex min-h-11 min-w-11 items-center justify-center", link_class()]}
          >
            {version}
          </.link>
        </span>
      </p>
      <Opening.about opening={@opening} mode={@mode} reviewer?={@reviewer?} />
    </footer>
    """
  end

  # ── no selection to show (D1 rows 20–24) ─────────────────────────────────

  attr :state, :map, required: true
  attr :base, :string, required: true
  attr :lemma, :string, required: true
  attr :page, :map, required: true
  attr :card_sources, :list, default: []
  attr :record_path, :string, required: true

  defp state(assigns) do
    ~H"""
    <section
      id="curated-state"
      data-state={@state.kind}
      aria-labelledby="curated-state-heading"
      class="flex flex-col gap-4 border-t border-mist-950/10 py-8 dark:border-white/10"
    >
      <%= if @state.kind == :withheld do %>
        <h2 id="curated-state-heading" class="font-display text-3xl/9 tracking-tight text-pretty">
          <%= if @state.published_on do %>
            A selection published on {date(@state.published_on)} is not shown.
          <% else %>
            A published selection is not shown.
          <% end %>
        </h2>
        <p id="curated-state-why" class="text-lg/7 text-pretty">
          {clauses(@state.reasons)}. Nothing was put in its place.
        </p>
        <%!-- The withheld version's own record (§4 H). --%>
        <.link
          :if={@state[:version]}
          id="curated-state-receipt"
          navigate={"#{@base}/receipt/#{@state.version}"}
          class={["flex min-h-11 w-fit items-center", link_class()]}
        >
          How this page was curated →
        </.link>
        <.assessed
          :if={@state.assessment}
          assessment={@state.assessment}
          lead_in={"last assessed #{@lemma} under the current configuration on"}
        />
      <% else %>
        <h2 id="curated-state-heading" class="font-display text-3xl/9 tracking-tight text-pretty">
          No selection is published for {@lemma}.
        </h2>
        <.assessed :if={@state.kind == :abstained} assessment={@state} lead_in="last assessed it on" />
        <p :if={@state.kind == :none} id="curated-state-why" class="text-lg/7 text-pretty">
          No editor has assessed it yet.
        </p>
      <% end %>
      <%!-- A bare index word holds no dictionary entry yet: no count to give. --%>
      <p :if={@card_sources != []} id="curated-holdings" class="text-base/7 text-pretty">
        This page holds {holdings(@page, @card_sources)}.
      </p>
      <.link
        id="record-inventory-link"
        patch={@record_path}
        class="flex min-h-12 w-full items-center justify-center rounded-xl bg-mist-950 px-4 text-base/6 font-medium text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 sm:w-fit dark:bg-white dark:text-mist-950 dark:focus-visible:outline-white"
      >
        Everything this page holds →
      </.link>
    </section>
    """
  end

  attr :assessment, :map, required: true
  attr :lead_in, :string, required: true

  # The editor's last assessment, in its own words where it stored a reason.
  defp assessed(assigns) do
    editor = %{kind: :model, label: assigns.assessment.editor || ""}

    assigns =
      assigns
      |> assign(:editor, "The " <> String.replace_prefix(editor_phrase(editor), "an ", ""))
      |> assign(
        :cut,
        assigns.assessment.reason &&
          Opening.cut_at(%{kind: :editorial, text: assigns.assessment.reason, author: editor})
      )

    ~H"""
    <p id="curated-state-assessed" class="flex gap-3 text-base/7 text-pretty">
      <Opening.ai_mark class="mt-0.5 size-6 text-[0.625rem]" />
      <span>
        {@editor} {@lead_in} {clock(@assessment.assessed_at)} and chose not to select{cond do
          @assessment.reason -> ":"
          # Withheld for quoting provider text, or the attempt is not found:
          # nothing is said about a reason (#309 review 2).
          @assessment[:reason_withheld?] or not @assessment[:attempt?] -> "."
          true -> ", and gave no reason."
        end}
      </span>
    </p>
    <blockquote
      :if={@assessment.reason}
      id="curated-state-reason"
      class="ml-9 border-l-2 border-mist-950/10 pl-4 text-base/7 text-pretty dark:border-white/10"
    >
      “{@assessment.reason}”<span :if={@cut} class="text-mist-600 dark:text-mist-400"> · cut at {@cut} characters</span>
    </blockquote>
    """
  end

  # ── words ─────────────────────────────────────────────────────────────────

  defp receipt(base, %{origin: :published, composition: %{version: version}})
       when is_integer(version),
       do: "#{base}/receipt/#{version}"

  defp receipt(_base, _opening), do: nil

  # "Inspired by Voltaire · voltaire-whole-entry-v6 · qwen3.5-…": the
  # editor's actor label, as the receipt and the curation screen name it.
  defp persona(%{kind: :model, label: label}) when is_binary(label),
    do: Opening.editor_parts(label).persona

  defp persona(_selector), do: nil

  defp editor_phrase(%{kind: :model} = selector) do
    case persona(selector) do
      nil -> "an AI editor"
      name -> "an AI editor inspired by #{name}"
    end
  end

  # No person's name on a public page (#299 M5).
  defp editor_phrase(_selector), do: "a person"

  defp lens(%{kind: :model}, nil), do: @generic
  defp lens(_selector, persona), do: get_in(@personas, [persona, :sentence])

  # No person's name on a public page (#299 M5): a review is "a person".
  defp status(%{reviewed_by: reviewer, reviewed_on: on}) when is_binary(reviewer),
    do: "Reviewed by a person" <> if(on, do: " · #{date(on)}", else: "")

  defp status(_review), do: "AI-selected · not reviewed by a person"

  defp technical(%{kind: :model, label: label}) when is_binary(label) do
    %{instruction: instruction, model: model} = Opening.editor_parts(label)
    {instruction, model}
  end

  defp technical(_selector), do: {nil, nil}

  defp holdings(page, sources) do
    senses = Enum.reduce(page.cards, 0, &(&2 + (&1.senses || 0)))
    noun = if senses == 1, do: "sense", else: "senses"

    "entries from #{Word.dictionaries(sources)}, #{senses} #{noun}, their quotations, and what discovery found for #{page.headword.lemma}"
  end

  defp clauses(reasons) do
    reasons
    |> Enum.map(&Opening.withheld_reason/1)
    |> Enum.join("; ")
    |> capitalize_first()
  end

  defp capitalize_first(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  defp date(%Date{} = date), do: Calendar.strftime(date, "%-d %B %Y")
  defp date(%DateTime{} = at), do: at |> DateTime.to_date() |> date()
  defp date(%NaiveDateTime{} = at), do: at |> NaiveDateTime.to_date() |> date()

  defp clock(%NaiveDateTime{} = at), do: date(at) <> ", " <> Calendar.strftime(at, "%H:%M UTC")
  defp clock(%DateTime{} = at), do: date(at) <> ", " <> Calendar.strftime(at, "%H:%M UTC")
end
