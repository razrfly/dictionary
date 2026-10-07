defmodule Mix.Tasks.Dd.Bootstrap.Cluster do
  @shortdoc "Create the dictionary's own PostgreSQL cluster from a bundle's record"

  @moduledoc """
  Creates a dedicated PostgreSQL cluster for the dictionary, with the
  source database's encoding, ICU locale and the source cluster's roles
  (attributes only; no password is ever carried), and starts it.

      mix dd.bootstrap.cluster \\
        --bundle "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2" \\
        --expect-manifest-sha256 <digest> \\
        --data-dir "/Volumes/LLM Models/dictionary/postgres/18/data" --port 5434 \\
        --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31

  It prints the new cluster's `system_identifier`, which
  `mix dd.bootstrap --mode restore --target-cluster` then pins.

  Refused before anything is written: a data directory off the mounted
  external volume or already holding files, a port in use, an `initdb` of
  another major version. A cluster already running from that directory on
  that port is reported, not touched. The new cluster's ICU collation
  version must equal the source's.

  The server is started with `pg_ctl` and logs beside its data directory.
  Starting it after a reboot is an operator decision (a Postgres.app server
  entry or a launchd job); this task does not install either.

  ## Options

    * `--bundle DIR`, `--data-dir DIR`, `--port N`, `--volume MOUNT` (required)
    * `--volume-uuid UUID`, `--expect-manifest-sha256 HEX`
    * `--auth METHOD` — `pg_hba` method for local connections (default `trust`)
    * `--setting key=value` — a server setting, repeatable (for example
      `--setting wal_sync_method=fsync_writethrough --setting shared_buffers=16GB`).
      The name may be given in any case (`timezone` is `TimeZone`); a list of
      names (`shared_preload_libraries=a,b`) is written element by element.
      Refused before `initdb`: a name given twice, an extension's own
      `ext.name`, and the settings this task manages (`port`,
      `listen_addresses`, `unix_socket_directories`, the file locations).
      Each is written with `ALTER SYSTEM`, made effective (a reload, and a
      restart when one is needed), and then proven running: the file holds
      it, the server's value comes from that file, and the file has not
      changed since the server loaded it. On a cluster already running they
      are checked the same way and never changed; values are compared as
      written, so a re-run repeats the spelling it was created with.
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Installation.Cluster

  @requirements ["app.config"]

  @switches [
    bundle: :string,
    data_dir: :string,
    port: :integer,
    volume: :string,
    volume_uuid: :string,
    expect_manifest_sha256: :string,
    auth: :string,
    setting: :keep
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [],
      do:
        Mix.raise(
          "unknown arguments: #{inspect(invalid ++ rest)}; see `mix help dd.bootstrap.cluster`"
        )

    for key <- [:bundle, :data_dir, :port, :volume],
        is_nil(opts[key]),
        do: Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")

    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    case Cluster.init(
           bundle: opts[:bundle],
           data_dir: opts[:data_dir],
           port: opts[:port],
           volume: opts[:volume],
           uuid: opts[:volume_uuid],
           expect_manifest_sha256: opts[:expect_manifest_sha256],
           auth: opts[:auth] || "trust",
           settings: settings(Keyword.get_values(opts, :setting)),
           log: &say("  " <> &1)
         ) do
      {:ok, result} ->
        say("")
        row("outcome", result.outcome)
        row("system_identifier", result.system_identifier)
        row("port", Integer.to_string(result.port))
        row("data directory", result.data_dir)
        row("log", result.log_file)

        for {key, value} <- Enum.sort(result.settings),
            do: row("setting #{key}", value)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp settings(values) do
    Enum.map(values, fn value ->
      case String.split(value, "=", parts: 2) do
        [key, setting] when key != "" -> {String.trim(key), setting}
        _ -> Mix.raise("--setting takes key=value, not #{inspect(value)}")
      end
    end)
  end
end
