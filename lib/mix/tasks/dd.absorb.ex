defmodule Mix.Tasks.Dd.Absorb do
  @shortdoc "Absorb a source into source_records and materialize it"

  @moduledoc """
  Runs a source's `absorb/2`: a dump or static file streamed into
  `source_records`, then materialized into lexemes, senses, entries, relations,
  concepts and links.

      mix dd.absorb wordnet
      mix dd.absorb wiktionary --index
      mix dd.absorb wiktionary --scope animals
      mix dd.absorb wikipedia --scope animals
      mix dd.absorb wikidata --scope animals
      mix dd.absorb wikipedia --scope animals --concepts

  Every run writes an `import_runs` row (running → done or failed) and prints
  the numbers it produced. Those numbers are the point: they are what the
  scorecard in #69 §7 reads.

  Options:

    * `--index` — Wiktionary only: the bare-lexeme index pass over every English
      headword, rather than scoped records
    * `--scope` — restrict the absorb to a scope slug
    * `--path` — override the dump path from `sources.config`
    * `--limit` — stop after N records (for a smoke test)
    * `--reason` — with `--scope`, only the lemmas a scope rule tagged with that
      reason (`wordnet_closure`, `wiktionary_category`, …)
    * `--rebuild-indexes` — drop the lexemes GIN indexes for the load and
      recreate them after
    * `--rate-limit-ms` — override the per-request pause from `sources.config`
    * `--max-candidates` — Wikipedia only: how many articles to keep from a
      disambiguation page (default 100; the API lists them alphabetically, so a
      low cap truncates rather than samples)
    * `--concepts` — Wikipedia only: fetch a summary for every `concepts` row
      with an enwiki sitelink and no entry, rather than probing scope lemmas.
      This is scorecard row A7, and it is the pass that gives the taxa and the
      disambiguation candidates their text and thumbnails.
    * `--max-depth` — Wikidata only: how many parent tiers to walk (default 30)
    * `--refresh` — Wikidata only: refetch seed entities already stored, rather
      than only the tiers that are missing
    * `--strict` — raise on the first HTTP failure instead of counting it and
      carrying on. Use it on a smoke run; leave it off for a 20,000-lemma pass.
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.{Absorb, Lexicon, Sources}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, [slug], _} =
      OptionParser.parse(args,
        strict: [
          index: :boolean,
          scope: :string,
          path: :string,
          limit: :integer,
          reason: :string,
          rebuild_indexes: :boolean,
          concepts: :boolean,
          max_candidates: :integer,
          max_depth: :integer,
          refresh: :boolean,
          rate_limit_ms: :integer,
          strict: :boolean
        ]
      )

    module = Absorb.source_module!(slug)
    source = Sources.get_source_by_slug!(slug)
    scope = opts[:scope] && Lexicon.get_scope_by_slug!(opts[:scope])

    task = if opts[:index], do: "index", else: "absorb"

    run_row =
      Sources.start_run(task, source_id: source.id, scope_id: scope && scope.id)

    started = System.monotonic_time(:millisecond)
    Mix.shell().info("#{slug}: #{task}#{(scope && " (scope: #{scope.slug})") || ""}…")

    try do
      {:ok, stats} = module.absorb(scope, opts)
      elapsed = System.monotonic_time(:millisecond) - started

      stats = Map.put(stats, :elapsed_ms, elapsed)
      Sources.finish_run(run_row, stringify(stats))
      report(slug, stats, elapsed)
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp report(slug, stats, elapsed) do
    say("\n#{slug} — #{fmt_ms(elapsed)}")

    stats
    |> Map.drop([:elapsed_ms])
    |> Enum.sort()
    |> Enum.each(fn {key, value} ->
      row(key, value, 22)
    end)
  end
end
