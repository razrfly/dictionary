defmodule Mix.Tasks.Dd.Films.Backfill do
  @shortdoc "Backfills durable film identities from retained CineGraph results"

  @moduledoc """
  Reconciles a bounded, stable-id CineGraph batch locally. The Wikidata phase
  queues legacy film refreshes through the existing enrichment worker:

      mix dd.films.backfill --wikidata --limit 100


      mix dd.films.backfill --limit 100
      mix dd.films.backfill --limit 100 --after 4200

  The report separates matched, newly created, insufficient and conflicting
  records. The Wikidata phase also reports malformed records as failed without
  stopping its batch. Pass the reported `--after` checkpoint to continue.
  Rerunning a batch is safe: exact identifiers converge through the shared resolver.
  """

  use Mix.Task

  alias DevilsDictionary.SourceIdentity.Backfill

  @switches [limit: :integer, after: :integer, wikidata: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments; run `mix help dd.films.backfill`")

    options = [limit: opts[:limit] || 100, after_id: opts[:after]]
    summary = if opts[:wikidata], do: Backfill.wikidata(options), else: Backfill.run(options)
    Mix.shell().info("Film identity backfill: " <> inspect(Map.delete(summary, :next_after)))

    if summary.next_after do
      Mix.shell().info("Next checkpoint: --after #{summary.next_after}")
    else
      Mix.shell().info("Batch complete: no continuation checkpoint.")
    end
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end
end
