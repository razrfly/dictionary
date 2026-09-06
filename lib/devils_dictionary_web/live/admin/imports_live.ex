defmodule DevilsDictionaryWeb.Admin.ImportsLive do
  @moduledoc """
  The import dashboard (#69 §6 W5): per source, what we hold, what is absent,
  what still needs fetching or materializing, and what ran last.

  Every number comes from `Health.records/1` and `Health.source_runs/0`, which is
  what `mix dd.health` prints — one implementation, so the page and the task
  cannot disagree.

  On the buttons: only one action here has an execution path from a web request.
  `AbsorbWorker` exists (its moduledoc says so) precisely so an absorb can be
  started from this page. `resolve`, `link`, `materialize` and `score` are mix
  tasks and nothing more; wrapping them in workers is a decision for whoever
  needs it, not something to invent while building a dashboard. So they are
  shown as the exact command to run, and the `import_runs` row each one writes
  shows up in the table either way, which is the actual feedback loop.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Health
  alias DevilsDictionary.Workers.AbsorbWorker

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Imports") |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = params["scope"] || "animals"

    if scope == socket.assigns.scope_slug do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(scope_slug: scope) |> load()}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("absorb", %{"source" => slug} = params, socket) do
    args =
      %{"source" => slug}
      |> then(
        &if(params["scope"] in [nil, ""], do: &1, else: Map.put(&1, "scope", params["scope"]))
      )

    case Oban.insert(AbsorbWorker.new(args)) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued absorb of #{slug} as job ##{job.id}.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not queue: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    scope_slug = socket.assigns[:scope_slug] || "animals"

    assign(socket,
      scope_slug: scope_slug,
      records: Health.records(scope_slug),
      runs: Health.source_runs(),
      links: Health.links(scope_slug),
      resolution: Health.resolution("wiktionary"),
      disambiguation: Health.disambiguation(scope_slug),
      conflicts: Health.conflicts(scope_slug),
      loaded_at: DateTime.utc_now()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section
        id="imports"
        eyebrow="Developer surface"
        headline="Imports"
        subheadline={"Every figure here is Health.records/1 and Health.source_runs/0 — the same call mix dd.health prints. Scope: #{@scope_slug}."}
      >
        <:cta>
          <div class="flex items-center gap-3">
            <.button phx-click="refresh" variant="soft">Refresh</.button>
            <span class="text-sm/7 text-mist-500">
              read at {Calendar.strftime(@loaded_at, "%H:%M:%S")}
            </span>
          </div>
        </:cta>

        <.table id="imports-rows" rows={@records}>
          <:col :let={r} label="source">
            <.link navigate={~p"/sources/#{r.slug}"} class="font-medium hover:underline">
              <span class={tier_class(r.tier)}>{tier_glyph(r.tier)}</span>
              {r.slug}
            </.link>
          </:col>
          <:col :let={r} label="access">{r.access}</:col>
          <:col :let={r} label="records">{number(r.records)}</:col>
          <:col :let={r} label="absent">{number(r.absent)}</:col>
          <:col :let={r} label="needs fetch">
            <span :if={r.needs_fetch} title={"of #{r.needs_fetch_of}"}>
              {number(r.needs_fetch)}
            </span>
            <span :if={is_nil(r.needs_fetch)} class="text-mist-400" title="a dump is the answer">
              —
            </span>
          </:col>
          <:col :let={r} label="needs mat.">
            <span class={r.needs_materialization > 0 && "font-semibold text-red-700"}>
              {number(r.needs_materialization)}
            </span>
          </:col>
          <:col :let={r} label="changed">{number(r.changed)}</:col>
          <:col :let={r} label="last run">{last_run(r.last_run)}</:col>
          <:col :let={r} label="runs">{done_runs(@runs, r.slug)}</:col>
          <:col :let={r} label="pin">{pin(@runs, r.slug)}</:col>
          <%!-- A `<:col>`, not the generator's `<:action>`: that slot's cell is
          `w-0`, and a button overflowing a zero-width cell escapes the table's
          scroll box and drags the whole page sideways at 375 px. --%>
          <:col :let={r} label="">
            <.button
              phx-click="absorb"
              phx-value-source={r.slug}
              phx-value-scope={if(r.access == :api, do: @scope_slug, else: "")}
              variant="soft"
              data-confirm={"Queue an absorb of #{r.slug}?"}
            >
              absorb
            </.button>
          </:col>
        </.table>

        <p class="mt-2 text-sm/7 text-mist-500">
          needs fetch counts {Enum.map_join(populations(@records), ", ", & &1)}.
        </p>
      </.section>

      <.section id="health-summary" eyebrow="Health" headline="Where the graph stands">
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <.stat value={"#{@links.pct}%"}>
            of {number(@links.scope_total)} scope words linked at ≥ {@links.threshold} ({@links.reachable_pct}% of the {number(
              @links.reachable
            )} with an article)
          </.stat>
          <.stat value={number(@resolution.total - @resolution.resolved)}>
            unresolved Wiktionary relation targets, of {number(@resolution.total)}
          </.stat>
          <.stat value={number(@conflicts.count)}>
            words with two concepts ≥ 0.7 —
            <.link
              navigate={~p"/s/#{@scope_slug}?state=disputed"}
              class="underline"
            >listed</.link>
          </.stat>
          <.stat value={number(@disambiguation.candidates)}>
            disambiguation candidates, from {number(@disambiguation.hits)} ambiguous lemmas
          </.stat>
        </div>

        <p class="mt-6 text-sm/7 text-mist-700 dark:text-mist-400">
          Parity (M1) is not on this page: it re-runs <code>materialize/1</code>
          over every stored
          record, which is right but minutes long. It lives on <.link
            navigate={~p"/health"}
            class="underline"
          >the health page</.link>, behind a button,
          exactly as <code>mix dd.health</code>
          keeps it behind <code>--parity</code>.
        </p>
      </.section>

      <.section id="imports-commands" eyebrow="Tasks" headline="The rest is a command">
        <.text class="mb-6">
          Only <code>absorb</code> has a worker, so only <code>absorb</code> has a button. These
          write the same <code>import_runs</code> rows the table above reads.
        </.text>
        <div class="flex flex-col gap-2">
          <div
            :for={{command, what} <- commands(@scope_slug)}
            class="flex flex-col gap-1 rounded-xl bg-mist-950/2.5 p-4 sm:flex-row sm:items-center sm:justify-between dark:bg-white/5"
          >
            <code class="font-mono text-sm/7 text-mist-950 dark:text-white">{command}</code>
            <span class="text-sm/7 text-mist-700 dark:text-mist-400">{what}</span>
          </div>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  defp commands(scope) do
    [
      {"mix dd.resolve", "fill to_lexeme_id and canonical variants (R2)"},
      {"mix dd.link --scope #{scope}", "run the ladder, print the histogram (L1–L4)"},
      {"mix dd.materialize --source <slug> --dry-run", "raw vs derived parity (M1)"},
      {"mix dd.materialize --source <slug> --all", "rebuild every derived row, offline (M2)"},
      {"mix dd.scope.build #{scope}", "rebuild scope membership and its reasons (A4)"},
      {"mix dd.health --scope #{scope} --parity", "this page, plus parity, in a terminal"},
      {"mix dd.score --scope #{scope}", "the scorecard as PASS/FAIL (O1)"}
    ]
  end

  defp populations(records) do
    records
    |> Enum.reject(&is_nil(&1.needs_fetch_of))
    |> Enum.map(&"#{&1.slug}: #{&1.needs_fetch_of}")
  end

  defp done_runs(runs, slug) do
    case Enum.find(runs.sources, &(&1.slug == slug)) do
      %{runs: n} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp pin(runs, slug) do
    case Enum.find(runs.sources, &(&1.slug == slug)) do
      %{snapshot: pin} when is_binary(pin) -> pin
      _ -> "—"
    end
  end

  defp last_run(nil), do: "never"

  defp last_run(%{task: task, status: status, at: at}) do
    "#{task} · #{status} · #{Calendar.strftime(at, "%b %d %H:%M")}"
  end
end
