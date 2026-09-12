defmodule Mix.Tasks.Dd.Films.Backfill do
  @shortdoc "Backfills durable film identities from retained CineGraph results"

  @moduledoc """
  Reconciles a bounded, stable-id batch without making network requests:

      mix dd.films.backfill --limit 100
      mix dd.films.backfill --limit 100 --after 4200

  The report separates matched, newly created, insufficient and conflicting
  records. Pass the reported `--after` checkpoint to continue. Rerunning a
  batch is safe: exact identifiers converge through the shared resolver.
  """

  use Mix.Task

  alias DevilsDictionary.SourceIdentity.Backfill

  @switches [limit: :integer, after: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments; run `mix help dd.films.backfill`")

    summary = Backfill.run(limit: opts[:limit] || 100, after_id: opts[:after])

    Mix.shell().info(
      "Film identity backfill: scanned=#{summary.scanned} matched=#{summary.matched} " <>
        "newly_created=#{summary.newly_created} insufficient_evidence=#{summary.insufficient_evidence} " <>
        "conflicting_identifiers=#{summary.conflicting_identifiers}"
    )

    if summary.next_after do
      Mix.shell().info("Next checkpoint: --after #{summary.next_after}")
    else
      Mix.shell().info("Batch complete: no continuation checkpoint.")
    end
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end
