defmodule DevilsDictionaryWeb.CurationLive do
  @moduledoc """
  The owner's curation queue, `/ops/curation` (#257 §2.1, #253 §6).

  An operator surface: 404 through the tunnel like every `/ops` page
  (`ProxyGuard`), and a reviewer's (`UserAuth.require_reviewer/2` answers any
  other account 403; `:require_reviewer` guards a socket that live-navigates
  in). It lists the pilot pages (`:curation_pilot_pages`, #253 D2) with what
  each page's composition is now and which kinds of candidate its page
  offers, and the published compositions and their withheld items. Stale
  and Proposed are #254 P5's and P6's: drawn, disabled, with nothing behind
  them.

  Every figure is read: the page as `WordPage.build/2` builds it, its
  candidates (`Curation.Candidates`), its composition under the resolved
  global default (`Compositions.active/4` over the page's words, as the
  reader finds it) and `Published.current/1`. Nothing is written, nothing is
  fetched, and no job is queued: building a page here is not a visit.

  `page/1` and `record/2` are shared with the editor
  (`CurationLive.Editor`).
  """
  use DevilsDictionaryWeb, :live_view

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Candidates,
    Composition,
    CompositionMembership,
    CompositionPublication,
    CompositionVersion,
    Compositions,
    Configurations,
    Published
  }

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.Repo

  on_mount {DevilsDictionaryWeb.UserAuth, :require_reviewer}

  @marks ~w(B J Q W E)
  @tabs ~w(pilot published withheld)

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Curation", rows: nil, published: [], stats: nil)
    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "pilot"
    {:noreply, assign(socket, :tab, tab)}
  end

  # The pages are built once the socket is up, so the first paint is the
  # chrome and the pilot list's skeleton, not ten page builds twice.
  defp load(socket) do
    rows = Enum.map(pilot_pages(), &row/1)
    published = published()

    assign(socket,
      rows: rows,
      published: published,
      stats: %{
        pilot: length(rows),
        published: length(published),
        withheld: published |> Enum.map(&length(&1.withheld)) |> Enum.sum()
      }
    )
  end

  @doc "The configured pilot pages' slugs (#253 D2)."
  def pilot_pages, do: Application.get_env(:devils_dictionary, :curation_pilot_pages, [])

  @doc """
  The On page a slug addresses, built as the reader builds it, for the
  public: its words are the composition's scope.
  """
  def page(slug), do: slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

  @doc """
  Where a page's curation stands, from the record:

      %{configuration, configuration_version, composition, versions,
        receipts, latest, published_id, state, overlapping}

  `state` is `:unconfigured` (no enabled global default), `:no_scope` (no
  words, or words in several languages), `:never` (no version yet),
  `:draft`, `:published` or `:withdrawn` (the last receipt took it down).
  `overlapping` lists the active compositions whose words overlap this
  page's when it has none of its own: the record will not provision beside
  them (K3).
  """
  def record(candidates) do
    base = %{
      configuration: nil,
      configuration_version: nil,
      composition: nil,
      versions: [],
      receipts: [],
      latest: nil,
      published_id: nil,
      state: :unconfigured,
      overlapping: []
    }

    case {Configurations.resolve_default(), candidates.scope} do
      {{:ok, %{configuration: c, version: cv}}, %{language: language, ids: [_ | _] = ids}}
      when is_binary(language) ->
        composition =
          Compositions.active(c.id, :lexical_page, language, Compositions.signature(ids))

        versions = if composition, do: versions(composition.id), else: []
        receipts = if composition, do: receipts(composition.id), else: []
        published_id = composition && composition.current_published_version_id

        %{
          base
          | configuration: c,
            configuration_version: cv,
            composition: composition,
            versions: versions,
            receipts: receipts,
            latest: List.first(versions),
            published_id: published_id,
            state: state(versions, receipts, published_id),
            overlapping: if(composition, do: [], else: overlapping(c.id, language, ids))
        }

      {{:ok, %{configuration: c, version: cv}}, _no_scope} ->
        %{base | configuration: c, configuration_version: cv, state: :no_scope}

      _unavailable ->
        base
    end
  end

  defp state([], _receipts, _published), do: :never
  defp state(_versions, _receipts, id) when is_integer(id), do: :published
  defp state(_versions, [%{action: :withdraw} | _], nil), do: :withdrawn
  defp state(_versions, _receipts, nil), do: :draft

  # Every version, newest first, with its items and its latest review.
  defp versions(composition_id) do
    versions =
      Repo.all(
        from v in CompositionVersion,
          where: v.composition_id == ^composition_id,
          order_by: [desc: v.version]
      )

    ids = Enum.map(versions, & &1.id)

    reviews =
      Repo.all(
        from r in DevilsDictionary.Curation.CompositionReview,
          where: r.composition_version_id in ^ids,
          order_by: [asc: r.id]
      )
      |> Enum.group_by(& &1.composition_version_id)

    actors = actor_labels(Enum.map(versions, & &1.created_by_actor_id))

    Enum.map(versions, fn v ->
      %{
        version: v,
        items: Compositions.items(v.id),
        review: reviews |> Map.get(v.id, []) |> List.last(),
        author: actors[v.created_by_actor_id]
      }
    end)
  end

  # Every publication receipt, newest first, with who acted.
  defp receipts(composition_id) do
    receipts =
      Repo.all(
        from p in CompositionPublication,
          where: p.composition_id == ^composition_id,
          order_by: [desc: p.id]
      )

    actors = actor_labels(Enum.map(receipts, & &1.actor_id))
    Enum.map(receipts, &Map.put(&1, :actor_label, actors[&1.actor_id]))
  end

  defp actor_labels(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from a in DevilsDictionary.Sources.Actor, where: a.id in ^ids)
    |> Map.new(&{&1.id, Compositions.author_label(&1)})
  end

  defp overlapping(configuration_id, language, ids) do
    Repo.all(
      from m in CompositionMembership,
        join: c in Composition,
        on: c.id == m.composition_id,
        where:
          c.curation_configuration_id == ^configuration_id and c.scope_kind == :lexical_page and
            c.language_tag == ^language and c.state == :active and m.object_id in ^ids,
        distinct: true,
        select: c.id
    )
  end

  # ── the rows ─────────────────────────────────────────────────────────────

  defp row(slug) do
    page = page(slug)
    candidates = Candidates.for_page(page)
    record = record(candidates)

    %{
      slug: slug,
      lemma: page.headword.lemma || slug,
      scope: parts(candidates.scope.lexemes),
      record: record,
      marks: Candidates.marks(candidates),
      shown: shown(record)
    }
  end

  # What is on the page now: the published version and its highlight count.
  defp shown(%{published_id: id, versions: versions}) when is_integer(id) do
    case Enum.find(versions, &(&1.version.id == id)) do
      nil ->
        nil

      v ->
        %{version: v.version.version, highlights: Enum.count(v.items, &(&1.role == :highlight))}
    end
  end

  defp shown(_record), do: nil

  # Every published composition of the global default, with what its page
  # withholds now.
  defp published do
    case Configurations.resolve_default() do
      {:ok, %{configuration: c}} ->
        compositions =
          Repo.all(
            from c in Composition,
              where:
                c.curation_configuration_id == ^c.id and c.state == :active and
                  not is_nil(c.current_published_version_id),
              order_by: c.id
          )

        Enum.map(compositions, fn composition ->
          members = Compositions.member_ids(composition.id)

          lexemes =
            Repo.all(
              from l in Lexeme,
                where: l.object_id in ^members,
                order_by: l.object_id,
                select: %{id: l.object_id, lemma: l.lemma, slug: l.slug, pos: l.part_of_speech}
            )

          {withheld, version} =
            case Published.current(composition.id) do
              {:ok, published} -> {published.withheld, published.version.version}
              {:withheld, reasons} -> {Enum.map(reasons, &%{role: :version, reason: &1}), nil}
              _other -> {[], nil}
            end

          %{
            composition: composition,
            lexemes: lexemes,
            slug: first_of(lexemes, :slug),
            version: version,
            withheld: withheld
          }
        end)

      _unavailable ->
        []
    end
  end

  defp first_of([lexeme | _], field), do: Map.fetch!(lexeme, field)
  defp first_of([], _field), do: nil

  @doc "A scope's parts of speech as the queue prints them: `noun · verb · name`."
  def parts(lexemes) do
    lexemes |> Enum.map(&(&1.pos || "word")) |> Enum.uniq() |> Enum.join(" · ")
  end

  # ── rendering ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.section
        id="curation"
        eyebrow="Operations"
        headline="Curation"
        subheadline="Each word page's curated opening: who leads, up to three highlights, and why. Curate a page, publish it, withdraw it. Nothing here is fetched or generated; every candidate is something the record already holds."
      >
        <nav
          id="curation-tabs"
          aria-label="Queues"
          class="-mt-4 flex flex-wrap items-center gap-2"
        >
          <.tab id="tab-pilot" tab="pilot" current={@tab} count={@stats && @stats.pilot}>
            Pilot pages
          </.tab>
          <.tab id="tab-published" tab="published" current={@tab} count={@stats && @stats.published}>
            Published
          </.tab>
          <.tab id="tab-withheld" tab="withheld" current={@tab} count={@stats && @stats.withheld}>
            Withheld items
          </.tab>
          <span
            id="tab-stale"
            aria-disabled="true"
            title="Freshness is #254 P5's"
            class="inline-flex min-h-11 items-center gap-2 rounded-full px-3 text-sm/7 text-mist-400 ring-1 ring-mist-950/10 ring-inset sm:min-h-9 dark:text-mist-500 dark:ring-white/10"
          >
            Stale <span class="tabular-nums">—</span> <span class="text-xs/5">P5</span>
          </span>
          <span
            id="tab-proposed"
            aria-disabled="true"
            title="Proposals are #254 P6's"
            class="inline-flex min-h-11 items-center gap-2 rounded-full px-3 text-sm/7 text-mist-400 ring-1 ring-mist-950/10 ring-inset sm:min-h-9 dark:text-mist-500 dark:ring-white/10"
          >
            Proposed <span class="tabular-nums">—</span> <span class="text-xs/5">P6</span>
          </span>
        </nav>

        <p :if={is_nil(@rows)} id="curation-loading" class="text-sm/7 text-mist-500">
          Reading the pilot pages…
        </p>

        <div :if={@rows && @tab == "pilot"} id="curation-pilot" class="mt-2">
          <div
            aria-hidden="true"
            class="hidden gap-x-6 pb-2 text-xs/5 font-semibold tracking-wide text-mist-500 uppercase sm:grid sm:grid-cols-[10rem_minmax(0,1fr)_auto]"
          >
            <span>Word · scope</span>
            <span class="flex gap-6">
              <span class="w-56">State</span><span class="w-34">Candidates</span><span>Shown</span>
            </span>
            <span class="w-20"></span>
          </div>
          <ul
            id="curation-pages"
            role="list"
            class="divide-y divide-mist-950/10 border-y border-mist-950/10 dark:divide-white/10 dark:border-white/10"
          >
            <li
              :for={row <- @rows}
              id={"curation-page-#{row.slug}"}
              class="grid grid-cols-1 gap-x-6 gap-y-1 py-4 sm:grid-cols-[10rem_minmax(0,1fr)_auto] sm:items-center"
            >
              <div class="min-w-0">
                <p class="font-display text-xl/7 text-mist-950 dark:text-white">{row.lemma}</p>
                <p class="text-sm/6 text-mist-500">{row.scope}</p>
              </div>
              <div class="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-center sm:gap-6">
                <p
                  id={"curation-page-#{row.slug}-state"}
                  class="text-sm/6 text-mist-700 sm:w-56 dark:text-mist-300"
                >
                  {state_label(row.record)}
                </p>
                <p
                  id={"curation-page-#{row.slug}-marks"}
                  class="flex w-34 gap-1 font-mono text-sm/6"
                  aria-label={marks_label(row.marks)}
                >
                  <span
                    :for={mark <- marks()}
                    data-mark={mark}
                    data-present={to_string(row.marks[mark])}
                    class={[
                      "inline-flex size-6 items-center justify-center rounded",
                      row.marks[mark] && "bg-mist-950 text-white dark:bg-white dark:text-mist-950",
                      !row.marks[mark] && "text-mist-300 dark:text-mist-600"
                    ]}
                  >
                    {if row.marks[mark], do: mark, else: "·"}
                  </span>
                </p>
                <p class="text-sm/6 text-mist-600 tabular-nums dark:text-mist-400">
                  <%= if row.shown do %>
                    v{row.shown.version} · {row.shown.highlights} {if row.shown.highlights == 1,
                      do: "highlight",
                      else: "highlights"}
                  <% else %>
                    —
                  <% end %>
                </p>
              </div>
              <span :if={row.record.state == :no_scope} class="w-20 text-sm/6 text-mist-400">—</span>
              <.button_link
                :if={row.record.state != :no_scope}
                id={"curation-page-#{row.slug}-open"}
                navigate={~p"/ops/curation/on/#{row.slug}"}
                variant={if row.record.state == :published, do: "soft", else: "solid"}
                class="min-h-11 justify-self-start sm:min-h-0"
              >
                {if row.record.state in [:never, :no_scope], do: "Curate", else: "Open"}
              </.button_link>
            </li>
          </ul>
          <p
            id="curation-marks-key"
            class="mt-4 text-sm/7 text-pretty text-mist-600 dark:text-mist-400"
          >
            Candidates: <b class="font-mono">B</b>
            Bierce entry · <b class="font-mono">J</b>
            Johnson entry · <b class="font-mono">Q</b>
            sense quotation · <b class="font-mono">W</b>
            catalog work · <b class="font-mono">E</b>
            accepted exemplar.
          </p>
        </div>

        <div :if={@rows && @tab == "published"} id="curation-published">
          <p :if={@published == []} class="text-sm/7 text-mist-500">Nothing is published yet.</p>
          <ul
            :if={@published != []}
            role="list"
            class="divide-y divide-mist-950/10 border-y border-mist-950/10 dark:divide-white/10 dark:border-white/10"
          >
            <li
              :for={p <- @published}
              id={"curation-published-#{p.composition.id}"}
              class="flex flex-wrap items-center justify-between gap-4 py-4"
            >
              <div>
                <p class="font-display text-xl/7 text-mist-950 dark:text-white">
                  {first_of(p.lexemes, :lemma)}
                </p>
                <p class="text-sm/6 text-mist-500">
                  composition #{p.composition.id} · {parts(p.lexemes)} · v{p.version || "—"}
                </p>
              </div>
              <.button_link
                :if={p.slug}
                navigate={~p"/ops/curation/on/#{p.slug}"}
                variant="soft"
                class="min-h-11 sm:min-h-0"
              >
                Open
              </.button_link>
            </li>
          </ul>
        </div>

        <div :if={@rows && @tab == "withheld"} id="curation-withheld">
          <p :if={Enum.all?(@published, &(&1.withheld == []))} class="text-sm/7 text-mist-500">
            No published item is withheld. Every published item is still eligible.
          </p>
          <ul role="list" class="flex flex-col gap-4">
            <li
              :for={p <- Enum.reject(@published, &(&1.withheld == []))}
              id={"curation-withheld-#{p.composition.id}"}
            >
              <p class="font-medium text-mist-950 dark:text-white">
                {first_of(p.lexemes, :lemma)} · composition #{p.composition.id}
              </p>
              <ul role="list" class="mt-1 text-sm/6 text-mist-700 dark:text-mist-300">
                <li :for={w <- p.withheld}>
                  {withheld_label(w)}: {DevilsDictionaryWeb.Opening.withheld_reason(w.reason)}
                  <code class="text-mist-500">({w.reason})</code>
                </li>
              </ul>
            </li>
          </ul>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :count, :integer, default: nil
  slot :inner_block, required: true

  defp tab(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={~p"/ops/curation?#{%{tab: @tab}}"}
      aria-current={if @tab == @current, do: "page"}
      class={[
        "inline-flex min-h-11 items-center gap-2 rounded-full px-3 text-sm/7 sm:min-h-9",
        @tab == @current && "bg-mist-950 text-white dark:bg-mist-300 dark:text-mist-950",
        @tab != @current &&
          "bg-mist-950/10 text-mist-950 hover:bg-mist-950/15 dark:bg-white/10 dark:text-white"
      ]}
    >
      {render_slot(@inner_block)}
      <span class="tabular-nums">{if is_nil(@count), do: "…", else: @count}</span>
    </.link>
    """
  end

  defp marks, do: @marks

  defp marks_label(marks) do
    names = %{
      "B" => "Bierce entry",
      "J" => "Johnson entry",
      "Q" => "sense quotation",
      "W" => "catalog work",
      "E" => "accepted exemplar"
    }

    case for(m <- @marks, marks[m], do: names[m]) do
      [] -> "No candidates"
      present -> "Candidates: " <> Enum.join(present, ", ")
    end
  end

  @doc "A page's curation state as the queue and the editor print it."
  def state_label(%{state: :unconfigured}), do: "no enabled curation configuration"
  def state_label(%{state: :no_scope}), do: "no words to curate"
  def state_label(%{state: :never, overlapping: [_ | _]}), do: "shares a composition"
  def state_label(%{state: :never}), do: "never curated"

  def state_label(%{state: :draft, latest: latest}),
    do: "draft v#{latest.version.version} · not published"

  def state_label(%{state: :published, receipts: [receipt | _]}),
    do: "published #{short_date(receipt.committed_at)}"

  def state_label(%{state: :published}), do: "published"

  def state_label(%{state: :withdrawn, receipts: [receipt | _]}),
    do: "withdrawn #{short_date(receipt.committed_at)} · “#{receipt.reason}”"

  @doc "A date as the queue writes one: *24 Oct*."
  def short_date(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b")

  defp withheld_label(%{role: :lead}), do: "The lead"
  defp withheld_label(%{role: :highlight, position: n}), do: "Highlight #{n}"
  defp withheld_label(%{role: :version}), do: "The whole version"
end
