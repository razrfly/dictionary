defmodule Mix.Tasks.Dd.Score do
  @shortdoc "Print the MVP-0 scorecard with actuals"

  @moduledoc """
  Issue #69 §7 as a PASS / FAIL table with the real numbers. **MVP-0 is done
  when every row passes** — this task is scorecard row O1.

      mix dd.score
      mix dd.score --scope animals
      mix dd.score --skip-parity

  Rows the spec gives no threshold are printed as `report`: the number is the
  finding, not a grade. Rows belonging to a session that has not run are
  printed as `pending` with the session that owns them, so the table is complete
  from the first run rather than quietly short.

  Exits non-zero when a computable row fails, so a session can be gated on it.

  Options:

    * `--scope` — scope slug (default `animals`)
    * `--skip-parity` — omit M1, which re-runs `materialize/1` over every stored
      record; correct, but minutes rather than seconds on a full database
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Health.Score
  alias DevilsDictionary.{Lexicon, Sources}

  @requirements ["app.start"]

  @glyph %{pass: "PASS", fail: "FAIL", report: "  · ", pending: "  ⬜"}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [scope: :string, skip_parity: :boolean])

    scope = Lexicon.get_scope_by_slug!(opts[:scope] || "animals")
    run_row = Sources.start_run("score", scope_id: scope.id)
    started = System.monotonic_time(:millisecond)

    try do
      rows = Score.rows(scope: scope.slug, skip_parity: opts[:skip_parity])
      summary = Score.summary(rows)
      elapsed = System.monotonic_time(:millisecond) - started

      report(rows, summary, elapsed)

      Sources.finish_run(
        run_row,
        %{
          "elapsed_ms" => elapsed,
          "passed" => summary.passed,
          "failed" => summary.failed,
          "graded" => summary.graded,
          "pending" => summary.pending,
          "rows" =>
            Map.new(rows, &{&1.id, %{"status" => to_string(&1.status), "actual" => &1.actual}})
        }
      )

      if summary.failed > 0, do: exit({:shutdown, 1})
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp report(rows, summary, elapsed) do
    say("\nMVP-0 scorecard — #{fmt_ms(elapsed)}\n")

    rows
    |> Enum.chunk_by(&group/1)
    |> Enum.each(fn group ->
      say("  " <> heading(hd(group)))
      Enum.each(group, &print_row/1)
      say("")
    end)

    say(
      "  #{summary.passed} / #{summary.graded} graded rows pass" <>
        ", #{summary.reported} reported, #{summary.pending} pending"
    )

    if summary.failed > 0 do
      warn("\n  #{summary.failed} row(s) failing:")
      for r <- rows, r.status == :fail, do: warn("    #{r.id}  #{r.check} — #{r.actual}")
    end
  end

  defp print_row(row) do
    line =
      "  #{@glyph[row.status]}  #{String.pad_trailing(row.id, 4)}#{String.pad_trailing(row.check, 30)} #{row.actual}"

    case row.status do
      :fail -> warn(line <> "   (wants #{row.wants})")
      :pending -> say(line <> pending_note(row))
      _ -> say(line)
    end
  end

  defp pending_note(%{session: nil}), do: ""
  defp pending_note(%{session: session}), do: "   (#{session})"

  defp group(%{id: id}), do: String.first(id)

  defp heading(%{id: id}) do
    case String.first(id) do
      "A" -> "ABSORB"
      "M" -> "MATERIALIZE"
      "R" -> "RESOLVE"
      "L" -> "LINK"
      "X" -> "EXPERIENCE"
      "U" -> "PAGES"
      "E" -> "EXTENSIBILITY"
      "O" -> "OPERATIONS"
    end
  end
end
