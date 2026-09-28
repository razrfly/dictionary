defmodule DevilsDictionary.Curation.Runtime.FakeSystem do
  @moduledoc """
  The host as the curation runtime tests want it (#195).

  By default the model volume is mounted and external, the models root and
  run directory exist, memory is healthy, and no manifest file exists. A test
  changes that with `put/1`, which is scoped to the test process and every
  process it starts (through `$callers`), so async tests never see each
  other's host.
  """

  @table __MODULE__

  @defaults %{
    volume: {:ok, %{mounted: true, external: true, device: "/dev/fake1s1"}},
    dirs: :all,
    files: %{},
    memory: [{:ok, %{swap_used_bytes: 0, swap_total_bytes: 8 * 1024 ** 3, free_percent: 60}}],
    alive: MapSet.new(),
    # pid => executable. A live pid with no entry runs the configured binary.
    commands: %{}
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

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
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
    cond do
      Map.has_key?(state().commands, pid) -> {:ok, state().commands[pid]}
      process_alive?(pid) -> {:ok, DevilsDictionary.Curation.Runtime.Endpoint.get(:binary)}
      true -> :error
    end
  end
end
