defmodule Mix.Tasks.Dd.Bootstrap do
  @shortdoc "Restore, initialise or rebuild a dictionary database from a bundle"

  @moduledoc """
  Sets up a dictionary database from a bundle made by `mix dd.bundle`. The
  mode is always explicit (`docs/operations/installation.md`).

  **Restore this exact installation** — the migration path. Same database
  name, another cluster, pinned by its `system_identifier`, on the external
  volume, from the approved bundle:

      mix dd.bootstrap --mode restore \\
        --bundle "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2" \\
        --expect-manifest-sha256 <digest> \\
        --target ecto://postgres@localhost:5434/devils_dictionary_v2 \\
        --target-cluster <system_identifier> \\
        --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31

  **Initialise a new development installation** from an approved bundle,
  under any `devils_dictionary*` name:

      mix dd.bootstrap --mode init --bundle DIR --expect-manifest-sha256 <digest> \\
        --target devils_dictionary_v2

  **Rebuild from pinned inputs** — checks the inputs, and prints the
  `mix dd.rebuild` commands. It restores nothing: a rebuild renumbers every
  object and never reproduces routing or curation state.

      mix dd.bootstrap --mode rebuild --bundle DIR --target devils_dictionary_rebuild

  Every check runs before anything is written; a refusal changes nothing.
  The restore goes into a marked staging database and is renamed into
  place only once its state equals the bundle's in every section, so it can
  be interrupted and run again. A target already holding the bundle's state
  is reported and left alone. No migration is applied.

  ## Options

    * `--mode restore|init|rebuild` (required)
    * `--bundle DIR`; `--target NAME|URL`
    * `--expect-manifest-sha256 HEX` — required for restore and init
    * `--target-cluster ID` — required for restore
    * `--volume MOUNT`, `--volume-uuid UUID` — required for restore: the
      target server's data directory, and placed inputs, must be on it
    * `--jobs N` — parallel `pg_restore` workers (default 4)
    * `--place-inputs DIR` — also copy the bundle's inputs into a checkout
    * `--inputs-from DIR` — rebuild: a directory holding the inputs instead
    * `--report PATH` — write the JSON report there
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Installation.Bootstrap

  @requirements ["app.config"]

  @switches [
    mode: :string,
    bundle: :string,
    target: :string,
    target_cluster: :string,
    expect_manifest_sha256: :string,
    volume: :string,
    volume_uuid: :string,
    jobs: :integer,
    place_inputs: :string,
    inputs_from: :string,
    report: :string
  ]

  @modes %{"restore" => :restore, "init" => :init, "rebuild" => :rebuild}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [],
      do: Mix.raise("unknown arguments: #{inspect(invalid ++ rest)}; see `mix help dd.bootstrap`")

    mode =
      Map.get(@modes, opts[:mode]) ||
        Mix.raise("--mode restore|init|rebuild is required; see `mix help dd.bootstrap`")

    if is_nil(opts[:target]), do: Mix.raise("--target is required")
    if mode != :rebuild and is_nil(opts[:bundle]), do: Mix.raise("--bundle is required")

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    result =
      Bootstrap.run(mode,
        bundle: opts[:bundle],
        target: opts[:target],
        target_cluster: opts[:target_cluster],
        expect_manifest_sha256: opts[:expect_manifest_sha256],
        volume: opts[:volume],
        uuid: opts[:volume_uuid],
        jobs: opts[:jobs],
        place_inputs: opts[:place_inputs],
        inputs_from: opts[:inputs_from],
        report: opts[:report],
        log: &say("  " <> &1)
      )

    case result do
      {:ok, report} -> print(report)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp print(%{mode: :rebuild} = report) do
    say("")
    say("  Inputs verified against this checkout's pins. To rebuild #{report.target}:")
    say("")
    for command <- report.commands, do: say("    " <> command)
    say("")
    say("  " <> report.note)
  end

  defp print(report) do
    say("")
    row("outcome", report.outcome)
    row("target", report.target)
    row("cluster", report.target_cluster)
    row("database oid", report.database_oid)
    row("manifest sha256", report.manifest_sha256)
    row("elapsed", fmt_ms(report.elapsed_ms))

    case report.pending_migrations do
      [] ->
        :ok

      pending ->
        say("")
        say("  This checkout carries #{length(pending)} migrations the bundle's schema does not:")
        say("  #{Enum.join(pending, ", ")}. Apply them only as a separate, recorded step,")
        say("  after the restore is accepted, never as part of it.")
    end
  end
end
