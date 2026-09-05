defmodule Mix.Tasks.Dd.Resolve do
  @shortdoc "Fill relation targets and canonical variants"

  @moduledoc """
  Runs `DevilsDictionary.Absorb.Resolver`: points `lexical_relations.to_lemma`
  at a lexeme where we have one, and points spelling variants and inflected
  entries at their canonical lexeme.

      mix dd.resolve
      mix dd.resolve --source wiktionary

  Safe to run repeatedly — it only touches rows that are still unresolved, so
  WordNet's edges (already resolved inside its absorb) are never revisited.

  Prints scorecard row **R2**: resolved share by relation type, and the targets
  that are still unplaced, most-referenced first.

  Options:

    * `--source` — restrict to one source slug
  """

  use Mix.Task

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Sources

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [source: :string])

    source = opts[:source] && Sources.get_source_by_slug!(opts[:source])

    run_row = Sources.start_run("resolve", source_id: source && source.id)
    started = System.monotonic_time(:millisecond)

    Mix.shell().info("resolving#{(source && " (#{source.slug})") || ""}…")

    try do
      result = Resolver.run(source_id: source && source.id)
      elapsed = System.monotonic_time(:millisecond) - started

      Sources.finish_run(run_row, %{
        "resolved" => result.resolved,
        "canonical" => result.canonical,
        "by_type" => stringify_types(result.by_type),
        "elapsed_ms" => elapsed
      })

      report(result, elapsed)
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp report(result, elapsed) do
    Mix.shell().info("\nresolve — #{elapsed} ms")
    Mix.shell().info("  targets resolved this run   #{result.resolved}")
    Mix.shell().info("  canonical variants linked   #{result.canonical}")

    total = result.by_type |> Map.values() |> Enum.map(& &1.total) |> Enum.sum()
    resolved = result.by_type |> Map.values() |> Enum.map(& &1.resolved) |> Enum.sum()

    Mix.shell().info("\n  by type (resolved / total)")

    result.by_type
    |> Enum.sort_by(fn {_type, c} -> -c.total end)
    |> Enum.each(fn {type, c} ->
      Mix.shell().info(
        "    #{String.pad_trailing(type, 12)} #{c.resolved} / #{c.total}" <>
          " (#{pct(c.resolved, c.total)}%)"
      )
    end)

    Mix.shell().info("\n  R2: #{resolved} / #{total} (#{pct(resolved, total)}%) — wants >= 80%")

    if result.unresolved_lemmas != [] do
      Mix.shell().info("\n  most-referenced unresolved targets")

      Enum.each(result.unresolved_lemmas, fn {lemma, n} ->
        Mix.shell().info("    #{String.pad_trailing(lemma, 30)} #{n}")
      end)
    end
  end

  defp stringify_types(by_type) do
    Map.new(by_type, fn {type, counts} ->
      {type, Map.new(counts, fn {k, v} -> {to_string(k), v} end)}
    end)
  end

  defp pct(_part, 0), do: "0.0"
  defp pct(part, total), do: Float.round(part * 100 / total, 1) |> to_string()
end
