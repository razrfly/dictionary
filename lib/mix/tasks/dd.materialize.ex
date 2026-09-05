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
    * `--all` — ignore the "needs materialization" filter
    * `--limit` — stop after roughly N records (a smoke test)
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.{Absorb, Health, Repo, Sources}
  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, Sense}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source: :string, dry_run: :boolean, all: :boolean, limit: :integer]
      )

    slugs = if opts[:source], do: [opts[:source]], else: Absorb.implemented()

    Enum.each(slugs, fn slug ->
      if opts[:dry_run], do: dry_run(slug, opts), else: materialize(slug, opts)
    end)
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

  # Every table `materialize/1` writes into. Row counts rather than checksums:
  # an upsert that lost a row, wrote a duplicate or swapped a natural key all
  # show up here, and M1's parity check covers what counts alone would miss.
  @tables [
    lexemes: Lexeme,
    senses: Sense,
    entries: Entry,
    relations: LexicalRelation,
    concepts: Concept,
    concept_relations: ConceptRelation,
    links: ConceptLink
  ]

  defp table_counts do
    Map.new(@tables, fn {name, schema} ->
      {to_string(name), Repo.aggregate(from(r in schema), :count)}
    end)
  end

  defp m2_stats(true), do: %{}

  defp m2_stats(before) do
    now = table_counts()

    changed =
      for {k, v} <- before, now[k] != v, into: %{}, do: {k, %{"before" => v, "after" => now[k]}}

    %{"m2_identical" => changed == %{}, "m2_changed" => changed, "m2_before" => before}
  end

  defp materialize(slug, opts) do
    module = Absorb.source_module!(slug)
    source = Sources.get_source_by_slug!(slug)
    only_stale = not (opts[:all] || false)

    pending = Batch.count(source, only_stale: only_stale)
    Mix.shell().info("#{slug}: materializing #{pending} record(s)…")

    run_row = Sources.start_run("materialize", source_id: source.id)
    started = System.monotonic_time(:millisecond)

    # Scorecard M2: rebuilding every derived row from `raw`, with the network
    # off, must change nothing. The check has to be taken here, around the
    # rebuild — reading it back afterwards would only measure the database, not
    # the rebuild — so `--all` records what it saw before and after.
    before = only_stale || table_counts()

    try do
      counts = Batch.run(module, source, only_stale: only_stale)
      elapsed = System.monotonic_time(:millisecond) - started

      Sources.finish_run(
        run_row,
        counts
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("elapsed_ms", elapsed)
        |> Map.merge(m2_stats(before))
      )

      Mix.shell().info("\n#{slug} — #{elapsed} ms")

      Enum.each(Enum.sort(counts), fn {key, value} ->
        Mix.shell().info("  #{String.pad_trailing(to_string(key), 22)} #{value}")
      end)
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end
end
