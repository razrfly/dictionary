defmodule Mix.Tasks.Dd.Doctor do
  @shortdoc "Read-only readiness checks for this installation"

  @moduledoc """
  Is this installation ready? Read-only: it starts no server, Oban node or
  model, writes nothing and downloads nothing.

      mix dd.doctor
      DD_DATABASE_PORT=5434 mix dd.doctor --expect-cluster <id> --volume "/Volumes/LLM Models"
      mix dd.doctor --bundle DIR --deep --json

  Checks the toolchain against `.tool-versions`, the PostgreSQL tools
  against the server, the server's identity and data directory, the
  database's locale, ICU collation version and settings, its extensions and
  migrations, the archived inputs and replay archive against their pins,
  the build, the HTTP port, what Oban would run, `.env` key names (never
  values) and the curation model service's files and database binding.

  **Core** checks decide whether the installation is usable; **optional**
  ones (provider credentials, the model service, inputs only a rebuild
  reads) only make it degraded. Exits 1 when a core check fails.

  ## Options

    * `--target NAME|URL` — default: the configured database
    * `--expect-cluster ID` — the `system_identifier` it must be on
    * `--volume MOUNT`, `--volume-uuid UUID` — the server's data directory
      must be on this mounted external volume
    * `--bundle DIR` — compare with a bundle's record and files
    * `--deep` — hash every file, and compare the full state with the
      bundle's (minutes at corpus scale)
    * `--json` — machine-readable output
  """

  use Mix.Task

  alias DevilsDictionary.Installation.Doctor

  @requirements ["app.config"]

  @switches [
    target: :string,
    expect_cluster: :string,
    volume: :string,
    volume_uuid: :string,
    bundle: :string,
    deep: :boolean,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [],
      do: Mix.raise("unknown arguments: #{inspect(invalid ++ rest)}; see `mix help dd.doctor`")

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    report =
      Doctor.run(
        target: opts[:target],
        expect_cluster: opts[:expect_cluster],
        volume: opts[:volume],
        uuid: opts[:volume_uuid],
        bundle: opts[:bundle],
        deep: Keyword.get(opts, :deep, false)
      )

    if opts[:json],
      do: Mix.shell().info(Jason.encode!(report, pretty: true)),
      else: Enum.each(Doctor.lines(report), fn line -> Mix.shell().info(line) end)

    unless report.usable, do: exit({:shutdown, 1})
  end
end
