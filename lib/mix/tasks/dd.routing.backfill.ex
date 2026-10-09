defmodule Mix.Tasks.Dd.Routing.Backfill do
  @shortdoc "Stage 2 routing backfill: decisions, pages and approved addresses, resumably"

  @moduledoc """
  Runs `Routing.Backfill` (#194, Stage 2) over a bounded candidate population.

      DD_NO_OBAN=1 mix dd.routing.backfill \\
        --snapshot EXPORT.jsonl --population candidates.json \\
        [--reviews reviews.json | --rule priv/routing/review-rule.json] \\
        [--batch 25] [--manifest MANIFEST.json] [--dry-run] [--decisions OUT.json]

  The export is `docs/audits/2026-09-26-issue194/policy-export.sql`'s output
  for this database, and the population `docs/routing/stage-2/candidates.py`'s
  output for that export. Without `--reviews`, it writes classification
  decisions, draft pages and per-record dispositions, and allocates nothing.
  With them, it allocates only what a named reviewer approved.

  Re-running the same inputs resumes the run from its checkpoint, and a
  finished run writes nothing. Nothing is published. `--manifest` writes the
  candidate launch manifest, whose decision fingerprints are what a review
  file's confirmations name.

  With `--rule`, the owner's signed standing review rule decides in place of
  a review file (#237): every record no human has decided, each by a clause
  of the rule, recorded on its checkpoint row and on every override it
  writes. `--dry-run` prints what the rule would decide, and writes nothing;
  `--decisions` also writes those decisions as JSON.

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
          rule: :string,
          batch: :integer,
          manifest: :string,
          dry_run: :boolean,
          decisions: :string
        ]
      )

    # A stray argument (a review file without --reviews) would otherwise run
    # without reviews and say nothing.
    unless (extra == [] and invalid == [] and opts[:snapshot]) && opts[:population] do
      Mix.raise(
        "usage: mix dd.routing.backfill --snapshot EXPORT --population CANDIDATES " <>
          "[--reviews REVIEWS | --rule RULE] [--batch N] [--manifest OUT] " <>
          "[--dry-run] [--decisions OUT]"
      )
    end

    if (opts[:dry_run] || opts[:decisions]) && !opts[:rule],
      do: Mix.raise("--dry-run and --decisions show what --rule decides: name the rule")

    plan =
      case Backfill.load(opts[:snapshot], opts[:population], opts[:reviews],
             allow_rehearsal: rehearsal_copy?(),
             rule: opts[:rule]
           ) do
        {:ok, plan} -> plan
        {:error, message} -> Mix.raise(message)
      end

    decided =
      if plan.rule do
        decisions = Backfill.decisions(plan)
        report(plan, decisions)

        if path = opts[:decisions] do
          File.write!(
            path,
            Jason.encode_to_iodata!(decisions_file(plan, decisions), pretty: true)
          )

          Mix.shell().info("decisions #{path}")
        end

        decisions
      end

    unless opts[:dry_run], do: run(plan, opts, decided)
  end

  # The run executes the decisions it printed, when the rule decided.
  defp run(plan, opts, decided) do
    started = System.monotonic_time(:millisecond)
    run_opts = [batch_size: opts[:batch] || 25] ++ if(decided, do: [decided: decided], else: [])

    summary =
      case Backfill.run(plan, importer!().id, run_opts) do
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

  # What the rule decides, before anything is written: counts by action and
  # clause, then every record the population addresses.
  defp report(plan, decisions) do
    rule = plan.rule

    Mix.shell().info(
      "rule #{rule.sha256} (#{rule.path}), signed by #{rule.signer.email} at #{rule.signature["signed_at"]}"
    )

    Mix.shell().info("run  #{plan.run_key}")

    decisions
    |> Map.values()
    |> Enum.frequencies_by(&{&1.action, &1.clause})
    |> Enum.sort()
    |> Enum.each(fn {{action, clause}, n} ->
      Mix.shell().info(
        "  #{String.pad_trailing("#{action}", 14)} #{String.pad_trailing("#{clause}", 28)} #{n}"
      )
    end)

    labels = Map.new(plan.records, &{&1["object_id"], &1["label"]})

    for {id, d} <- Enum.sort(decisions), d.action != :not_addressed do
      target = if d.action == :confirm, do: d.path, else: d.reason

      Mix.shell().info(
        "  #{String.pad_leading(Integer.to_string(id), 8)}  #{String.pad_trailing("#{d.action}", 8)} " <>
          "#{String.pad_trailing("#{d.clause}", 26)} #{labels[id]}: #{target}"
      )
    end
  end

  defp decisions_file(plan, decisions) do
    labels = Map.new(plan.records, &{&1["object_id"], &1["label"]})

    %{
      "run_key" => plan.run_key,
      "rule_sha256" => plan.rule.sha256,
      "signer" => plan.rule.signer.email,
      "inputs" => %{
        "input_sha256" => plan.input_sha256,
        "policy_sha256" => plan.policy_sha256,
        "population_sha256" => plan.population_sha256
      },
      "counts" => decisions |> Map.values() |> Enum.frequencies_by(&"#{&1.action} #{&1.clause}"),
      "decisions" =>
        for {id, d} <- Enum.sort(decisions) do
          %{
            "object_id" => id,
            "label" => labels[id],
            "action" => Atom.to_string(d.action),
            "clause" => d.clause,
            "family" => d[:family],
            "path" => d[:path],
            "standing" => d[:standing] || false,
            "evidence_fingerprint" => d[:fingerprint],
            "reason" => d.reason
          }
        end
    }
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
