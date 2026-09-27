defmodule Mix.Tasks.Dd.Routing.Verify do
  @shortdoc "Compare this database's registry and routing state with a baseline, exactly"

  @moduledoc """
  The verification step of the routing recovery procedure
  (`docs/routing/recovery.md`). Neither database is modified.

      DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2
      DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2 --projected

  The baseline is a database name on the configured server, or an `ecto://`
  URL naming one on another — for a copy restored into a separate scratch
  cluster (`DD_DATABASE_PORT`):

      DD_DATABASE=devils_dictionary_copy DD_DATABASE_PORT=5433 \\
        mix dd.routing.verify --baseline ecto://postgres:postgres@localhost:5432/devils_dictionary_v2

  Compares, section by section, every column of every table — registry
  identities, references and routing rows alike, by exact id — plus the
  schema's definitions and every sequence's state
  (`Routing.Recovery.manifest/1`), and what every stored path and page id
  resolves to. Only Oban's queue tables are left out. Counts alone are not
  accepted as evidence.

  Routing is compared only where both databases have it. When neither has any
  routing table — both predate the routing migration — the report says
  **routing: not applicable**: the corpus comparison still decides the result,
  but nothing about routing recovery has been shown. One database with the
  routing tables and one without, or either with only some of them, fails.

  `--projected` is for the check after `mix dd.materialize --all --resolve`
  has re-projected the restored copy. The projection's own bookkeeping — its
  `import_runs`, and the `updated_at`, `materialized_at` and
  `last_seen_run_id` stamps — is left out, and sequences must only not have
  fallen behind their tables; every other column must still match. Exits
  non-zero on any difference.

  It opens its own connections to the two databases and starts nothing else —
  no Oban, no endpoint — so a restored copy's queued jobs and cron do not run
  while it is being checked, and a Repo already running in the same VM cannot
  stand in for the configured database.
  """

  use Mix.Task

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: [baseline: :string, projected: :boolean])

    if invalid != [] or is_nil(opts[:baseline]),
      do: Mix.raise("--baseline DATABASE (or an ecto:// URL) is required")

    current = Recovery.identity(Repo.config())
    baseline = Recovery.identity(opts[:baseline])

    # The same database reached two ways — a socket and TCP, `localhost` and
    # an address — is still one database; the servers say which it is.
    if Recovery.same_database?(Repo.config(), opts[:baseline]),
      do:
        Mix.raise(
          "the baseline must be a different database: #{Recovery.describe(current)} and " <>
            "#{Recovery.describe(baseline)} are the same database"
        )

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    # Through a pool of its own, pointed at exactly the configured database:
    # a Repo already running in this VM may be connected to another one.
    {_host, _port, database} = current

    {result, report} =
      Recovery.with_database(database, fn ->
        Recovery.verify(opts[:baseline], projected: opts[:projected] || false)
      end)

    for {section, rows} <- Enum.sort(report.sections) do
      status = if Map.has_key?(report.differences, section), do: "DIFFERS", else: "exact"
      Mix.shell().info("  #{String.pad_trailing(section, 26)} #{rows} rows  #{status}")
    end

    Mix.shell().info("  #{String.pad_trailing("routing", 26)} #{routing(report)}")

    if result == :error do
      Mix.raise(
        "#{Recovery.describe(current)} does not match #{Recovery.describe(baseline)}:\n" <>
          inspect(report, pretty: true)
      )
    end

    suffix =
      if report.routing == :not_applicable,
        do: " Routing: not applicable, so routing recovery is not shown.",
        else: ""

    Mix.shell().info(
      "\n#{Recovery.describe(current)} matches #{Recovery.describe(baseline)} exactly.#{suffix}"
    )
  end

  defp routing(%{routing: :present, resolutions_match: true}),
    do: "every path and page resolves the same"

  defp routing(%{routing: :present}), do: "resolutions DIFFER"

  defp routing(%{routing: :not_applicable}),
    do:
      "not applicable: neither database has the routing tables (both predate the routing migration)"

  defp routing(%{routing: {:mismatch, baseline, current}}),
    do:
      "MISMATCH: the baseline's routing tables are #{state(baseline)}, this database's #{state(current)}"

  defp state(:present), do: "present"
  defp state(:absent), do: "absent"
  defp state({:partial, tables}), do: "only partly present (#{Enum.join(tables, ", ")})"

  defp state({:inconsistent, :migration_without_tables}),
    do: "missing although the routing migration is recorded"

  defp state({:inconsistent, :tables_without_migration}),
    do: "present although the routing migration is not recorded"

  defp state({:inconsistent, :no_migration_history}),
    do: "unknown: the database has no migration history"
end
