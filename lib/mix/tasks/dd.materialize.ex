defmodule Mix.Tasks.Dd.Materialize do
  @shortdoc "Re-materialize source records, or report raw-vs-derived parity"

  @moduledoc """
  Rebuilds derived rows from `source_records.raw`. No network, ever: `raw` is
  self-sufficient by design, which is what scorecard rows M1 and M2 are about.

      mix dd.materialize --source wiktionary
      mix dd.materialize --source wiktionary --all
      mix dd.materialize --dry-run

  Without `--dry-run` it materializes the records that need it — never
  materialized, or materialized before the payload they now hold was fetched
  (#69 §5's "needs materialization"). `--all` forces every record, which is the
  offline rebuild M2 measures.

  With `--dry-run` it writes nothing and instead runs `materialize/1` over every
  record, comparing what it emits against what the database holds, by natural
  key. Scorecard row **M1** wants zero gaps.

  Options:

    * `--source` — one source slug; defaults to every implemented source
    * `--dry-run` — compare only, write nothing
    * `--all` — ignore the "needs materialization" filter, and check M2
    * `--resolve` — after materializing, run the resolver for the source, and
      include `pending_relations` in M2 (`Absorb.SemanticReplay`); without it,
      `--all` re-creates drained pending edges and cannot compare them
    * `--limit` — stop after roughly N records (a smoke test)
  """

  use Mix.Task

  alias DevilsDictionary.{Absorb, Health, Sources}
  alias DevilsDictionary.Absorb.{Batch, SemanticReplay}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          source: :string,
          dry_run: :boolean,
          all: :boolean,
          resolve: :boolean,
          limit: :integer
        ]
      )

    slugs = if opts[:source], do: [opts[:source]], else: Absorb.implemented()

    results =
      Enum.map(slugs, fn slug ->
        if opts[:dry_run], do: dry_run(slug, opts), else: materialize(slug, opts)
      end)

    if false in results,
      do: Mix.raise("semantic replay changed derived state; inspect materialize run stats")
  end

  defp dry_run(slug, opts) do
    Mix.shell().info("#{slug}: parity check (no writes)…")
    started = System.monotonic_time(:millisecond)
    result = Health.parity(slug, limit: opts[:limit])
    elapsed = System.monotonic_time(:millisecond) - started

    Mix.shell().info("\n#{slug} — #{elapsed} ms")
    Mix.shell().info("  records checked        #{result.records}")
    Mix.shell().info("  needs materialization  #{result.stale}")
    Mix.shell().info("  missing senses         #{result.missing_senses}")
    Mix.shell().info("  missing relations      #{result.missing_relations}")
    Mix.shell().info("  missing entries        #{result.missing_entries}")
    Mix.shell().info("  missing concepts       #{result.missing_concepts}")
    Mix.shell().info("  missing concept edges  #{result.missing_concept_relations}")
    Mix.shell().info("  M1 gaps                #{result.gaps} — wants 0")

    Enum.each(result.examples, fn {external_id, detail} ->
      Mix.shell().info("    #{external_id}: #{inspect(detail)}")
    end)
  end

  defp materialize(slug, opts) do
    module = Absorb.source_module!(slug)
    source = Sources.get_source_by_slug!(slug)
    all? = opts[:all] || false
    resolve? = opts[:resolve] || false

    pending = Batch.count(source, only_stale: not all?)
    Mix.shell().info("#{slug}: materializing #{pending} record(s)…")

    run_row = Sources.start_run("materialize", source_id: source.id)
    started = System.monotonic_time(:millisecond)

    try do
      # Scorecard M2 is taken around the rebuild itself — reading it back
      # afterwards would only measure the database — and, with `--resolve`,
      # around the resolve pass that closes it (`Absorb.SemanticReplay`).
      replay =
        SemanticReplay.run(module, source, all: all?, resolve: resolve?, run_id: run_row.id)

      elapsed = System.monotonic_time(:millisecond) - started

      comparison =
        if all? do
          %{
            "m2_version" => 3,
            "m2_identical" => replay.identical,
            "m2_changed" => replay.changed,
            "m2_compared" => replay.compared,
            "m2_not_compared" => replay.not_compared,
            "resolved" => replay.resolved && Map.take(replay.resolved, [:resolved, :canonical])
          }
        else
          %{}
        end

      Sources.finish_run(
        run_row,
        replay.counts
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("elapsed_ms", elapsed)
        |> Map.merge(comparison)
      )

      Mix.shell().info("\n#{slug} — #{elapsed} ms")

      Enum.each(Enum.sort(replay.counts), fn {key, value} ->
        Mix.shell().info("  #{String.pad_trailing(to_string(key), 22)} #{inspect_count(value)}")
      end)

      if replay.resolved,
        do:
          Mix.shell().info(
            "  resolved               #{replay.resolved.resolved} edges, #{replay.resolved.canonical} canonical links"
          )

      if all? do
        Mix.shell().info("  semantic replay identical: #{replay.identical}")

        if replay.not_compared != [],
          do:
            Mix.shell().info(
              "  not compared: #{Enum.join(replay.not_compared, ", ")} (the resolve pass closes them: add --resolve)"
            )

        if replay.changed != %{},
          do: Mix.shell().info("  changed: #{Enum.join(Map.keys(replay.changed), ", ")}")
      end

      replay.identical != false
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp inspect_count(value) when is_map(value), do: inspect(value)
  defp inspect_count(value), do: value
end
