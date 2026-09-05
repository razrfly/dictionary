defmodule Mix.Tasks.Dd.Scope.Build do
  @shortdoc "Build a scope's membership from its rules"

  @moduledoc """
  Applies a scope's rules and writes `scope_lexemes`, recording why each lemma
  matched.

      mix dd.scope.build animals
      mix dd.scope.build animals --reset

  Prints the size per reason, which is scorecard row A4's *report* half. A rule
  that cannot run yet says so rather than contributing a silent zero.

  Options:

    * `--reset` — delete the scope's rows first, so a rule that stopped matching
      does not leave stale reasons behind
  """

  use Mix.Task

  alias DevilsDictionary.Absorb.ScopeBuilder
  alias DevilsDictionary.{Lexicon, Sources}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, [slug], _} = OptionParser.parse(args, strict: [reset: :boolean])

    scope = Lexicon.get_scope_by_slug!(slug)
    run_row = Sources.start_run("scope.build", scope_id: scope.id)
    started = System.monotonic_time(:millisecond)

    Mix.shell().info("building scope #{slug}…")

    try do
      result = ScopeBuilder.build(scope, opts)
      elapsed = System.monotonic_time(:millisecond) - started

      Sources.finish_run(run_row, %{
        "total" => result.total,
        "reasons" => result.reasons,
        "rules" => result.rules,
        "elapsed_ms" => elapsed
      })

      report(slug, result, elapsed)
    rescue
      error ->
        Sources.fail_run(run_row, Exception.message(error))
        reraise error, __STACKTRACE__
    end
  end

  defp report(slug, result, elapsed) do
    Mix.shell().info("\n#{slug} — #{result.total} lexemes in #{elapsed} ms\n")

    Enum.each(result.rules, fn {rule, info} ->
      line =
        case info do
          %{"status" => "ok", "matched" => n} -> "#{n} matched"
          %{"status" => "skipped", "reason" => reason} -> "skipped — #{reason}"
        end

      Mix.shell().info("  #{String.pad_trailing(rule, 22)} #{line}")
    end)

    Mix.shell().info("\n  by reason:")

    Enum.each(result.reasons, fn {reason, count} ->
      Mix.shell().info("    #{String.pad_trailing(reason, 20)} #{count}")
    end)

    if result.without_reason > 0 do
      Mix.shell().error("\n  #{result.without_reason} rows carry no reason (A4 requires 0)")
    end
  end
end
