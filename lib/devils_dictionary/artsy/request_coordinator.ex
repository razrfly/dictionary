defmodule DevilsDictionary.Artsy.RequestCoordinator do
  @moduledoc """
  Application-wide pacing and withdrawal generation for Artsy HTTP attempts.

  Every authentication, redirect and retry reserves a slot here before it is
  sent. The returned generation is checked again after the response, so a
  request already on the wire when withdrawal begins cannot publish its body.
  """

  use GenServer

  @default_name __MODULE__

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Reserves one globally paced request attempt."
  def acquire(server \\ @default_name, interval_ms \\ nil, opts \\ []) do
    GenServer.call(
      server,
      {:acquire, interval_ms, opts[:scope], opts[:limit], opts[:window_ms]}
    )
  end

  @doc "Revalidates a queued reservation and reports any provider-wide deferral still remaining."
  def revalidate(generation, server \\ @default_name) do
    GenServer.call(server, {:revalidate, generation})
  end

  @doc "Checks that a request generation is still current after an HTTP response."
  def current?(generation, server \\ @default_name) do
    GenServer.call(server, {:current?, generation})
  end

  @doc "Defers every client until at least the supplied number of milliseconds has elapsed."
  def defer(milliseconds, server \\ @default_name)
      when is_integer(milliseconds) and milliseconds >= 0 do
    GenServer.call(server, {:defer, milliseconds})
  end

  @doc "Atomically disables requests and invalidates responses already in flight."
  def disable(server \\ @default_name), do: GenServer.call(server, :disable)

  @doc "Re-enables requests without resetting request-attempt accounting."
  def enable(server \\ @default_name), do: GenServer.call(server, :enable)

  @doc "Returns whether provider requests are currently enabled."
  def enabled?(server \\ @default_name), do: GenServer.call(server, :enabled?)

  @doc "Returns global attempt, pacing, and scoped-budget counters."
  def stats(server \\ @default_name), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    config = Application.get_env(:devils_dictionary, :artsy, [])
    now_fun = Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end)

    {:ok,
     %{
       enabled: Keyword.get(opts, :enabled, config[:enabled] != false),
       generation: 0,
       next_at: now_fun.(),
       attempts: 0,
       interval_ms: Keyword.get(opts, :interval_ms, config[:rate_limit_ms] || 340),
       scope_attempts: %{},
       scope_started_at: %{},
       deferred_until: now_fun.(),
       now_fun: now_fun
     }}
  end

  @impl true
  def handle_call(
        {:acquire, _interval_ms, _scope, _limit, _window_ms},
        _from,
        %{enabled: false} = state
      ),
      do: {:reply, {:error, :provider_disabled}, state}

  def handle_call({:acquire, interval_ms, scope, limit, window_ms}, _from, state) do
    now = state.now_fun.()
    {used, started_at} = scope_usage(state, scope, window_ms, now)

    if is_integer(limit) and used >= limit do
      {:reply, {:error, :shared_request_limit}, state}
    else
      slot_at = max(max(state.next_at, state.deferred_until), now)
      wait_ms = slot_at - now
      interval_ms = if is_integer(interval_ms), do: max(interval_ms, 0), else: state.interval_ms

      scope_attempts =
        if is_nil(scope),
          do: state.scope_attempts,
          else: Map.put(state.scope_attempts, scope, used + 1)

      scope_started_at =
        if is_nil(scope),
          do: state.scope_started_at,
          else: Map.put(state.scope_started_at, scope, started_at)

      state = %{
        state
        | next_at: slot_at + interval_ms,
          attempts: state.attempts + 1,
          scope_attempts: scope_attempts,
          scope_started_at: scope_started_at
      }

      {:reply, {:ok, state.generation, wait_ms}, state}
    end
  end

  def handle_call({:current?, generation}, _from, state),
    do: {:reply, state.enabled and state.generation == generation, state}

  def handle_call({:revalidate, generation}, _from, state) do
    if state.enabled and state.generation == generation do
      {:reply, {:ok, max(state.deferred_until - state.now_fun.(), 0)}, state}
    else
      {:reply, {:error, :provider_disabled}, state}
    end
  end

  def handle_call({:defer, milliseconds}, _from, state) do
    not_before = state.now_fun.() + milliseconds

    {:reply, :ok,
     %{
       state
       | next_at: max(state.next_at, not_before),
         deferred_until: max(state.deferred_until, not_before)
     }}
  end

  def handle_call(:disable, _from, state) do
    state = %{state | enabled: false, generation: state.generation + 1}
    {:reply, {:ok, state.generation}, state}
  end

  def handle_call(:enable, _from, state),
    do:
      {:reply, :ok,
       %{
         state
         | enabled: true,
           next_at: state.now_fun.(),
           deferred_until: state.now_fun.()
       }}

  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  def handle_call(:stats, _from, state),
    do:
      {:reply,
       Map.take(state, [
         :enabled,
         :generation,
         :attempts,
         :next_at,
         :deferred_until,
         :scope_attempts,
         :scope_started_at
       ]), state}

  defp scope_usage(_state, nil, _window_ms, now), do: {0, now}

  defp scope_usage(state, scope, window_ms, now) do
    used = Map.get(state.scope_attempts, scope, 0)
    started_at = Map.get(state.scope_started_at, scope, now)

    if is_integer(window_ms) and window_ms > 0 and now - started_at >= window_ms,
      do: {0, now},
      else: {used, started_at}
  end
end
