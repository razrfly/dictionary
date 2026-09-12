defmodule DevilsDictionary.Artsy.RequestCoordinator do
  @moduledoc """
  Application-wide pacing and withdrawal generation for Artsy HTTP attempts.

  Every authentication, redirect and retry reserves a slot here before it is
  sent. The returned generation is checked again after the response, so a
  request already on the wire when withdrawal begins cannot publish its body.
  """

  use GenServer

  @default_name __MODULE__

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  def acquire(server \\ @default_name, interval_ms \\ nil) do
    GenServer.call(server, {:acquire, interval_ms})
  end

  def current?(generation, server \\ @default_name) do
    GenServer.call(server, {:current?, generation})
  end

  def defer(milliseconds, server \\ @default_name)
      when is_integer(milliseconds) and milliseconds >= 0 do
    GenServer.call(server, {:defer, milliseconds})
  end

  def disable(server \\ @default_name), do: GenServer.call(server, :disable)
  def enable(server \\ @default_name), do: GenServer.call(server, :enable)
  def enabled?(server \\ @default_name), do: GenServer.call(server, :enabled?)
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
       now_fun: now_fun
     }}
  end

  @impl true
  def handle_call({:acquire, _interval_ms}, _from, %{enabled: false} = state),
    do: {:reply, {:error, :provider_disabled}, state}

  def handle_call({:acquire, interval_ms}, _from, state) do
    now = state.now_fun.()
    wait_ms = max(state.next_at - now, 0)
    interval_ms = if is_integer(interval_ms), do: max(interval_ms, 0), else: state.interval_ms

    state = %{
      state
      | next_at: now + wait_ms + interval_ms,
        attempts: state.attempts + 1
    }

    {:reply, {:ok, state.generation, wait_ms}, state}
  end

  def handle_call({:current?, generation}, _from, state),
    do: {:reply, state.enabled and state.generation == generation, state}

  def handle_call({:defer, milliseconds}, _from, state) do
    not_before = state.now_fun.() + milliseconds
    {:reply, :ok, %{state | next_at: max(state.next_at, not_before)}}
  end

  def handle_call(:disable, _from, state) do
    state = %{state | enabled: false, generation: state.generation + 1}
    {:reply, {:ok, state.generation}, state}
  end

  def handle_call(:enable, _from, state),
    do: {:reply, :ok, %{state | enabled: true, next_at: 0}}

  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled, state}

  def handle_call(:stats, _from, state),
    do: {:reply, Map.take(state, [:enabled, :generation, :attempts, :next_at]), state}
end
