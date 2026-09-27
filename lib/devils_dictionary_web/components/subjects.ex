defmodule DevilsDictionaryWeb.Subjects do
  @moduledoc """
  What an On page adds to a word page (#219 B3, B5): the authored overview,
  when one belongs to these words, and the Subjects section — one card per
  subject, each linking to its address when the reading mode serves one and
  to its exact identity otherwise.

  Curated and discovered subjects are kept visibly apart. Curated members
  come from an authored overview's current revision, in its order, and are
  the page's editorial choice; discovered ones are what the page's sources
  and names reach, labelled as unreviewed. An association (Putin/poutine) is
  shown as an association, never as the same thing. A draft is marked as a
  draft, a fixture as a fixture, and nothing unpublished is presented as
  public: the state and the link come from `Routing.Subjects`, which asks the
  resolver.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Markdown
  alias DevilsDictionary.Registry.Lexeme

  # ── the overview ─────────────────────────────────────────────────────────

  @doc """
  An authored overview. As the page's `:treatment` it heads the page; as a
  `:choice` it is something else that happens to be at this address, shown
  apart and said to be about other words.
  """
  attr :overview, :map, required: true
  attr :as, :atom, values: [:treatment, :choice], default: :treatment
  attr :subject_paths, :map, default: %{}

  def overview(assigns) do
    members = assigns.overview.members

    assigns =
      assigns
      |> assign(
        :words,
        for(%{kind: :word, lexeme: l} <- members, do: l) |> Enum.uniq_by(& &1.object_id)
      )
      |> assign(:pages, for(%{kind: :page} = m <- members, do: m))
      |> assign(:withheld, Enum.count(members, &(&1.kind == :withheld)))
      |> assign(:discusses, for(%{kind: :subject} = m <- members, do: m))

    ~H"""
    <section
      id={if(@as == :treatment, do: "overview", else: "overview-choice")}
      aria-labelledby={"#{if(@as == :treatment, do: "overview", else: "overview-choice")}-title"}
      class={[
        "flex flex-col gap-4",
        @as == :choice &&
          "rounded-2xl border border-dashed border-mist-950/15 p-5 dark:border-white/15"
      ]}
    >
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <p class="text-sm/7 font-semibold text-mist-700 dark:text-mist-400">
          {if @as == :treatment, do: "An authored page", else: "Also at this address"}
        </p>
        <.mark :if={@overview.draft?} id="overview-draft" kind={:draft} />
      </div>

      <h2
        id={"#{if(@as == :treatment, do: "overview", else: "overview-choice")}-title"}
        class="font-display text-3xl text-balance text-mist-950 dark:text-white"
      >
        {@overview.revision.title}
      </h2>

      <p
        :if={@as == :choice}
        class="max-w-2xl text-base/7 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400"
      >
        An authored page about something else. It shares this address's spelling, not the words
        below, so it is shown apart from them.
      </p>

      <.document :if={@overview.revision.body not in [nil, ""]} class="max-w-[47rem]">
        {Phoenix.HTML.raw(Markdown.to_html(@overview.revision.body, @overview.revision.body_format))}
      </.document>

      <p
        :if={@words != []}
        id={"#{@as}-words"}
        class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400"
      >
        Words it draws on:
        <span :for={{lexeme, i} <- Enum.with_index(@words)}><span :if={i > 0}>, </span><.link
          id={"#{@as}-word-#{lexeme.object_id}"}
          navigate={~p"/words/#{lexeme.object_id}/#{lexeme.slug}"}
          class="text-mist-950 underline decoration-mist-950/20 underline-offset-4 hover:decoration-mist-950 dark:text-white dark:decoration-white/25 dark:hover:decoration-white"
        >{lexeme.lemma}</.link> <span class="text-mist-500">({lexeme.part_of_speech})</span></span>
      </p>

      <p
        :if={@as == :choice and @discusses != []}
        class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400"
      >
        It discusses:
        <span :for={{member, i} <- Enum.with_index(@discusses)}><span :if={i > 0}>, </span><.link
          navigate={@subject_paths[member.object_id]}
          class="text-mist-950 underline decoration-mist-950/20 underline-offset-4 hover:decoration-mist-950 dark:text-white dark:decoration-white/25 dark:hover:decoration-white"
        >{member.label}</.link></span>
      </p>

      <p :if={@pages != []} class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
        See also:
        <span :for={{member, i} <- Enum.with_index(@pages)}><span :if={i > 0}>, </span><.link
          navigate={member.path}
          class="text-mist-950 underline decoration-mist-950/20 underline-offset-4 hover:decoration-mist-950 dark:text-white dark:decoration-white/25 dark:hover:decoration-white"
        >{member.title}</.link></span>
      </p>

      <p :if={@withheld > 0} class="text-base/7 text-mist-500 sm:text-sm/6">
        <span class="tabular-nums">{@withheld}</span>
        {if @withheld == 1, do: "member is", else: "members are"} withheld: not public, withdrawn or no longer an active identity.
      </p>

      <details id={"#{@as}-provenance"} class="group text-base/7 text-mist-500 sm:text-sm/6">
        <summary class="w-fit cursor-pointer underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">
          About this page
        </summary>
        <dl class="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1">
          <dt class="font-medium text-mist-700 dark:text-mist-300">Address</dt>
          <dd class="font-mono break-all">{URI.decode(@overview.address)}</dd>
          <dt class="font-medium text-mist-700 dark:text-mist-300">Revision</dt>
          <dd class="tabular-nums">{@overview.revision.revision_number}</dd>
          <dt class="font-medium text-mist-700 dark:text-mist-300">Written by</dt>
          <dd>{@overview.author || "—"}</dd>
          <dt class="font-medium text-mist-700 dark:text-mist-300">Reviewed by</dt>
          <dd>{@overview.reviewer || "not reviewed"}</dd>
          <dt class="font-medium text-mist-700 dark:text-mist-300">Publication</dt>
          <dd>{@overview.page.publication_state}</dd>
        </dl>
      </details>
    </section>
    """
  end

  @doc "The authored pages elsewhere that name this page's words."
  attr :overviews, :list, required: true

  def linked_overviews(assigns) do
    ~H"""
    <p
      :if={@overviews != []}
      id="linked-overviews"
      class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400"
    >
      Authored pages about these words:
      <span :for={{overview, i} <- Enum.with_index(@overviews)}><span :if={i > 0}>, </span><.link
        id={"linked-overview-#{overview.page_id}"}
        navigate={overview.path}
        class="text-mist-950 underline decoration-mist-950/20 underline-offset-4 hover:decoration-mist-950 dark:text-white dark:decoration-white/25 dark:hover:decoration-white"
      >{overview.title}</.link><span :if={overview.draft?} class="text-amber-800 dark:text-amber-300"> (draft)</span></span>
    </p>
    """
  end

  # ── the section ──────────────────────────────────────────────────────────

  @doc """
  The Subjects section. `subjects` is `Routing.Subjects.cards/5`'s answer;
  `members` the treatment overview's resolved members, when there is one,
  so the curated cards keep its order and relationships.
  """
  attr :subjects, :map, required: true
  attr :members, :list, default: []

  def section(assigns) do
    cards =
      Map.new(
        assigns.subjects.curated |> Enum.reject(&match?({:withheld, _}, &1)),
        &{&1.object_id, &1}
      )

    curated =
      for %{kind: :subject, relationship: :discusses_subject, object_id: id} <- assigns.members,
          card = cards[id],
          do: card

    associations =
      for %{kind: :subject, relationship: :editorial_association, object_id: id} = member <-
            assigns.members,
          card = cards[id],
          do: Map.put(card, :rationale, member.rationale)

    withheld =
      Enum.count(assigns.subjects.curated, &match?({:withheld, _}, &1)) +
        Enum.count(
          assigns.members,
          &(&1.kind == :withheld and
              &1.relationship in [:discusses_subject, :editorial_association])
        )

    all = curated ++ associations ++ assigns.subjects.discovered

    assigns =
      assigns
      |> assign(:curated, curated)
      |> assign(:associations, associations)
      |> assign(:discovered, assigns.subjects.discovered)
      |> assign(
        :more,
        max(assigns.subjects.discovered_total - length(assigns.subjects.discovered), 0)
      )
      |> assign(:withheld, withheld)
      |> assign(:count, length(all))
      |> assign(:addressed, Enum.count(all, &(&1.state == :addressed)))

    ~H"""
    <.slab :if={@count > 0 or @withheld > 0} id="subjects" title="Subjects">
      <:meta>
        <span class="tabular-nums">{@count}</span>
        {if @count == 1, do: "subject", else: "subjects"} ·
        <span class="tabular-nums">{@addressed}</span>
        addressed
      </:meta>

      <div class="flex flex-col gap-6 py-4">
        <div :if={@curated != []} id="subjects-curated" class="flex flex-col gap-3">
          <p class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
            Chosen for this page, in its editors' order.
          </p>
          <ul role="list" class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <li :for={card <- @curated}><.card card={card} group="curated" /></li>
          </ul>
        </div>

        <div :if={@associations != []} id="subjects-associations" class="flex flex-col gap-3">
          <p class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
            Associations: linked on purpose, and not the same thing.
          </p>
          <ul role="list" class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <li :for={card <- @associations}><.card card={card} group="association" /></li>
          </ul>
        </div>

        <p :if={@withheld > 0} id="subjects-withheld" class="text-base/7 text-mist-500 sm:text-sm/6">
          <span class="tabular-nums">{@withheld}</span>
          chosen {if @withheld == 1, do: "subject is", else: "subjects are"} withheld: not public, withdrawn or no longer an active identity.
        </p>

        <div :if={@discovered != []} id="subjects-discovered" class="flex flex-col gap-3">
          <p class="text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
            Found by name and by the sources. Not reviewed: a shared name is not a shared identity.
          </p>
          <ul role="list" class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <li :for={card <- @discovered}><.card card={card} group="discovered" /></li>
          </ul>
          <p :if={@more > 0} id="subjects-more" class="text-base/7 text-mist-500 sm:text-sm/6">
            <span class="tabular-nums">{@more}</span> more with this name not shown.
          </p>
        </div>
      </div>
    </.slab>
    """
  end

  @doc "One subject: a card the reader opens, at its address or its identity."
  attr :card, :map, required: true
  attr :group, :string, required: true

  def card(assigns) do
    ~H"""
    <article
      id={"subject-#{@group}-#{@card.object_id}"}
      data-state={@card.state}
      class="relative flex h-full flex-col gap-1.5 rounded-xl bg-white/70 p-4 ring-1 ring-mist-950/10 has-[a:focus-visible]:outline-2 has-[a:focus-visible]:outline-offset-2 has-[a:focus-visible]:outline-mist-950 dark:bg-white/2.5 dark:ring-white/10 dark:has-[a:focus-visible]:outline-white"
    >
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <p class="text-sm/6 font-semibold text-mist-700 dark:text-mist-400">
          {@card.family_label || "Subject"}
        </p>
        <.mark :if={@card.draft?} kind={:draft} />
        <.mark :if={@card.fixture} kind={:fixture} title={@card.fixture} />
      </div>

      <h3 class="text-base/7 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
        <.link
          id={"subject-#{@group}-#{@card.object_id}-link"}
          navigate={@card.path}
          class="break-words underline decoration-mist-950/20 underline-offset-4 after:absolute after:inset-0 after:rounded-xl hover:decoration-mist-950 focus-visible:outline-none dark:decoration-white/25 dark:hover:decoration-white"
        >
          {@card.label}
        </.link>
      </h3>

      <p
        :if={@card.description}
        class="line-clamp-2 text-base/7 text-pretty text-mist-600 sm:text-sm/6 dark:text-mist-400"
      >
        {@card.description}
      </p>

      <p
        :if={@card[:rationale]}
        class="text-base/7 text-pretty text-mist-600 italic sm:text-sm/6 dark:text-mist-400"
      >
        {@card.rationale}
      </p>

      <div class="mt-auto pt-1">
        <.state card={@card} />
      </div>
    </article>
    """
  end

  attr :card, :map, required: true

  defp state(%{card: %{state: :addressed}} = assigns) do
    ~H"""
    <p class="flex min-w-0 items-center gap-1.5 text-base/7 text-mist-500 sm:text-sm/6">
      <.icon name="hero-map-pin-mini" class="size-4 shrink-0" />
      <span class="truncate font-mono">{URI.decode(@card.address)}</span>
    </p>
    """
  end

  defp state(%{card: %{state: pending}} = assigns)
       when pending in [:not_yet_public, :awaiting_review, :identity_review, :withdrawn] do
    ~H"""
    <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-base/7 text-mist-500 sm:text-sm/6">
      <span class="inline-flex items-center gap-1 rounded-full bg-amber-500/10 py-0.5 pr-2 pl-1 font-medium text-amber-800 dark:bg-amber-400/10 dark:text-amber-300">
        <.icon name="hero-clock-mini" class="size-4 shrink-0" />
        {state_label(@card.state)}
      </span>
      <span :if={@card.state == :awaiting_review and @card.candidate_families != []}>
        {families(@card.candidate_families)}
      </span>
    </p>
    """
  end

  defp state(assigns) do
    ~H"""
    <p class="text-base/7 text-mist-500 sm:text-sm/6">{state_label(@card.state)}</p>
    """
  end

  attr :kind, :atom, values: [:draft, :fixture], required: true
  attr :id, :string, default: nil
  attr :title, :string, default: nil

  # A mark on something that is not what it would be in public: a draft page,
  # or a fixture made for a demonstration rather than taken from the corpus.
  defp mark(assigns) do
    ~H"""
    <span
      id={@id}
      title={@title}
      class="rounded-full border border-dashed border-amber-600/60 px-2 py-0.5 text-sm/5 font-medium text-amber-800 dark:border-amber-400/50 dark:text-amber-200"
    >
      {if @kind == :draft, do: "Draft", else: "Fixture"}
    </span>
    """
  end

  defp state_label(:addressed), do: "Addressed"
  defp state_label(:not_yet_public), do: "Not yet public"
  defp state_label(:withdrawn), do: "Withdrawn"
  defp state_label(:no_address), do: "No public address yet"
  defp state_label(:awaiting_review), do: "Awaiting classification review"
  defp state_label(:identity_review), do: "Awaiting identity review"
  defp state_label(:source_page), do: "A source page, not a subject"
  defp state_label(:unclassified), do: "Unclassified"

  defp families(families) do
    labels = Enum.map(families, &(DevilsDictionary.Routing.Address.label(&1) || &1))

    case labels do
      [one] -> one
      many -> Enum.join(Enum.drop(many, -1), ", ") <> " or " <> List.last(many)
    end
  end

  @doc "The exact-word route for a lexeme, by identity."
  def word_path(%Lexeme{object_id: id, slug: slug}), do: ~p"/words/#{id}/#{slug}"
end
