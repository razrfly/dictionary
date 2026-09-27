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
  candidate launch manifest.
  """

  use Mix.Task

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Backfill
  alias DevilsDictionary.Sources.Actor

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          snapshot: :string,
          population: :string,
          reviews: :string,
          batch: :integer,
          manifest: :string
        ]
      )

    unless (invalid == [] and opts[:snapshot]) && opts[:population] do
      Mix.raise(
        "usage: mix dd.routing.backfill --snapshot EXPORT --population CANDIDATES " <>
          "[--reviews REVIEWS] [--batch N] [--manifest OUT]"
      )
    end

    plan =
      case Backfill.load(opts[:snapshot], opts[:population], opts[:reviews]) do
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

  # One import actor for the backfill, found by its label.
  defp importer! do
    Repo.get_by(Actor, actor_kind: :import, label: "routing backfill (#194 Stage 2)") ||
      Repo.insert!(%Actor{actor_kind: :import, label: "routing backfill (#194 Stage 2)"})
  end
end
