defmodule Mix.Tasks.Dd.Snapshot do
  @shortdoc "Dump the configured database to a file, or restore one into it"

  @moduledoc """
  Moves a built corpus to another machine without rebuilding it.

      mix dd.snapshot                                    # dump to priv/snapshots/
      mix dd.snapshot --out ~/Desktop/dictionary.dump
      mix dd.snapshot --restore ~/Desktop/dictionary.dump --database devils_dictionary_v2

  ## Why this exists rather than "just rebuild it"

  `mix dd.rebuild` is the reproducible path and stays the source of truth, but it
  is not the fast one: it reads a 2.6 GB dump, walks sixteen stages, and stages 8
  and 9 talk to Wikidata and Wikipedia for hours. Worse for a fresh machine, the
  Wiktionary input is recorded in `priv/sources/MANIFEST.json` as
  `url_is_rolling`, so re-downloading it gives *different bytes* than the pinned
  digest every measurement was taken on. A rebuilt database is therefore a
  similar database, not the same one.

  A snapshot is the same one. It is the right tool for putting an existing
  working corpus on a second machine; `mix dd.rebuild` is the right tool for
  proving the corpus can be derived from its inputs.

  ## Restoring is destructive, so it demands the name

  Following `mix dd.reset`: `--restore` requires `--database`, the name must
  match the database this environment is configured for, and it must begin with
  `devils_dictionary`. Set `DD_DATABASE` to point at another one. A restore drops
  and recreates the schema, so it is refused unless the name was typed.

  Dumping is read-only and needs no confirmation.

  ## What it does not carry

  `.env` is never read or written here — credentials move by their own route.
  `data/` and `priv/sources/` are untouched: a snapshot restores the *database*,
  not the archived inputs a rebuild reads. `mix dd.manifest` still reports those
  as missing on a fresh clone, which is accurate.

  Options:

    * `--out` — where to write the dump (default `priv/snapshots/<db>-<date>.dump`)
    * `--restore` — restore this file instead of dumping
    * `--database` — required with `--restore`; must match the configured database
    * `--jobs` — parallel workers for dump/restore (default 4)
    * `--quiet` — suppress the report
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  @requirements []

  @prefix "devils_dictionary"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          restore: :string,
          database: :string,
          jobs: :integer,
          quiet: :boolean
        ]
      )

    config = repo_config()
    quiet? = opts[:quiet] || false
    jobs = opts[:jobs] || 4

    case opts[:restore] do
      nil -> dump(config, opts, jobs, quiet?)
      path -> restore(config, path, opts, jobs, quiet?)
    end
  end

  defp dump(config, opts, _jobs, quiet?) do
    database = config[:database]
    path = Path.expand(opts[:out] || default_out(database))
    File.mkdir_p!(Path.dirname(path))

    tell(quiet?, fn -> say("dumping #{database}") end)

    started = System.monotonic_time(:millisecond)

    # Custom format so the restore can run in parallel and skip ownership.
    args =
      connection_args(config) ++
        [
          "--format=custom",
          "--compress=6",
          "--no-owner",
          "--no-privileges",
          "--file=#{path}",
          database
        ]

    run!("pg_dump", args, config)

    elapsed = System.monotonic_time(:millisecond) - started

    tell(quiet?, fn ->
      say("")
      row("database", database)
      row("file", path)
      row("size", human_size(path))
      row("elapsed", fmt_ms(elapsed))
      say("")
      say("  restore it with `mix dd.snapshot --restore #{path} --database #{database}`")
    end)
  end

  defp restore(config, path, opts, jobs, quiet?) do
    configured = config[:database]
    named = opts[:database]
    path = Path.expand(path)

    check!(named, configured)

    unless File.exists?(path) do
      Mix.raise("no such snapshot: #{path}")
    end

    tell(quiet?, fn -> say("restoring #{path} into #{named}") end)

    started = System.monotonic_time(:millisecond)

    # Drop and recreate rather than restoring over a populated schema: a
    # --clean restore into a half-built database leaves whichever objects the
    # dump did not know about, which is exactly the state nobody can reason about.
    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])

    args =
      connection_args(config) ++
        [
          "--no-owner",
          "--no-privileges",
          "--jobs=#{jobs}",
          "--dbname=#{named}",
          path
        ]

    run!("pg_restore", args, config)

    elapsed = System.monotonic_time(:millisecond) - started

    tell(quiet?, fn ->
      say("")
      row("database", named)
      row("from", path)
      row("elapsed", fmt_ms(elapsed))
      say("")
      say("  `mix ecto.migrate` next, in case the snapshot predates a migration.")
    end)
  end

  defp connection_args(config) do
    [
      "--host=#{config[:hostname] || "localhost"}",
      "--port=#{config[:port] || 5432}",
      "--username=#{config[:username] || "postgres"}"
    ]
  end

  defp run!(executable, args, config) do
    binary = System.find_executable(executable) || Mix.raise("#{executable} is not on PATH")

    env = [{"PGPASSWORD", to_string(config[:password] || "")}]

    case System.cmd(binary, args,
           env: env,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("#{executable} exited with #{status}")
    end
  end

  defp check!(nil, configured) do
    Mix.raise("""
    --database is required with --restore, and must be #{configured}.

    A restore drops and recreates the schema. As with `mix dd.reset`, the name of
    the thing being replaced has to be typed.
    """)
  end

  defp check!(named, configured) do
    unless String.starts_with?(named, @prefix) do
      Mix.raise("refusing to restore into #{named}: this task only writes #{@prefix}* databases")
    end

    unless named == configured do
      Mix.raise("""
      #{named} is not the database this environment is configured for (#{configured}).

      Set DD_DATABASE=#{named} first.
      """)
    end
  end

  defp repo_config do
    Application.load(:devils_dictionary)
    Application.get_env(:devils_dictionary, DevilsDictionary.Repo)
  end

  defp default_out(database) do
    date = Date.utc_today() |> Date.to_iso8601()
    Path.join(["priv", "snapshots", "#{database}-#{date}.dump"])
  end

  defp human_size(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} -> human_bytes(bytes)
      _ -> "unknown"
    end
  end

  defp human_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp human_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp human_bytes(bytes), do: "#{bytes} B"

  defp tell(true, _fun), do: :ok
  defp tell(false, fun), do: fun.()
end
