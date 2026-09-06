defmodule DevilsDictionaryWeb.HealthLive do
  @moduledoc """
  The scorecard and the numbers under it — row **O4**, and `mix dd.score` and
  `mix dd.health` rendered rather than printed. `Health.Score.rows/1` and
  `Health.Score.summary/1` are the same calls the task makes, so the table here
  and the table in a terminal are the same table.

  Parity (M1) is the one figure not loaded on mount. It re-runs `materialize/1`
  over every stored record of a source — right, but minutes on a full database,
  which is why `mix dd.health` gates it behind `--parity` and `mix dd.score`
  offers `--skip-parity`. Here it is a button per source and a `start_async`,
  so the rest of the page is readable while it runs.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.{Health, Sources}
  alias DevilsDictionary.Health.Score

  @impl true
  def mount(_params, _session, socket) do
    scope = "animals"
    rows = Score.rows(scope: scope, skip_parity: true)

    {:ok,
     socket
     |> assign(
       page_title: "Health",
       scope_slug: scope,
       rows: rows,
       summary: Score.summary(rows),
       parity: %{},
       sources: Sources.list_sources()
     )
     |> assign_async(:detail, fn -> {:ok, %{detail: detail(scope)}} end)}
  end

  @impl true
  def handle_event("parity", %{"source" => slug}, socket) do
    {:noreply,
     socket
     |> put_parity(slug, :running)
     |> start_async({:parity, slug}, fn -> Health.parity(slug) end)}
  end

  @impl true
  def handle_async({:parity, slug}, {:ok, result}, socket) do
    {:noreply, put_parity(socket, slug, result)}
  end

  @impl true
  def handle_async({:parity, slug}, {:exit, reason}, socket) do
    {:noreply, put_parity(socket, slug, {:error, reason})}
  end

  defp put_parity(socket, slug, value) do
    assign(socket, parity: Map.put(socket.assigns.parity, slug, value))
  end

  # Everything mix dd.health prints under the scorecard. Async because the link
  # histogram and the conflict list are a second or two together, and the
  # scorecard above them is the reason to open the page.
  defp detail(scope) do
    %{
      coverage: for(slug <- source_slugs(), do: {slug, Health.coverage(scope, slug)}),
      resolution: for(slug <- ~w(wordnet wiktionary bierce), do: {slug, Health.resolution(slug)}),
      links: Health.links(scope),
      conflicts: Health.conflicts(scope),
      taxonomy: Health.taxonomy(scope),
      disambiguation: Health.disambiguation(scope),
      images: Health.images(scope),
      links_back: Health.links_back(),
      bierce: Health.bierce(scope),
      variants: Health.variants()
    }
  end

  defp source_slugs, do: ~w(wordnet wiktionary wikidata wikipedia bierce)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section
        id="scorecard"
        eyebrow="Scorecard"
        headline={"#{@summary.passed} / #{@summary.graded} graded rows pass"}
        subheadline={"#{@summary.reported} reported, #{@summary.pending} pending. This is Health.Score.rows/1 — the same call mix dd.score prints, on scope #{@scope_slug}."}
      >
        <div>
          <.table id="scorecard-rows" rows={@rows}>
            <:col :let={row} label="">
              <span id={"score-row-#{row.id}"} class={status_class(row.status)}>
                {status_glyph(row.status)}
              </span>
            </:col>
            <:col :let={row} label="id">
              <span class="font-mono text-xs/6 font-semibold">{row.id}</span>
            </:col>
            <:col :let={row} label="check">
              <span class="text-mist-950 dark:text-white">{row.check}</span>
            </:col>
            <:col :let={row} label="actual">{row.actual}</:col>
            <:col :let={row} label="wants">{row.wants}</:col>
            <:col :let={row} label="">
              <span :if={row.session} class="font-mono text-xs/6 text-mist-400">{row.session}</span>
              <span :if={row.detail} class="text-xs/6 text-mist-500">{row.detail}</span>
            </:col>
          </.table>
        </div>
      </.section>

      <.section
        id="health-parity"
        eyebrow="M1"
        headline="Parity: does raw still agree with derived?"
        subheadline="Not loaded on arrival. It re-runs materialize/1 over every stored record — the same reason mix dd.health keeps it behind --parity."
      >
        <div class="flex flex-col gap-3">
          <div
            :for={source <- @sources}
            class="flex flex-col gap-2 rounded-xl bg-mist-950/2.5 p-4 sm:flex-row sm:items-center sm:justify-between dark:bg-white/5"
          >
            <div class="flex items-center gap-3">
              <span class={tier_class(source.tier)}>{tier_glyph(source.tier)}</span>
              <span class="text-sm/7 font-medium text-mist-950 dark:text-white">{source.slug}</span>
            </div>
            <div class="flex items-center gap-4">
              <span id={"parity-#{source.slug}"} class="text-sm/7">
                {parity_line(@parity[source.slug])}
              </span>
              <.button
                phx-click="parity"
                phx-value-source={source.slug}
                variant="soft"
                disabled={@parity[source.slug] == :running}
              >
                {if @parity[source.slug] == :running, do: "checking…", else: "check"}
              </.button>
            </div>
          </div>
        </div>
      </.section>

      <.async_result :let={detail} assign={@detail}>
        <:loading>
          <.section id="health-loading" eyebrow="Detail" headline="Reading the graph…">
            <.text>Coverage, resolution, links and taxonomy are a second or two behind.</.text>
          </.section>
        </:loading>
        <:failed :let={_reason}>
          <.section id="health-failed" eyebrow="Detail" headline="Could not read the graph">
            <.text>Reload the page; the scorecard above is unaffected.</.text>
          </.section>
        </:failed>

        <.section
          id="health-coverage"
          eyebrow="A5 · A6"
          headline="Coverage of the scope, per source"
          subheadline="A badge on the browse page counts the same way: lexemes.source_ids, the array the materializer maintains."
        >
          <.table id="health-coverage-rows" rows={detail.coverage}>
            <:col :let={{slug, _}} label="source">
              <.link navigate={~p"/sources/#{slug}"} class="font-medium hover:underline">
                {slug}
              </.link>
            </:col>
            <:col :let={{_, c}} label="attests">{number(c.covered)}</:col>
            <:col :let={{_, c}} label="of">{number(c.total)}</:col>
            <:col :let={{_, c}} label="%">{c.pct}%</:col>
            <:col :let={{_, c}} label="misses by kind">
              {c.missing_by_kind
              |> Enum.sort()
              |> Enum.map_join(" · ", fn {k, n} -> "#{k} #{number(n)}" end)}
            </:col>
            <:col :let={{slug, _}} label="">
              <.link navigate={~p"/s/#{@scope_slug}?missing=#{slug}"} class="underline">
                browse the gaps
              </.link>
            </:col>
          </.table>
        </.section>

        <.section
          id="health-resolution"
          eyebrow="R1 · R2"
          headline="Relation targets resolved"
          subheadline="A relation keeps its to_lemma forever; dd.resolve fills to_lexeme_id when the word turns up."
        >
          <.table id="health-resolution-rows" rows={detail.resolution}>
            <:col :let={{slug, _}} label="source">{slug}</:col>
            <:col :let={{_, r}} label="resolved">{number(r.resolved)}</:col>
            <:col :let={{_, r}} label="of">{number(r.total)}</:col>
            <:col :let={{_, r}} label="%">{r.pct}%</:col>
            <:col :let={{_, r}} label="by type">
              {r.by_type
              |> Enum.sort()
              |> Enum.map_join(" · ", fn {t, %{total: t2, resolved: rr}} -> "#{t} #{rr}/#{t2}" end)}
            </:col>
          </.table>
        </.section>

        <.section
          id="health-links"
          eyebrow="L1 – L4"
          headline="The word ↔ thing bridge"
          subheadline="Every link records how we know and how sure we are. Conflicts are surfaced, never resolved silently."
        >
          <div class="flex flex-col gap-10">
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
              <.stat value={"#{detail.links.reachable_pct}%"}>
                of the {number(detail.links.reachable)} scope words that have an English article
                (L1)
              </.stat>
              <.stat value={"#{detail.links.pct}%"}>
                of all {number(detail.links.scope_total)} scope words, at ≥ {detail.links.threshold}
              </.stat>
              <.stat value={"#{detail.links.strict_pct}%"}>
                by the strict ladder alone, before corroboration
              </.stat>
              <.stat value={"#{detail.taxonomy.pct}%"}>
                of linked concepts reach Animalia by parent_taxon (L3)
              </.stat>
            </div>

            <div>
              <h3 class="mb-2 text-base/8 font-medium text-mist-950 dark:text-white">
                Links by rung and confidence
              </h3>
              <.table id="health-histogram" rows={Enum.sort(detail.links.histogram)}>
                <:col :let={{method, _, _}} label="rung">{method}</:col>
                <:col :let={{_, confidence, _}} label="confidence">{confidence}</:col>
                <:col :let={{_, _, n}} label="links">{number(n)}</:col>
              </.table>
            </div>

            <div>
              <h3 class="mb-2 text-base/8 font-medium text-mist-950 dark:text-white">
                {number(detail.conflicts.count)} words with two concepts ≥ 0.7 (L2)
              </h3>
              <.table id="health-conflicts" rows={detail.conflicts.sample}>
                <:col :let={c} label="word">{c.lemma}</:col>
                <:col :let={c} label="pos">{c.pos}</:col>
                <:col :let={c} label="concepts">{c.concepts}</:col>
              </.table>
              <p class="mt-3 text-sm/7">
                <.link navigate={~p"/s/#{@scope_slug}?state=disputed"} class="underline">
                  Browse every disputed word →
                </.link>
              </p>
            </div>

            <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
              <.stat value={number(detail.disambiguation.candidates)}>
                candidate links from {number(detail.disambiguation.hits)} ambiguous lemmas (L4)
              </.stat>
              <.stat value={"#{detail.images.pct}%"}>
                of asserted concepts carry an image (A10)
              </.stat>
              <.stat value={"#{detail.links_back.pct}%"}>
                of senses and entries can link back to their source (A9)
              </.stat>
            </div>
          </div>
        </.section>

        <.section id="health-dead" eyebrow="A8 · X3" headline="The dead, and the forms">
          <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
            <.stat value={number(detail.bierce.entries)}>Bierce entries</.stat>
            <.stat value={"#{detail.bierce.index_hit_pct}%"}>
              of his headwords another source already attested
            </.stat>
            <.stat value={number(detail.bierce.introduced_by_bierce)}>
              words he alone brought to the index
            </.stat>
            <.stat value={"#{detail.variants.passed} / #{detail.variants.total}"}>
              form and variant probes land on the right word (X3)
            </.stat>
          </div>

          <div class="mt-6">
            <.table id="health-probes" rows={detail.variants.probes}>
              <:col :let={p} label="typed">{p.input}</:col>
              <:col :let={p} label="landed on">{p.landed}</:col>
              <:col :let={p} label="">{if p.ok, do: "✓", else: "✗"}</:col>
            </.table>
          </div>
        </.section>
      </.async_result>
    </Layouts.app>
    """
  end

  defp status_glyph(:pass), do: "PASS"
  defp status_glyph(:fail), do: "FAIL"
  defp status_glyph(:report), do: "·"
  defp status_glyph(:pending), do: "⬜"

  defp status_class(:pass),
    do: "font-mono text-xs/6 font-semibold text-green-700 dark:text-green-400"

  defp status_class(:fail), do: "font-mono text-xs/6 font-semibold text-red-700 dark:text-red-400"
  defp status_class(_), do: "font-mono text-xs/6 text-mist-400"

  defp parity_line(nil), do: "not checked"
  defp parity_line(:running), do: "running…"
  defp parity_line({:error, _reason}), do: "failed"

  defp parity_line(%{gaps: 0, records: records}),
    do: "0 gaps over #{number(records)} records"

  defp parity_line(%{gaps: gaps, records: records}),
    do: "#{number(gaps)} gaps over #{number(records)} records"
end
