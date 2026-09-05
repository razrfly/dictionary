defmodule Mix.Tasks.Dd.Absorb do
  @shortdoc "Absorb a source into source_records and materialize it"

  @moduledoc """
  Runs a source's `absorb/2`: a dump or static file streamed into
  `source_records`, then materialized into lexemes, senses, entries, relations,
  concepts and links.

      mix dd.absorb wordnet
      mix dd.absorb wiktionary --index
      mix dd.absorb wiktionary --scope animals

  Every run writes an `import_runs` row (running → done or failed) and prints
  the numbers it produced. Those numbers are the point: they are what the
  scorecard in #69 §7 reads.

  Options:

    * `--index` — Wiktionary only: the bare-lexeme index pass over every English
      headword, rather than scoped records
    * `--scope` — restrict the absorb to a scope slug
    * `--path` — override the dump path from `sources.config`
    * `--limit` — stop after N records (for a smoke test)
    * `--rebuild-indexes` — drop the lexemes GIN indexes for the load and
      recreate them after
  """

  use Mix.Task

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
          rebuild_indexes: :boolean
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
    Mix.shell().info("\n#{slug} — #{fmt_ms(elapsed)}")

    stats
    |> Map.drop([:elapsed_ms])
    |> Enum.sort()
    |> Enum.each(fn {key, value} ->
      Mix.shell().info("  #{String.pad_trailing(to_string(key), 22)} #{fmt(value)}")
    end)
  end

  defp stringify(stats), do: Map.new(stats, fn {k, v} -> {to_string(k), v} end)

  defp fmt(n) when is_integer(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp fmt(other), do: to_string(other)

  defp fmt_ms(ms) when ms < 1_000, do: "#{ms} ms"
  defp fmt_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  defp fmt_ms(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
end
