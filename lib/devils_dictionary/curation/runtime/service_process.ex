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
  a generation ended: the recorded process is signalled, and it must be gone,
  and its port closed, before the stop is confirmed.

  The process id, log and authority marker live in `run_dir` on the same
  volume. For a service that must survive a reboot,
  `docs/curation/runtime-operations.md` says what a user LaunchAgent must
  keep. Installing one is an operator's choice, never done here.
  """

  alias DevilsDictionary.Curation.Runtime.{Authority, Endpoint}

  @stop_wait_ms 30_000

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
  Stops the recorded service and confirms it: the process is gone and nothing
  listens on the port. `{:ok, %{stopped_at, evidence}}` or `{:error, reason}`.

  Only a recorded pid that runs the configured binary is signalled. A pid
  file whose process is gone, or now belongs to another program, is stale:
  the service already ended, so nothing is signalled, and the stop is
  confirmed as `"not_running"` once the port is closed.
  """
  def stop(opts \\ []) do
    system = Endpoint.system(opts)

    case recorded_pid(opts) do
      nil ->
        {:error, :no_recorded_service}

      pid ->
        method =
          if ours?(pid, opts) do
            System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

            unless wait_gone(system, pid, @stop_wait_ms),
              do: System.cmd("kill", ["-KILL", Integer.to_string(pid)])

            wait_gone(system, pid, 5_000)
            "sigterm"
          else
            "not_running"
          end

        cond do
          ours?(pid, opts) ->
            {:error, :still_running}

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
                 "method" => method
               }
             }}
        end
    end
  end

  # The recorded pid is this service: alive, and running the configured binary.
  defp ours?(pid, opts) do
    system = Endpoint.system(opts)

    system.process_alive?(pid) and
      system.process_command(pid) == {:ok, Endpoint.get(:binary, opts)}
  end

  defp wait_gone(system, pid, remaining) when remaining <= 0, do: not system.process_alive?(pid)

  defp wait_gone(system, pid, remaining) do
    if system.process_alive?(pid) do
      Process.sleep(250)
      wait_gone(system, pid, remaining - 250)
    else
      true
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
