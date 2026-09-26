defmodule Mix.Tasks.Dd.Routing.Verify do
  @shortdoc "Compare this database's registry and routing state with a baseline, exactly"

  @moduledoc """
  The verification step of the routing recovery procedure
  (`docs/routing/recovery.md`). Neither database is modified.

      DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2
      DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2 --projected

  Compares, section by section, every registry identity and every routing row
  by exact id and reference (`Routing.Recovery.manifest/1`), the sequences that
  hand out the next ids, and what every stored path and page id resolves to.
  Counts alone are not accepted as evidence.

  `--projected` is for the check after `mix dd.materialize --all` has
  re-projected the restored copy: sequences must then only not have fallen
  behind their tables, while every row must still match. Exits non-zero on any
  difference.

  It starts the Repo and nothing else — no Oban, no endpoint — so a restored
  copy's queued jobs and cron do not run while it is being checked.
  """

  use Mix.Task

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args, strict: [baseline: :string, projected: :boolean])

    if invalid != [] or is_nil(opts[:baseline]), do: Mix.raise("--baseline DATABASE is required")
    current = Repo.config()[:database]
    if current == opts[:baseline], do: Mix.raise("the baseline must be a different database")

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    case Repo.start_link(pool_size: 2) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {result, report} = Recovery.verify(opts[:baseline], projected: opts[:projected] || false)

    for {section, rows} <- Enum.sort(report.sections) do
      status = if Map.has_key?(report.differences, section), do: "DIFFERS", else: "exact"
      Mix.shell().info("  #{String.pad_trailing(section, 26)} #{rows} rows  #{status}")
    end

    Mix.shell().info(
      "  #{String.pad_trailing("resolutions", 26)} #{if report.resolutions_match, do: "exact", else: "DIFFER"}"
    )

    if result == :error do
      Mix.raise("#{current} does not match #{opts[:baseline]}:\n#{inspect(report, pretty: true)}")
    end

    Mix.shell().info("\n#{current} matches #{opts[:baseline]} exactly.")
  end
end
