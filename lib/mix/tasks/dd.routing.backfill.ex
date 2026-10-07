defmodule Mix.Tasks.Dd.Routing.Backfill do
  @shortdoc "Stage 2 routing backfill: decisions, pages and approved addresses, resumably"

  @moduledoc """
  Runs `Routing.Backfill` (#194, Stage 2) over a bounded candidate population.

      DD_NO_OBAN=1 mix dd.routing.backfill \\
        --snapshot EXPORT.jsonl --population candidates.json \\
        [--reviews reviews.json] [--batch 25] [--manifest MANIFEST.json]

  The export is `docs/audits/2026-09-26-issue194/policy-export.sql`'s output
  for this database, and the population `docs/routing/stage-2/candidates.py`'s
  output for that export. Without `--reviews`, it writes classification
  decisions, draft pages and per-record dispositions, and allocates nothing.
  With them, it allocates only what a named reviewer approved.

  Re-running the same inputs resumes the run from its checkpoint, and a
  finished run writes nothing. Nothing is published. `--manifest` writes the
  candidate launch manifest, whose decision fingerprints are what a review
  file's confirmations name.

  A review file marked `"rehearsal": true` is refused except on an isolated
  rehearsal copy (`DD_STAGE2_REHEARSAL=1`, a `devils_dictionary_stage2*_*`
  database off the corpus's servers: 5434, the dictionary's own cluster since
  #211, and 5432, the shared cluster that held the pre-move copy until its
  reclaim on 7 October 2026).
  """

  use Mix.Task

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Backfill
  alias DevilsDictionary.Sources.Actor

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, extra, invalid} =
      OptionParser.parse(args,
        strict: [
          snapshot: :string,
          population: :string,
          reviews: :string,
          batch: :integer,
          manifest: :string
        ]
      )

    # A stray argument (a review file without --reviews) would otherwise run
    # without reviews and say nothing.
    unless (extra == [] and invalid == [] and opts[:snapshot]) && opts[:population] do
      Mix.raise(
        "usage: mix dd.routing.backfill --snapshot EXPORT --population CANDIDATES " <>
          "[--reviews REVIEWS] [--batch N] [--manifest OUT]"
      )
    end

    plan =
      case Backfill.load(opts[:snapshot], opts[:population], opts[:reviews],
             allow_rehearsal: rehearsal_copy?()
           ) do
        {:ok, plan} -> plan
        {:error, message} -> Mix.raise(message)
      end

    started = System.monotonic_time(:millisecond)

    summary =
      case Backfill.run(plan, importer!().id, batch_size: opts[:batch] || 25) do
        {:ok, summary} -> summary
        {:error, message} -> Mix.raise(message)
      end

    Mix.shell().info("run #{plan.run_key}")
    Mix.shell().info("  records   #{length(plan.records)}")
    Mix.shell().info("  checkpoint #{summary.items}")

    for {disposition, n} <- Enum.sort(summary.dispositions),
        do: Mix.shell().info("  #{String.pad_trailing(disposition, 24)} #{n}")

    Mix.shell().info("  elapsed   #{System.monotonic_time(:millisecond) - started} ms")

    if path = opts[:manifest] do
      File.write!(path, Jason.encode_to_iodata!(Backfill.manifest(plan.run_key), pretty: true))
      Mix.shell().info("manifest  #{path}")
    end
  end

  # Rule-made rehearsal reviews may drive a run only on an isolated
  # rehearsal copy: DD_STAGE2_REHEARSAL=1, a devils_dictionary_stage2*_*
  # database, and neither corpus server's port (5434 since #211; 5432, the
  # shared cluster that held the pre-move copy until its reclaim).
  defp rehearsal_copy? do
    config = Repo.config()

    System.get_env("DD_STAGE2_REHEARSAL") == "1" and
      Regex.match?(~r/^devils_dictionary_stage2[a-z]?_/, config[:database] || "") and
      (config[:port] || 5432) not in [5432, 5434]
  end

  # One import actor for the backfill, found by its label.
  defp importer! do
    Repo.get_by(Actor, actor_kind: :import, label: "routing backfill (#194 Stage 2)") ||
      Repo.insert!(%Actor{actor_kind: :import, label: "routing backfill (#194 Stage 2)"})
  end
end
