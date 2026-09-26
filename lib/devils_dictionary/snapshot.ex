defmodule DevilsDictionary.Snapshot do
  @moduledoc """
  Whole-database snapshots: `pg_dump` in custom format, and a restore that
  drops, recreates and `pg_restore`s one named database.

  `mix dd.snapshot` is the operator's front door and adds the checks — which
  database, and whether durable routing state would be destroyed. The functions
  here take an explicit Repo config, so the supported recovery procedure and
  its tests (`docs/routing/recovery.md`) run exactly this code against
  isolated, disposable databases.
  """

  @doc """
  Dumps `config[:database]` to `path` in pg_dump's custom format.

  `snapshot:` dumps under an exported snapshot (`pg_export_snapshot()`), so a
  caller can read the database in the very state the dump contains.
  """
  def dump!(config, path, opts \\ []) do
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
    unless File.exists?(path), do: raise(ArgumentError, "no such snapshot: #{path}")

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

  defp connection_args(config) do
    [
      "--host=#{config[:hostname] || "localhost"}",
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
