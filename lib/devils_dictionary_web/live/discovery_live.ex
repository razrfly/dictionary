defmodule DevilsDictionaryWeb.DiscoveryLive do
  @moduledoc """
  The operator's view of discovery (#144 Phase 4): what each provider has
  spent, what it holds, and what it is waiting for.

  A sibling of `/ops/imports` rather than a section of it. That page is the
  **corpus**: what each dictionary source has absorbed, what is unresolved,
  what needs materializing. This one is the **culture shelves**: twelve
  providers whose results are a disposable cache with a refresh clock and a
  retention deadline, and none of whose numbers are in `import_runs`. They
  share an eyebrow and nothing else.

  Every figure comes from `DevilsDictionary.Discovery.Status.rows/0` and
  `preflight/0`, which is exactly what `mix dd.discovery.status` and
  `mix dd.discovery.check` print — one implementation, so the page and the
  tasks cannot drift, the arrangement `Health.records/1` has had with
  `mix dd.health` since #69 §6.

  Nothing here names a provider. The rows are `Providers.all()` in registry
  order, so the thirteenth appears the day it is registered.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Discovery.Status

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Discovery") |> load()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    now = DateTime.utc_now()

    assign(socket,
      rows: Status.rows(now: now),
      preflight: Status.preflight(),
      unclaimed: Status.unclaimed_credentials(),
      loaded_at: now
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section
        id="discovery"
        eyebrow="Developer surface"
        headline="Discovery"
        subheadline="Every figure here is Discovery.Status.rows/0 and preflight/0 — the same two calls mix dd.discovery.status and mix dd.discovery.check print. The rows are the provider registry, in its order."
      >
        <:cta>
          <div class="flex items-center gap-3">
            <.button phx-click="refresh" variant="soft">Refresh</.button>
            <span class="text-sm/7 text-mist-500">
              read at {Calendar.strftime(@loaded_at, "%H:%M:%S")} UTC
            </span>
          </div>
        </:cta>

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <.stat value={"#{Enum.count(@rows, & &1.enabled)}/#{length(@rows)}"}>
            providers ready — the rest are switched off or waiting for a credential
          </.stat>
          <.stat value={number(sum(@rows, :results))}>
            results held now, from {number(sum(@rows, :runs))} runs ever given
          </.stat>
          <.stat value={"#{number(sum(@rows, :stale))} of #{number(sum(@rows, :roots))}"}>
            display roots past their refresh clock, each re-queued by the next visit
          </.stat>
          <.stat value={number(sum(@rows, :retention_due))}>
            runs past retention, withdrawn and purged on the next cleanup tick
          </.stat>
        </div>

        <.table id="discovery-ledger" rows={@rows} row_id={&"ledger-#{&1.slug}"}>
          <:col :let={r} label="provider">
            <.link
              :if={r.active != nil}
              navigate={~p"/sources/#{r.slug}"}
              class="font-medium hover:underline"
            >
              {r.slug}
            </.link>
            <span :if={r.active == nil} class="font-medium">{r.slug}</span>
          </:col>
          <:col :let={r} label="state"><.state row={r} /></:col>
          <:col :let={r} label="runs">{number(r.runs)}</:col>
          <:col :let={r} label="failed">
            <span class={r.failed > 0 && "text-red-700 dark:text-red-400"}>{number(r.failed)}</span>
          </:col>
          <:col :let={r} label="last success">{last_success(r.last_success, @loaded_at)}</:col>
          <:col :let={r} label="held">{number(r.results)}</:col>
          <:col :let={r} label="roots">{number(r.roots)}</:col>
          <:col :let={r} label="stale">
            <span title="past refresh_after; re-queued on the next visit to that page">
              {number(r.stale)}
            </span>
          </:col>
          <:col :let={r} label="due">
            <span title={"held no longer than #{duration(r.budget.retention_seconds)}"}>
              {number(r.retention_due)}
            </span>
          </:col>
          <:col :let={r} label="budget">
            <span title={"per #{duration(r.budget.window_seconds)}"}>
              {r.budget.used}/{r.budget.limit || "?"}
            </span>
          </:col>
          <:col :let={r} label="backoff"><.backoff backoff={r.backoff} /></:col>
        </.table>

        <p class="mt-4 max-w-2xl text-sm/7 text-pretty text-mist-700 dark:text-mist-400">
          Nothing refreshes a page nobody visits, so a stale root is not a backlog —
          it is a page that has not been opened since it went stale. A provider with
          runs and nothing held is one whose retention has already run; a browser
          provider stores nothing here by design.
        </p>
      </.section>

      <.section
        id="discovery-configuration"
        eyebrow="Preflight"
        headline="What each provider is waiting for"
        subheadline="A credential is reported as present or missing and never read to say so: the presence map is built in config/runtime.exs and only the boolean leaves it."
      >
        <.table id="discovery-preflight" rows={@preflight} row_id={&"preflight-#{&1.slug}"}>
          <:col :let={p} label="provider"><span class="font-medium">{p.slug}</span></:col>
          <:col :let={p} label="driven by">{p.kind}</:col>
          <:col :let={p} label="enabled?">
            <.badge tone={if(p.enabled, do: :ready, else: :quiet)}>
              {if p.enabled, do: "yes", else: "no"}
            </.badge>
          </:col>
          <:col :let={p} label="switch">{p.switch}</:col>
          <:col :let={p} label="endpoints">
            <span :if={p.endpoints == []} class="text-mist-400">—</span>
            <div :for={{key, url, state} <- p.endpoints} class="font-mono text-sm/7">
              <span :if={state == :ok}>{url}</span>
              <span :if={state == :invalid} class="text-red-700 dark:text-red-400">
                {key} is not an http(s) endpoint
              </span>
            </div>
          </:col>
          <:col :let={p} label="policy">
            <span :if={match?({:ok, _}, p.policy)}>
              {duration(refresh(p.policy))} · holds {duration(retention(p.policy))}
            </span>
            <span :if={match?({:error, _}, p.policy)} class="text-red-700 dark:text-red-400">
              {elem(p.policy, 1)}
            </span>
          </:col>
          <:col :let={p} label="credentials">
            <span :if={p.credentials == []} class="text-mist-400">none needed</span>
            <span :for={{name, status} <- p.credentials} class="mr-2 inline-flex">
              <.badge tone={if(status == :present, do: :ready, else: :quiet)}>
                {name} {status}
              </.badge>
            </span>
          </:col>
        </.table>

        <p :if={@unclaimed != []} class="mt-4 max-w-2xl text-sm/7 text-pretty text-mist-500">
          Admitted by <code>allowed_provider_env</code>
          and read by no registered provider: {Enum.map_join(@unclaimed, ", ", fn {name, status} ->
            "#{name} #{status}"
          end)}. Not a
          fault — a credential nothing currently asks for.
        </p>
      </.section>

      <.section id="discovery-commands" eyebrow="Tasks" headline="The same two calls in a terminal">
        <div class="flex flex-col gap-2">
          <div
            :for={{command, what} <- commands()}
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

  # Four reasons a shelf is not there, told apart — a missing key, an owner's
  # switch, a withdrawn source row and a provider the reader's browser drives
  # are four different mornings, and "not enabled" is the one an operator can
  # do nothing with.
  attr :row, :map, required: true

  defp state(assigns) do
    ~H"""
    <.badge tone={tone(@row)}>{label(@row)}</.badge>
    """
  end

  defp label(%{kind: :browser}), do: "browser"
  defp label(%{active: false}), do: "inactive"
  defp label(%{enabled: true}), do: "ready"
  defp label(%{switch: :off}), do: "off"
  defp label(_row), do: "no key"

  defp tone(%{kind: :browser}), do: :quiet
  defp tone(%{enabled: true, active: active}) when active != false, do: :ready
  defp tone(_row), do: :quiet

  attr :tone, :atom, required: true
  slot :inner_block, required: true

  defp badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded-full px-2 py-0.5 text-sm/6 whitespace-nowrap",
      @tone == :ready && "bg-mist-950/5 text-mist-950 dark:bg-white/10 dark:text-white",
      @tone == :quiet && "bg-mist-950/2.5 text-mist-500 dark:bg-white/5 dark:text-mist-400"
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp commands do
    [
      {"mix dd.discovery.check", "the preflight table, before a deploy"},
      {"mix dd.discovery.status", "the ledger table, in any environment"},
      {"mix dd.discovery --definition-source bierce --providers all --limit 20 --dry-run",
       "exercise the pipeline on a bounded sample"}
    ]
  end

  defp sum(rows, key), do: Enum.sum(Enum.map(rows, &Map.fetch!(&1, key)))

  defp refresh({:ok, policy}), do: policy.positive_refresh_seconds
  defp retention({:ok, policy}), do: policy.retention_seconds

  defp last_success(nil, _now), do: "never"

  defp last_success(at, now) do
    "#{duration(DateTime.diff(now, at))} ago"
  end

  attr :backoff, :any, required: true

  defp backoff(%{backoff: nil} = assigns) do
    ~H"""
    <span class="text-mist-400">—</span>
    """
  end

  defp backoff(assigns) do
    ~H"""
    <span class="text-red-700 dark:text-red-400" title={@backoff.reason}>
      {duration(@backoff.seconds)} left
    </span>
    """
  end

  # Whole units, largest that fits: an operator reading a retention window
  # wants "24 h", and one reading a last success wants "22 h ago".
  defp duration(nil), do: "—"
  defp duration(seconds) when seconds < 90, do: "#{seconds} s"
  defp duration(seconds) when seconds < 5_400, do: "#{div(seconds, 60)} min"
  defp duration(seconds) when seconds < 172_800, do: "#{div(seconds, 3_600)} h"
  defp duration(seconds), do: "#{div(seconds, 86_400)} d"
end
