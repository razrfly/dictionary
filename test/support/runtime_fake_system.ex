defmodule DevilsDictionary.Curation.Runtime.FakeSystem do
  @moduledoc """
  The host as the curation runtime tests want it (#195).

  By default the model volume is mounted and external, the models root and
  run directory exist, memory is healthy, and no manifest file exists. A test
  changes that with `put/1`, which is scoped to the test process and every
  process it starts (through `$callers`), so async tests never see each
  other's host.

  **Processes.** `alive` is the set of running pids. `processes` is the
  process table's other rows, `%{pid, ppid, command}` (or `:unavailable`):
  only live ones are listed, and a row whose parent has died is listed under
  launchd (ppid 1), as macOS does. `signal/2` is recorded (`signals/0`) and
  ends the process unless the test said it survives that signal (`survives`,
  pid => signals). A row with `dies_with_parent: true` exits when its parent
  does, as a runner whose server shut it down.
  """

  @table __MODULE__

  @defaults %{
    volume: {:ok, %{mounted: true, external: true, device: "/dev/fake1s1"}},
    dirs: :all,
    files: %{},
    memory: [{:ok, %{swap_used_bytes: 0, swap_total_bytes: 8 * 1024 ** 3, free_percent: 60}}],
    alive: MapSet.new(),
    # pid => executable. A live pid with no entry runs the configured binary.
    commands: %{},
    processes: [],
    survives: %{},
    signals: []
  }

  @doc "Overrides the host for this test (and its processes)."
  def put(overrides) do
    ensure_table()
    :ets.insert(@table, {self(), Map.merge(state(), Map.new(overrides))})
    :ok
  end

  @doc "Adds a file the runtime may read."
  def put_file(path, body), do: put(files: Map.put(state().files, path, body))

  defp state do
    ensure_table()
    owners = [self() | Process.get(:"$callers", [])]

    Enum.find_value(owners, @defaults, fn pid ->
      case :ets.lookup(@table, pid) do
        [{^pid, state}] -> state
        [] -> nil
      end
    end)
  end

  # The table belongs to a process of its own that lives as long as the
  # suite. Owned by whichever test created it, it would vanish when that test
  # ended, taking every concurrent test's host with it.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          send(parent, {@table, :ready})
          Process.sleep(:infinity)
        rescue
          ArgumentError -> send(parent, {@table, :ready})
        end
      end)

      receive do
        {@table, :ready} -> :ok
      after
        5_000 -> raise "the fake host's table did not start"
      end
    end
  end

  def volume(_mount_point), do: state().volume

  def dir?(path) do
    case state().dirs do
      :all -> true
      dirs -> path in dirs
    end
  end

  def read_file(path) do
    case Map.fetch(state().files, path) do
      {:ok, body} -> {:ok, body}
      :error -> {:error, :enoent}
    end
  end

  # A list is a sequence: each call takes the next sample, and the last one
  # repeats.
  def memory do
    case state().memory do
      [only] ->
        only

      [next | rest] ->
        put(memory: rest)
        next
    end
  end

  def process_alive?(pid), do: MapSet.member?(state().alive, pid)

  def process_command(pid) do
    host = state()
    row = Enum.find(rows(host), &(&1.pid == pid))

    cond do
      not process_alive?(pid) -> :error
      Map.has_key?(host.commands, pid) -> {:ok, host.commands[pid]}
      row -> {:ok, row.command}
      true -> {:ok, DevilsDictionary.Curation.Runtime.Endpoint.get(:binary)}
    end
  end

  def processes do
    case state() do
      %{processes: :unavailable} ->
        {:error, :unavailable}

      host ->
        {:ok,
         for row <- rows(host), MapSet.member?(host.alive, row.pid) do
           orphaned = row.ppid > 1 and not MapSet.member?(host.alive, row.ppid)
           %{pid: row.pid, ppid: if(orphaned, do: 1, else: row.ppid), command: row.command}
         end}
    end
  end

  def signal(pid, signal) do
    host = state()
    signals = host.signals ++ [{pid, signal}]

    cond do
      not MapSet.member?(host.alive, pid) ->
        put(signals: signals)
        :error

      signal in Map.get(host.survives, pid, []) ->
        put(signals: signals)
        :ok

      true ->
        gone =
          for row <- rows(host), row.ppid == pid, Map.get(row, :dies_with_parent), do: row.pid

        put(
          signals: signals,
          alive: Enum.reduce([pid | gone], host.alive, &MapSet.delete(&2, &1))
        )

        :ok
    end
  end

  @doc "Every signal sent so far, as `{pid, signal}`, in order."
  def signals, do: state().signals

  defp rows(%{processes: :unavailable}), do: []
  defp rows(%{processes: rows}), do: rows
end
