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

  import DevilsDictionaryWeb.Ops

  alias DevilsDictionary.{Health, Lexicon}
  alias DevilsDictionary.Workers.AbsorbWorker

  # `:unset` distinguishes "mount has not seen params yet" from `nil`, which now
  # means "no population selected" and is a state the page renders rather than a
  # value it replaces (#77 §2).
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Imports", scope_slug: nil, scopes: Lexicon.list_scopes())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = params["scope"]

    if scope == socket.assigns.scope_slug do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(scope_slug: scope) |> load()}
    end
  end

  defp chooser_path(slug), do: ~p"/ops/imports?scope=#{slug}"

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  # An API source with no scope is the unbounded network import #77 §2 says a
  # missing selection must never start. The button is disabled for it; this is
  # the check that holds when the event arrives anyway.
  @impl true
  def handle_event("absorb", %{"source" => slug} = params, socket) do
    if api_source?(socket, slug) and params["scope"] in [nil, ""] do
      {:noreply,
       put_flash(
         socket,
         :error,
         "#{slug} is fetched over a population. Choose one before absorbing it."
       )}
    else
      queue_absorb(socket, slug, params)
    end
  end

  defp api_source?(socket, slug) do
    Enum.any?(socket.assigns.records, &(&1.slug == slug and &1.access == :api))
  end

  defp queue_absorb(socket, slug, params) do
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

  # The ledger and the runs are whole-corpus and always load. The link rate, the
  # conflicts and the disambiguation probes are per-population, and without one
  # they are not computed at all — this used to be the second `|| "animals"` in
  # this file, the one `mount/3` needed because it calls `load/1` before any
  # params exist.
  defp load(socket) do
    scope_slug = socket.assigns.scope_slug

    socket
    |> assign(
      records: Health.records(scope_slug),
      runs: Health.source_runs(),
      resolution: Health.resolution("wiktionary"),
      loaded_at: DateTime.utc_now()
    )
    |> assign(population_stats(scope_slug))
  end

  defp population_stats(nil), do: %{links: nil, disambiguation: nil, conflicts: nil}

  defp population_stats(scope_slug) do
    %{
      links: Health.links(scope_slug),
      disambiguation: Health.disambiguation(scope_slug),
      conflicts: Health.conflicts(scope_slug)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section
        id="imports"
        eyebrow="Developer surface"
        headline="Imports"
        subheadline="Every figure here is Health.records/1 and Health.source_runs/0 — the same call mix dd.health prints. The ledger is whole-corpus; the columns and sections that are not say so."
      >
        <:cta>
          <div class="flex flex-col gap-3">
            <.population_chooser scopes={@scopes} selected={@scope_slug} path={&chooser_path/1} />
            <div class="flex items-center gap-3">
              <.button phx-click="refresh" variant="soft">Refresh</.button>
              <span class="text-sm/7 text-mist-500">
                read at {Calendar.strftime(@loaded_at, "%H:%M:%S")}
              </span>
            </div>
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
            <span
              :if={is_nil(r.needs_fetch)}
              class="text-mist-400"
              title={
                if(r.needs_fetch_of,
                  do: "no population selected",
                  else: "a dump is the answer"
                )
              }
            >
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
              disabled={r.access == :api and is_nil(@scope_slug)}
              data-confirm={"Queue an absorb of #{r.slug}?"}
            >
              absorb
            </.button>
            <%!-- An API absorb with no scope is an unbounded network import, and
            #77 §2 is explicit that a missing selection must never start one. The
            handler below refuses it too; this only stops the click. --%>
          </:col>
        </.table>

        <p class="mt-2 text-sm/7 text-mist-500">
          needs fetch counts {Enum.map_join(populations(@records), ", ", & &1)}.
          <span :if={is_nil(@scope_slug)}>
            Wikipedia's is over a population's lemmas, so it needs one chosen.
          </span>
        </p>
      </.section>

      <.section id="health-summary" eyebrow="Health" headline="Where the graph stands">
        <.text :if={is_nil(@scope_slug)} id="no-population" class="mb-6 max-w-2xl text-pretty">
          The link rate, the conflicts and the disambiguation probes are measured
          over one population and none is selected. There is deliberately no
          default: these used to answer for Animals whatever the page was asked
          about. Unresolved Wiktionary targets are whole-corpus and stand alone.
        </.text>

        <div :if={is_nil(@scope_slug)} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <.stat value={number(@resolution.total - @resolution.resolved)}>
            unresolved Wiktionary relation targets, of {number(@resolution.total)}
          </.stat>
        </div>

        <div :if={@scope_slug} class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
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
              navigate={~p"/ops/scopes/#{@scope_slug}?state=disputed"}
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
            navigate={~p"/ops/health"}
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
        <.text :if={is_nil(@scope_slug)} id="no-population-commands" class="max-w-2xl text-pretty">
          Every command below takes <code>--scope</code>, and every one of them now
          refuses without it. Choose a population above and they appear ready to copy.
        </.text>
        <div :if={@scope_slug} class="flex flex-col gap-2">
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
