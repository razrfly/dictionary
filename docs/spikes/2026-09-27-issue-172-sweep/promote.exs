# #172 final sweep, 2026-09-27: produced dry run (rolled back), import runs 206-208, then repeat runs 209-211 (see README.md).
# #172 final sweep: corroboration + promotion on the restored dev database.
# Repo only — no application, no Oban, no endpoint.
#
#   DRY=1 mix run --no-start promote.exs   # every scope in a rolled-back transaction
#   mix run --no-start promote.exs         # for real, one `link` run row per scope
Logger.configure(level: :warning)
for app <- [:postgrex, :ecto_sql, :telemetry], do: {:ok, _} = Application.ensure_all_started(app)
{:ok, _} = DevilsDictionary.Repo.start_link()

alias DevilsDictionary.{Lexicon, Repo, Sources}
alias DevilsDictionary.Absorb.Linker

dry? = System.get_env("DRY") == "1"
[hwm_rev, hwm_assertion] = (System.get_env("HWM") || "0,0") |> String.split(",") |> Enum.map(&String.to_integer/1)

# What happened to promoted claims since the high-water marks: new assertions,
# withdrawals and reinstatements of existing ones, by the revision written.
breakdown = fn ->
  %{rows: rows} =
    Repo.query!(
      """
      SELECT CASE WHEN a.id > $2 THEN 'promoted_new'
                  WHEN r.lifecycle_state = 'withdrawn' THEN 'withdrawn'
                  ELSE 'reinstated_or_revised' END, count(*)
        FROM assertion_revisions r JOIN assertions a ON a.id = r.assertion_id
       WHERE r.id > $1 AND r.method = 'corroborated_gloss'
       GROUP BY 1
      """,
      [hwm_rev, hwm_assertion]
    )

  %{rows: other} =
    Repo.query!(
      "SELECT r.method, count(*) FROM assertion_revisions r WHERE r.id > $1 AND r.method IS DISTINCT FROM 'corroborated_gloss' GROUP BY 1",
      [hwm_rev]
    )

  %{corroborated_gloss: Map.new(rows, &List.to_tuple/1), other_methods: Map.new(other, &List.to_tuple/1)}
end

go = fn ->
  for slug <- ~w(animals emotions culture) do
    scope = Lexicon.get_scope_by_slug!(slug)
    before = Linker.promotion_counts(scope)
    run = unless dry?, do: Sources.start_run("link", scope_id: scope.id)
    t = System.monotonic_time(:millisecond)
    written = Linker.corroborate(scope, run_id: run && run.id)
    ms = System.monotonic_time(:millisecond) - t
    after_counts = Linker.promotion_counts(scope)

    if run do
      Sources.finish_run(run, %{
        "elapsed_ms" => ms,
        "corroboration" => Map.new(written, fn {k, v} -> {to_string(k), v} end),
        "promoted_lexemes" => after_counts.promoted_lexemes,
        "word_level_lexemes" => after_counts.word_level_lexemes,
        "note" => "#172 final sweep: corroborate/1 after the #188 restore (run 205)"
      })
    end

    IO.puts("#{slug} run=#{run && run.id} #{ms}ms written=#{inspect(written)} before=#{inspect(before)} after=#{inspect(after_counts)}")
  end

  IO.puts("breakdown since HWM: " <> inspect(breakdown.()))
end

if dry? do
  Repo.transaction(fn -> go.(); Repo.rollback(:dry_run) end, timeout: :infinity)
  IO.puts("DRY RUN: rolled back")
else
  go.()
end
