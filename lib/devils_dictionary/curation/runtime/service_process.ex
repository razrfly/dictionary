defmodule DevilsDictionary.Curation.Runtime.ServiceProcess do
  @moduledoc """
  Start, stop and inspect the one private Ollama service (#195).

  The service is one `ollama serve` process, on loopback, with its model cache
  on the external volume:

      OLLAMA_HOST=127.0.0.1:<port>          # never exposed off the machine
      OLLAMA_MODELS=<models_root>           # on the external volume
      OLLAMA_MAX_LOADED_MODELS=1            # one loaded model: personas share it
      OLLAMA_NUM_PARALLEL=1                 # one request at a time, as defense in depth
      OLLAMA_KEEP_ALIVE=10m                 # a bounded warm window
      OLLAMA_NO_CLOUD=1                     # no remote inference or web search
      HOME=<run_dir>/home                   # its key and cache stay on the volume too
      TMPDIR=<run_dir>/tmp                  # and so does any scratch file

  Ollama writes a signing key and a cache under `$HOME/.ollama` on first
  start. Without its own `HOME` that would land on the internal disk. The
  process also runs from `run_dir`, not from the caller's checkout.

  `start/1` refuses, and never falls back, when the volume is not mounted and
  external, the cache directory is missing, or the binary is absent. It
  downloads nothing. It binds the service to the connected database
  (`Runtime.Authority`), and refuses when the service is bound to another one
  unless `rebind: true`. `stop/1` is the only proof `Runtime.recover/1` accepts that
  a generation ended: the recorded process is signalled, and it, every runner
  it started and its port must all be gone before the stop is confirmed.

  The process id, log and authority marker live in `run_dir` on the same
  volume. For a service that must survive a reboot,
  `docs/curation/runtime-operations.md` says what a user LaunchAgent must
  keep. Installing one is an operator's choice, never done here.
  """

  alias DevilsDictionary.Curation.Runtime.{Authority, Endpoint}

  @stop_wait_ms 30_000
  @kill_wait_ms 5_000

  @doc """
  `%{pid, alive, listening}` for the recorded service. `alive` means the
  recorded pid is running the configured binary, not merely that the id is in
  use: after a reboot it can belong to another program.
  """
  def status(opts \\ []) do
    pid = recorded_pid(opts)

    %{
      pid: pid,
      alive: is_integer(pid) and ours?(pid, opts),
      listening: listening(opts)
    }
  end

  @doc "Starts the service. `{:ok, %{pid}}`, or `{:error, reason}` without starting anything."
  def start(opts \\ []) do
    system = Endpoint.system(opts)
    mount = Endpoint.get(:mount_point, opts)
    root = Endpoint.get(:models_root, opts)
    binary = Endpoint.get(:binary, opts)
    run_dir = Endpoint.get(:run_dir, opts)

    with {:ok, %{mounted: true, external: true}} <- normalize_volume(system.volume(mount)),
         :ok <- present(system.dir?(root), :models_root_missing),
         :ok <- present(File.regular?(binary), :runtime_binary_missing),
         :ok <- present(system.dir?(run_dir), :run_dir_missing),
         :ok <- present(not status(opts).alive and listening(opts) == [], :already_running),
         {:ok, authority} <- Authority.bind(opts) do
      log = Path.join(run_dir, "ollama.log")
      home = Path.join(run_dir, "home")
      tmp = Path.join(run_dir, "tmp")
      Enum.each([home, tmp], &File.mkdir_p!/1)

      env = [
        {"OLLAMA_HOST", "127.0.0.1:#{Endpoint.port(opts)}"},
        {"OLLAMA_MODELS", root},
        {"OLLAMA_MAX_LOADED_MODELS", "1"},
        {"OLLAMA_NUM_PARALLEL", "1"},
        {"OLLAMA_KEEP_ALIVE", "10m"},
        {"OLLAMA_NO_CLOUD", "1"},
        {"HOME", home},
        {"TMPDIR", tmp}
      ]

      {out, 0} =
        System.cmd("sh", ["-c", ~s(nohup "$0" serve >> "$1" 2>&1 & echo $!), binary, log],
          env: env,
          cd: run_dir
        )

      pid = out |> String.trim() |> String.to_integer()
      File.write!(pid_file(opts), Integer.to_string(pid))
      {:ok, %{pid: pid, log: log, authority: authority["database"]}}
    end
  end

  @doc """
  Stops the recorded service and confirms it: the process and every runner
  it started are gone, and nothing listens on the port. `{:ok, %{stopped_at,
  evidence}}` or `{:error, reason}`.

  `ollama serve` loads a model by starting a runner (`llama-server`, from the
  runtime's own directory) that holds the weights. A runner that outlives its
  parent keeps 6–8 GiB, and a restart would load a second copy (#221 S1). So
  the process table is read before anything is signalled, while the runners
  are still the parent's descendants: once the parent is gone they belong to
  launchd (pid 1), and nothing else names them. A process from the runtime's
  directory that launchd already owns is a runner an earlier death left
  behind, and it is ended too.

  The parent is asked first (SIGTERM, then SIGKILL after 30 s), since it
  shuts its own runners down. Any runner still alive after that is ended the
  same way. A pid is signalled only while it still runs what it ran when the
  table was read, so a reused pid is never signalled.

  Only a recorded pid that runs the configured binary is the service. A pid
  file whose process is gone, or now belongs to another program, is stale:
  the service already ended, so it is not signalled, its leftover runners
  are, and the stop is confirmed as `"not_running"` once they are gone and
  the port is closed.

  `opts`: `:stop_wait_ms` and `:kill_wait_ms` shorten the waits, for the
  suite.
  """
  def stop(opts \\ []) do
    system = Endpoint.system(opts)

    with pid when is_integer(pid) <- recorded_pid(opts) || {:error, :no_recorded_service},
         {:ok, table} <- process_table(system) do
      parent = %{pid: pid, command: Endpoint.get(:binary, opts)}
      ours = running?(system, parent)

      children = if ours, do: descendants(table, pid), else: []
      runners = Enum.uniq_by(children ++ left_behind(table, pid, opts), & &1.pid)

      if ours, do: end_all(system, [parent], opts)
      end_all(system, Enum.filter(runners, &running?(system, &1)), opts)

      survivors = Enum.filter(runners, &running?(system, &1))

      cond do
        running?(system, parent) ->
          {:error, :still_running}

        survivors != [] ->
          {:error, {:runners_still_running, Enum.map(survivors, & &1.pid)}}

        listening(opts) != [] ->
          {:error, {:port_still_open, listening(opts)}}

        true ->
          File.rm(pid_file(opts))

          {:ok,
           %{
             stopped_at: DateTime.utc_now(),
             evidence: %{
               "stopped_pid" => pid,
               "port" => Endpoint.port(opts),
               "method" => if(ours, do: "sigterm", else: "not_running"),
               "runners" =>
                 Enum.map(runners, &%{"pid" => &1.pid, "command" => Path.basename(&1.command)})
             }
           }}
      end
    end
  end

  @doc """
  The descendants of `root` in a process table (`%{pid, ppid}` maps, any
  other keys kept), at any depth, not including `root`. The walk that gates a
  confirmed stop, and that `Bench.tree_rss/1` measures.
  """
  def descendants(table, root), do: walk(table, MapSet.new([root]), [])

  defp walk(table, parents, found) do
    children = Enum.filter(table, &(&1.ppid in parents and not MapSet.member?(parents, &1.pid)))

    case children do
      [] ->
        Enum.reverse(found)

      _ ->
        walk(
          table,
          MapSet.union(parents, MapSet.new(children, & &1.pid)),
          Enum.reverse(children) ++ found
        )
    end
  end

  # Runners an earlier death left behind: processes from the runtime's own
  # directory that launchd now owns. The service itself is one too once its
  # starting shell has exited, so the recorded pid is left to `stop/1`.
  defp left_behind(table, pid, opts) do
    dir = Path.dirname(Endpoint.get(:binary, opts))

    Enum.filter(table, &(&1.ppid == 1 and &1.pid != pid and Path.dirname(&1.command) == dir))
  end

  defp process_table(system) do
    case system.processes() do
      {:ok, table} -> {:ok, table}
      {:error, _} -> {:error, :process_table_unavailable}
    end
  end

  # Still the process the table named: alive, and running the same program.
  defp running?(system, %{pid: pid, command: command}) do
    system.process_alive?(pid) and system.process_command(pid) == {:ok, command}
  end

  defp end_all(_system, [], _opts), do: :ok

  defp end_all(system, procs, opts) do
    Enum.each(procs, &system.signal(&1.pid, :term))

    unless wait_gone(system, procs, Keyword.get(opts, :stop_wait_ms, @stop_wait_ms)) do
      procs |> Enum.filter(&running?(system, &1)) |> Enum.each(&system.signal(&1.pid, :kill))
      wait_gone(system, procs, Keyword.get(opts, :kill_wait_ms, @kill_wait_ms))
    end

    :ok
  end

  # The recorded pid is this service: alive, and running the configured binary.
  defp ours?(pid, opts) do
    running?(Endpoint.system(opts), %{pid: pid, command: Endpoint.get(:binary, opts)})
  end

  defp wait_gone(system, procs, remaining) do
    cond do
      not Enum.any?(procs, &running?(system, &1)) ->
        true

      remaining <= 0 ->
        false

      true ->
        Process.sleep(250)
        wait_gone(system, procs, remaining - 250)
    end
  end

  defp listening(opts) do
    case System.cmd("lsof", ["-nP", "-iTCP:#{Endpoint.port(opts)}", "-sTCP:LISTEN", "-t"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1)
      _ -> []
    end
  end

  defp recorded_pid(opts) do
    case File.read(pid_file(opts)) do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {pid, ""} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp pid_file(opts), do: Path.join(Endpoint.get(:run_dir, opts), "ollama.pid")

  defp normalize_volume({:ok, %{mounted: true, external: true}} = ok), do: ok
  defp normalize_volume({:ok, %{mounted: true}}), do: {:error, :models_root_not_external}
  defp normalize_volume(_), do: {:error, :models_root_unmounted}

  defp present(true, _reason), do: :ok
  defp present(_false, reason), do: {:error, reason}
end
