defmodule DevilsDictionaryWeb.ScopeLive do
  @moduledoc """
  Scope browse (#69 §6 W3, scorecard row **U5**): the taxonomy on the left, the
  words on the right, one glyph per source, and filters that answer "who
  bothered to define what".

  Every badge is `lexemes.source_ids`, the array `Health.coverage/2` reads, so
  what this page shows and what `mix dd.health` prints are the same number. The
  page says so out loud, and `scope_live_test.exs` asserts it per source.

  All state — the query, the filters, the sort, the page, the selected taxon —
  lives in the query string and is read in `handle_params`. A developer surface
  that cannot be linked to is half a surface.

  The tree drills down rather than expanding in place: the breadcrumb is
  `Encyclopedia.taxon_chain/2` walking up from the selected node, the rows below
  it are `taxon_children/3` walking down. One level is one query, the URL stays
  short, and the widest case — Animalia itself — is 224 ms, which is why the
  panel is loaded with `assign_async` and the words do not wait for it.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.{Encyclopedia, Health, Lexicon, Sources}

  @states ~w(bare enriched disputed)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    scope = Lexicon.get_scope_by_slug!(slug)
    sources = Enum.sort_by(Sources.list_sources(), &tier_order(&1.tier))

    {:ok,
     assign(socket,
       page_title: scope.name || slug,
       scope: scope,
       sources: sources,
       attesting: Enum.reject(sources, &(&1.kind == :knowledge_graph)),
       taxon_root: scope.rules["wikidata_root"],
       coverage: nil
     )}
  rescue
    Ecto.NoResultsError ->
      {:ok, socket |> put_flash(:error, "No such scope.") |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)
    slug = socket.assigns.scope.slug
    page = Lexicon.browse(slug, Keyword.new(filters))
    qid = filters[:taxon]

    scope = socket.assigns.scope

    {:noreply,
     socket
     |> assign(filters: filters, page: page)
     |> assign_async(:tree, fn -> {:ok, %{tree: tree(qid, scope)}} end)
     |> assign_async(:coverage, fn -> {:ok, %{coverage: coverage(slug)}} end)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{q: params["q"], sort: params["sort"], page: nil})}
  end

  # The chip's value travels as `phx-value-slug`, never `phx-value-value`:
  # LiveView's JS reads the `phx-value-*` attributes and then sets
  # `meta.value = el.value`, so on a <button> a key called `value` arrives as
  # the button's own empty value and the chip does nothing (S4 audit, #70 S4c).
  # LiveViewTest's `render_click/1` cannot see this — it skips the JS.
  @impl true
  def handle_event("toggle", %{"kind" => kind, "slug" => slug}, socket) do
    key = String.to_existing_atom(kind)
    current = socket.assigns.filters[key] || []

    next =
      if slug in current, do: List.delete(current, slug), else: Enum.sort([slug | current])

    {:noreply, patch(socket, %{kind => Enum.join(next, ","), page: nil})}
  end

  @impl true
  def handle_event("state", %{"state" => state}, socket) do
    current = to_string(socket.assigns.filters[:state])
    {:noreply, patch(socket, %{state: if(current == state, do: nil, else: state), page: nil})}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/s/#{socket.assigns.scope.slug}")}
  end

  defp patch(socket, changes) do
    params =
      socket.assigns.filters
      |> to_params()
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> compact()

    push_patch(socket, to: ~p"/s/#{socket.assigns.scope.slug}?#{params}")
  end

  # Only what a reader would type: no empty keys, no `page=1`, no `false`.
  defp compact(params) do
    params |> Enum.reject(fn {_k, v} -> v in [nil, false, "", []] end) |> Map.new()
  end

  defp page_params(filters, page) do
    filters |> Keyword.put(:page, page) |> to_params() |> compact()
  end

  defp to_params(filters) do
    %{
      "q" => filters[:q],
      "has" => Enum.join(filters[:has] || [], ","),
      "missing" => Enum.join(filters[:missing] || [], ","),
      "state" => filters[:state] && to_string(filters[:state]),
      "sort" => to_string(filters[:sort]),
      "taxon" => filters[:taxon],
      "page" => if(filters[:page] > 1, do: to_string(filters[:page]), else: nil)
    }
  end

  # A comma-separated list rather than `has[]=`: the URL is meant to be read and
  # pasted, and a developer surface's URL is part of its interface.
  defp filters(params) do
    [
      q: presence(params["q"]),
      has: slugs(params["has"]),
      missing: slugs(params["missing"]),
      state: state(params["state"]),
      sort: sort(params["sort"]),
      taxon: presence(params["taxon"]),
      page: page(params["page"])
    ]
  end

  defp presence(nil), do: nil

  defp presence(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp slugs(nil), do: []

  defp slugs(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.sort()
  end

  defp state(value) when value in @states, do: String.to_existing_atom(value)
  defp state(_value), do: nil

  defp sort("coverage"), do: :coverage
  defp sort(_value), do: :lemma

  defp page(value) do
    case Integer.parse(value || "1") do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp tier_order(:aristocracy), do: 0
  defp tier_order(:middle), do: 1
  defp tier_order(:plebs), do: 2
  defp tier_order(_other), do: 3

  # The rail is rooted in the scope's own `wikidata_root`, not in Animalia. A
  # scope without one (`emotions`, built from a WordNet root alone) has no
  # taxonomy to walk and the aside is not rendered at all — asking for Q729
  # there would draw the animal kingdom with fifteen zero-count children.
  defp tree(qid, scope) do
    case scope.rules["wikidata_root"] do
      nil ->
        nil

      root ->
        qid = qid || root

        %{
          here: Encyclopedia.get_concept_by_qid(qid),
          path: path_to(qid, root),
          children: Encyclopedia.taxon_children(qid, scope.slug)
        }
    end
  end

  defp path_to(root, root), do: []

  defp path_to(qid, _root) do
    case Encyclopedia.get_concept_by_qid(qid) do
      nil -> []
      concept -> concept |> Encyclopedia.taxon_chain() |> Enum.reverse()
    end
  end

  # The figure the badges must agree with, read from the same function the
  # scorecard grades A5 on — plus the graph's own figure, which is not
  # attestation: Wikidata links words to things (`concept_links`), it never
  # enters `source_ids`, so its badge and its count mean "linked".
  defp coverage(scope_slug) do
    attested =
      for source <- Sources.list_sources(),
          source.kind != :knowledge_graph,
          into: %{},
          do: {source.slug, Health.coverage(scope_slug, source.slug).covered}

    %{attested: attested, linked: Lexicon.Browse.linked_count(scope_slug)}
  end

  defp badge_on?(%{kind: :knowledge_graph}, row), do: row.concept != nil
  defp badge_on?(source, row), do: source.id in row.source_ids

  defp badge_title(%{kind: :knowledge_graph} = source, row) do
    if badge_on?(source, row), do: "linked", else: "unlinked"
  end

  defp badge_title(source, row) do
    if badge_on?(source, row), do: "attests", else: "silent"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section
        id="scope"
        eyebrow="Scope"
        headline={@scope.name || @scope.slug}
        subheadline="A scope is a row and a filter. Each word carries one glyph per source that attests it — the same lexemes.source_ids array mix dd.health counts, so the badges and the scorecard cannot disagree. Wikidata's glyph means linked: it attests things, not words."
      >
        <div class="flex flex-col gap-8">
          <.form for={%{}} phx-change="filter" phx-submit="filter" id="scope-filters">
            <div class="flex flex-col gap-4 sm:flex-row sm:items-end">
              <div class="grow">
                <.input
                  type="text"
                  name="q"
                  value={@filters[:q] || ""}
                  label={"Search within #{@scope.slug}"}
                  placeholder="oyster"
                  phx-debounce="300"
                />
              </div>
              <div class="sm:w-56">
                <.input
                  type="select"
                  name="sort"
                  value={to_string(@filters[:sort])}
                  label="Sort"
                  options={[{"By word", "lemma"}, {"By coverage", "coverage"}]}
                />
              </div>
            </div>
          </.form>

          <div class="flex flex-col gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-sm/7 text-mist-700 dark:text-mist-400">has</span>
              <.chip
                :for={source <- @attesting}
                id={"filter-has-#{source.slug}"}
                on={source.slug in (@filters[:has] || [])}
                click="toggle"
                values={[kind: "has", slug: source.slug]}
              >
                <span class={tier_class(source.tier)}>{tier_glyph(source.tier)}</span>
                {source.slug}
              </.chip>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <span class="text-sm/7 text-mist-700 dark:text-mist-400">missing</span>
              <.chip
                :for={source <- @attesting}
                id={"filter-missing-#{source.slug}"}
                on={source.slug in (@filters[:missing] || [])}
                click="toggle"
                values={[kind: "missing", slug: source.slug]}
              >
                {source.slug}
              </.chip>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <span class="text-sm/7 text-mist-700 dark:text-mist-400">state</span>
              <.chip
                :for={{state, label} <- state_filters()}
                id={"filter-state-#{state}"}
                on={to_string(@filters[:state]) == state}
                click="state"
                values={[state: state]}
              >
                {label}
              </.chip>
              <.button
                :if={any_filter?(@filters)}
                phx-click="clear"
                variant="plain"
                id="filter-clear"
              >
                clear
              </.button>
            </div>
          </div>

          <div class="flex flex-col gap-2 border-t border-mist-950/10 pt-4 dark:border-white/10">
            <p id="scope-count" class="text-sm/7 text-mist-700 dark:text-mist-400">
              <strong class="text-mist-950 dark:text-white">{number(@page.total)}</strong>
              words{filter_summary(@filters)} · page {@page.page} of {number(@page.pages)}
            </p>
            <.async_result :let={coverage} assign={@coverage}>
              <:loading><span class="text-sm/7 text-mist-500">counting…</span></:loading>
              <:failed :let={_}><span class="text-sm/7 text-mist-500">—</span></:failed>
              <%!-- A wrapping flex row rather than inline spans: at 375 px the
              inline version ran past the column and `main`'s clip swallowed the
              last two counts, which on a page whose whole point is the counts is
              the worst place to lose two. --%>
              <div
                id="scope-coverage"
                class="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm/7 text-mist-500"
              >
                <span>attested by</span>
                <span :for={source <- @attesting} class="whitespace-nowrap">
                  <span class={tier_class(source.tier)}>{tier_glyph(source.tier)}</span>
                  {source.slug} {number(coverage.attested[source.slug])}
                </span>
                <span :for={source <- @sources -- @attesting} class="whitespace-nowrap">
                  · linked to <span class={tier_class(source.tier)}>{tier_glyph(source.tier)}</span>
                  {source.slug} <span id="scope-linked">{number(coverage.linked)}</span>
                </span>
              </div>
            </.async_result>
          </div>
        </div>
      </.section>

      <.container>
        <div class={[
          "grid grid-cols-1 gap-10 pb-16",
          @taxon_root && "lg:grid-cols-[18rem_1fr]"
        ]}>
          <aside :if={@taxon_root} id="scope-tree" class="flex flex-col gap-4">
            <h2 class="font-display text-2xl/8 text-mist-950 dark:text-white">Taxonomy</h2>
            <.async_result :let={tree} assign={@tree}>
              <:loading>
                <.text>Walking the taxonomy…</.text>
              </:loading>
              <:failed :let={_}>
                <.text>The taxonomy did not load.</.text>
              </:failed>

              <nav class="flex flex-wrap items-center gap-1 text-xs/6 text-mist-500">
                <.link patch={~p"/s/#{@scope.slug}?#{drill(@filters, nil)}"} class="hover:underline">
                  all
                </.link>
                <span :for={node <- tree.path} class="flex items-center gap-1">
                  <span aria-hidden="true">›</span>
                  <.link
                    patch={~p"/s/#{@scope.slug}?#{drill(@filters, node.qid)}"}
                    class="hover:underline"
                  >
                    {node.label || node.qid}
                  </.link>
                </span>
              </nav>

              <div :if={tree.here} class="rounded-xl bg-mist-950/2.5 p-4 dark:bg-white/5">
                <div class="text-sm/7 font-medium text-mist-950 dark:text-white">
                  {tree.here.label || tree.here.qid}
                </div>
                <div :if={tree.here.taxon} class="text-xs/6 text-mist-500">
                  {tree.here.taxon["rank"]} · {tree.here.taxon["scientific_name"]}
                </div>
                <.link
                  href={"https://www.wikidata.org/wiki/#{tree.here.qid}"}
                  target="_blank"
                  class="mt-1 inline-block text-xs/6 underline"
                >
                  {tree.here.qid} ↗
                </.link>
              </div>

              <ul role="list" class="flex flex-col gap-1">
                <li :for={child <- tree.children}>
                  <.link
                    patch={~p"/s/#{@scope.slug}?#{drill(@filters, child.qid)}"}
                    id={"tree-#{child.qid}"}
                    class="flex items-baseline justify-between gap-2 rounded-lg px-2 py-1 text-sm/7 hover:bg-mist-950/5 dark:hover:bg-white/10"
                  >
                    <span class="text-mist-950 dark:text-white">
                      {if child.has_children?, do: "▸ ", else: "· "}{child.label || child.qid}
                    </span>
                    <span class="shrink-0 text-xs/6 text-mist-500 tabular-nums">
                      {number(child.scope_lexemes)}
                    </span>
                  </.link>
                </li>
                <li :if={tree.children == []} class="px-2 text-sm/7 text-mist-500">
                  nothing below this
                </li>
              </ul>
            </.async_result>
          </aside>

          <div id="lexeme-list" class="flex flex-col gap-2">
            <div
              :for={row <- @page.rows}
              id={"lexeme-#{row.lexeme_id}"}
              class="flex flex-col gap-2 rounded-xl bg-mist-950/2.5 p-4 sm:flex-row sm:items-start sm:justify-between dark:bg-white/5"
            >
              <div class="flex min-w-0 items-start gap-3">
                <img
                  :if={row.concept && row.concept.image_url}
                  src={row.concept.image_url}
                  alt=""
                  loading="lazy"
                  class="size-12 shrink-0 rounded-lg object-cover"
                />
                <div class="min-w-0">
                  <div class="flex flex-wrap items-baseline gap-2">
                    <span class="text-base/7 font-medium text-mist-950 dark:text-white">
                      {row.lemma}
                    </span>
                    <span class="text-xs/6 text-mist-500">{row.pos}</span>
                    <span
                      :if={is_nil(row.enriched_at)}
                      class="rounded-full bg-mist-950/10 px-2 text-xs/6 text-mist-700 dark:bg-white/10 dark:text-mist-400"
                    >
                      bare
                    </span>
                  </div>
                  <div :if={row.concept} class="truncate text-sm/7 text-mist-700 dark:text-mist-400">
                    {row.concept.label}{taxon_note(row.concept)}
                  </div>
                  <div class="mt-1 text-xs/6 text-mist-500">
                    {Enum.join(row.reasons, " · ")}
                  </div>
                </div>
              </div>

              <div
                id={"badges-#{row.lexeme_id}"}
                class="flex shrink-0 items-center gap-1"
                title="one glyph per source that attests this word"
              >
                <span
                  :for={source <- @sources}
                  id={"badge-#{row.lexeme_id}-#{source.slug}"}
                  class={[
                    "text-sm/7",
                    badge_on?(source, row) && tier_class(source.tier),
                    !badge_on?(source, row) && "opacity-20 grayscale"
                  ]}
                  title={"#{source.slug}: #{badge_title(source, row)}"}
                >
                  {tier_glyph(source.tier)}
                </span>
              </div>
            </div>

            <p :if={@page.rows == []} id="lexeme-list-empty" class="py-16 text-center">
              <.text>Nothing in this scope matches. <em>Clear</em> puts it back.</.text>
            </p>

            <nav :if={@page.pages > 1} class="mt-6 flex items-center justify-between gap-4">
              <.button_link
                :if={@page.page > 1}
                patch={~p"/s/#{@scope.slug}?#{page_params(@filters, @page.page - 1)}"}
                variant="soft"
                id="page-prev"
              >
                ← previous
              </.button_link>
              <span class="text-sm/7 text-mist-500">
                page {@page.page} of {number(@page.pages)}
              </span>
              <.button_link
                :if={@page.page < @page.pages}
                patch={~p"/s/#{@scope.slug}?#{page_params(@filters, @page.page + 1)}"}
                variant="soft"
                id="page-next"
              >
                next →
              </.button_link>
            </nav>
          </div>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :on, :boolean, default: false
  attr :click, :string, required: true
  attr :values, :list, default: []
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@click}
      {Map.new(@values, fn {k, v} -> {"phx-value-#{k}", v} end)}
      aria-pressed={to_string(@on)}
      class={[
        "inline-flex cursor-pointer items-center gap-1 rounded-full px-3 py-1 text-sm/7",
        @on && "bg-mist-950 text-white dark:bg-mist-300 dark:text-mist-950",
        !@on && "bg-mist-950/10 text-mist-950 hover:bg-mist-950/15 dark:bg-white/10 dark:text-white"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp state_filters do
    [{"bare", "bare rows"}, {"enriched", "enriched"}, {"disputed", "disputed"}]
  end

  defp any_filter?(filters) do
    filters[:q] || filters[:has] != [] || filters[:missing] != [] || filters[:state] ||
      filters[:taxon] || filters[:sort] != :lemma
  end

  # Drilling into the tree keeps the filters and resets the page: the words on
  # screen should be the same question asked of a narrower branch.
  defp drill(filters, qid) do
    filters
    |> Keyword.put(:taxon, qid)
    |> Keyword.put(:page, 1)
    |> to_params()
    |> compact()
  end

  defp filter_summary(filters) do
    parts =
      [
        filters[:q] && "matching “#{filters[:q]}”",
        filters[:has] != [] && "with #{Enum.join(filters[:has], " and ")}",
        filters[:missing] != [] && "missing #{Enum.join(filters[:missing], " and ")}",
        filters[:state] && to_string(filters[:state]),
        filters[:taxon] && "under #{filters[:taxon]}"
      ]
      |> Enum.filter(&is_binary/1)

    if parts == [], do: "", else: " " <> Enum.join(parts, ", ")
  end

  defp taxon_note(%{taxon: %{"scientific_name" => name}}) when is_binary(name), do: " · #{name}"
  defp taxon_note(_concept), do: ""
end
