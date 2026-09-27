defmodule DevilsDictionary.Snapshot do
  @moduledoc """
  Whole-database snapshots: `pg_dump` in custom format, and a restore that
  drops, recreates and `pg_restore`s one named database.

  `mix dd.snapshot` is the operator's front door and adds the checks — which
  database, and whether durable routing state would be destroyed. The functions
  here take an explicit Repo config, so the supported recovery procedure and
  its tests (`docs/routing/recovery.md`) run exactly this code against
  isolated, disposable databases.

  ## Where a snapshot came from

  A restore drops its target first, so it must never land on the database the
  snapshot was taken from. Names and endpoints cannot decide that: a Unix
  socket and a TCP address can reach the same server, and two servers can
  hold databases of the same name. So a snapshot's sidecar
  (`PATH.routing.json`, written by `Routing.Recovery.snapshot!/2`) records
  the source as the server itself reports it — the cluster's
  `system_identifier` (`pg_control_system()`), the database's name and its
  oid — together with the dump's size and SHA-256. `restore!/3` refuses,
  before anything is dropped, unless:

    * the sidecar exists, parses, and records a source identity (a sidecar
      from before identities were recorded is refused, not guessed at);
    * the dump is the one the sidecar describes — the same bytes, and the
      database name its own header records;
    * the target's server identity can be read, over the same endpoint
      `pg_restore` will use;
    * the target is not the source: the same cluster, with the same database
      name or oid.

  A restore to another server, or to another database on the same server, is
  what recovery is for, and is allowed.
  """

  @doc """
  `config` with a `url:` expanded into its parts, taking precedence over them
  exactly as Ecto does, so that `config[:database]` names the database Ecto
  would connect to. A production config names its database only in the URL.
  """
  def resolve(config) do
    case config[:url] do
      nil -> config
      url -> Keyword.merge(config, Ecto.Repo.Supervisor.parse_url(url))
    end
  end

  @doc "Where `snapshot!/2` writes, and `restore!/3` reads, a dump's sidecar."
  def sidecar_path(path), do: path <> ".routing.json"

  @doc """
  The server and database `config` reaches, as the server reports them:
  `%{system_identifier:, database:, database_oid:}` (the oid is nil if the
  database does not exist yet). Connects to the maintenance database over the
  same endpoint the `pg_*` tools use. `{:error, reason}` if the server cannot
  be reached or will not say.
  """
  def database_identity(config) do
    config = resolve(config)
    database = config[:database]

    probe(maintenance(config), fn conn ->
      %{rows: [[system_identifier]]} =
        Postgrex.query!(conn, "SELECT system_identifier::text FROM pg_control_system()", [])

      oid =
        case Postgrex.query!(conn, "SELECT oid::bigint FROM pg_database WHERE datname = $1", [
               database
             ]) do
          %{rows: [[oid]]} -> oid
          %{rows: []} -> nil
        end

      %{system_identifier: system_identifier, database: database, database_oid: oid}
    end)
  end

  @doc """
  The source a snapshot's sidecar records: `{:ok, %{system_identifier:,
  database:, database_oid:}}`, or `{:error, :missing | :malformed | :legacy}`
  — `:legacy` for a sidecar written before identities were recorded.
  """
  def source(path) do
    with {:ok, recorded} <- sidecar(path) do
      case recorded do
        %{"source" => %{"system_identifier" => id, "database" => db, "database_oid" => oid}}
        when is_binary(id) and id != "" and is_binary(db) and is_integer(oid) ->
          {:ok, %{system_identifier: id, database: db, database_oid: oid}}

        %{"source" => _} ->
          {:error, :malformed}

        _legacy ->
          {:error, :legacy}
      end
    end
  end

  @doc "The sidecar's decoded JSON, or `{:error, :missing | :malformed}`."
  def sidecar(path) do
    case File.read(sidecar_path(path)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = recorded} -> {:ok, recorded}
          _ -> {:error, :malformed}
        end

      {:error, _} ->
        {:error, :missing}
    end
  end

  @doc "A dump's size and SHA-256, as the sidecar records them."
  def fingerprint(path) do
    hash =
      path
      |> File.stream!(4 * 1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    %{
      "bytes" => File.stat!(path).size,
      "sha256" => hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    }
  end

  @doc "The database name a custom-format dump's own header records, or nil."
  def archive_database(path) do
    binary = System.find_executable("pg_restore") || raise "pg_restore is not on PATH"

    case System.cmd(binary, ["--list", path], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/^;\s+dbname: (.+)$/m, output) do
          [_, name] -> String.trim(name)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether a recorded source and a target identity are the same database:
  the same cluster, and the same name or the same oid.
  """
  def same_database?(%{system_identifier: id} = source, %{system_identifier: id} = target) do
    source.database == target.database or
      (is_integer(source.database_oid) and source.database_oid == target.database_oid)
  end

  def same_database?(_source, _target), do: false

  @doc """
  `:ok` if `path` may be restored over `config[:database]`, or `{:error,
  message}`. Reads, never writes; `restore!/3` calls it before dropping
  anything. See "Where a snapshot came from" above.
  """
  def check_restore(config, path) do
    config = resolve(config)

    with :ok <- exists(path),
         {:ok, source} <- trusted_source(path),
         :ok <- bound(path, source),
         {:ok, target} <- target_identity(config) do
      if same_database?(source, target),
        do:
          {:error,
           "refusing to restore #{path} over #{target.database}: it is the database this snapshot " <>
             "was taken from (cluster #{target.system_identifier}). Restore into a separate database " <>
             "(docs/routing/recovery.md), verify it, and switch over deliberately."},
        else: :ok
    end
  end

  defp exists(path) do
    if File.regular?(path), do: :ok, else: {:error, "no such snapshot: #{path}"}
  end

  defp trusted_source(path) do
    case source(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error,
         "refusing to restore #{path}: its sidecar is #{reason}, so where it was taken from " <>
           "cannot be established. Take the snapshot again with `mix dd.snapshot`."}
    end
  end

  defp bound(path, source) do
    {:ok, recorded} = sidecar(path)

    cond do
      recorded["dump"] != fingerprint(path) ->
        {:error,
         "refusing to restore #{path}: it is not the dump its sidecar describes (size or SHA-256 differ)"}

      archive_database(path) != source.database ->
        {:error,
         "refusing to restore #{path}: its header names #{inspect(archive_database(path))}, " <>
           "but its sidecar records #{source.database}"}

      true ->
        :ok
    end
  end

  defp target_identity(config) do
    case database_identity(config) do
      {:ok, target} ->
        {:ok, target}

      {:error, reason} ->
        {:error,
         "refusing to restore over #{config[:database]}: the target server's identity cannot " <>
           "be read (#{reason})"}
    end
  end

  # The same endpoint the `pg_*` tools use (`connection_args/1`), pointed at
  # the maintenance database.
  defp maintenance(config) do
    config
    |> Keyword.take([:hostname, :port, :username, :password, :socket_dir])
    |> Keyword.put(:database, config[:maintenance_database] || "postgres")
  end

  # Runs `fun` on a connection in a process of its own, so that a server that
  # cannot be reached is an error returned, not an exit that takes the caller
  # down with it.
  defp probe(connection, fun) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          case Postgrex.start_link(connection ++ [backoff_type: :stop, sync_connect: true]) do
            {:ok, conn} ->
              try do
                {:ok, fun.(conn)}
              rescue
                error -> {:error, Exception.message(error)}
              after
                GenServer.stop(conn)
              end

            {:error, error} ->
              {:error, Exception.message(error)}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, inspect(reason)}
    after
      30_000 ->
        Process.exit(pid, :kill)
        {:error, "no answer within 30 s"}
    end
  end

  @doc """
  Dumps `config[:database]` to `path` in pg_dump's custom format.

  `snapshot:` dumps under an exported snapshot (`pg_export_snapshot()`), so a
  caller can read the database in the very state the dump contains.
  """
  def dump!(config, path, opts \\ []) do
    config = resolve(config)
    File.mkdir_p!(Path.dirname(path))
    snapshot = if opts[:snapshot], do: ["--snapshot=#{opts[:snapshot]}"], else: []

    run!(
      "pg_dump",
      connection_args(config) ++
        snapshot ++
        [
          "--format=custom",
          "--compress=6",
          "--no-owner",
          "--no-privileges",
          "--file=#{path}",
          config[:database]
        ],
      config
    )

    path
  end

  @doc """
  Drops and recreates `config[:database]`, then restores `path` into it.

  Drop and recreate rather than restoring over a populated schema: a `--clean`
  restore into a half-built database leaves whichever objects the dump did not
  know about, which is exactly the state nobody can reason about. Destructive —
  callers decide whether that is allowed.
  """
  def restore!(config, path, jobs \\ 4) do
    config = resolve(config)

    # Before anything is dropped.
    case check_restore(config, path) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    case Ecto.Adapters.Postgres.storage_down(config) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> raise "could not drop #{config[:database]}: #{inspect(reason)}"
    end

    :ok = Ecto.Adapters.Postgres.storage_up(config)

    run!(
      "pg_restore",
      connection_args(config) ++
        ["--no-owner", "--no-privileges", "--jobs=#{jobs}", "--dbname=#{config[:database]}", path],
      config
    )

    config[:database]
  end

  @doc "The table-data entries a snapshot file contains, from `pg_restore --list`."
  def tables(path) do
    binary = System.find_executable("pg_restore") || raise "pg_restore is not on PATH"

    case System.cmd(binary, ["--list", path], stderr_to_stdout: true) do
      {output, 0} ->
        for line <- String.split(output, "\n"),
            [_, table] <- [Regex.run(~r/ TABLE DATA public (\S+) /, line)],
            into: MapSet.new(),
            do: table

      {output, status} ->
        raise "pg_restore --list exited with #{status}: #{output}"
    end
  end

  # The endpoint Postgrex uses for the same config: a Unix socket directory
  # when one is configured, otherwise the host. `database_identity/1` checks
  # the server over exactly this endpoint before a restore.
  defp connection_args(config) do
    [
      "--host=#{config[:socket_dir] || config[:hostname] || "localhost"}",
      "--port=#{config[:port] || 5432}",
      "--username=#{config[:username] || "postgres"}"
    ]
  end

  defp run!(executable, args, config) do
    binary = System.find_executable(executable) || raise "#{executable} is not on PATH"
    env = [{"PGPASSWORD", to_string(config[:password] || "")}]

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "#{executable} exited with #{status}: #{output}"
    end
  end
end
