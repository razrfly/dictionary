defmodule Mix.Tasks.Dd.Link do
  @shortdoc "Run the word ↔ thing ladder and print the link rate"

  @moduledoc """
  Runs `DevilsDictionary.Absorb.Linker` over a scope and prints what it found.

      mix dd.link --scope animals
      mix dd.link --scope animals --strict-only

  Prints the confidence histogram by method, **L1 twice** — the strict ladder
  and the corroborated figure — plus L2 conflicts, L3 taxonomy reach and L4
  disambiguation, and promotion both ways (#172 C5): the lexemes a promoted
  gloss corroboration gave a sense-backed link, and the ones still read at the
  word level. The two L1 numbers are the point: #69 §5's rungs put
  `title_match` at 0.70, below L1's 0.8 bar, and only about a fifth of an
  Animals scope carries a QID, so the gap between them is the finding.

  Idempotent. Every rung upserts, so running it again after a fresh absorb
  updates the same rows rather than adding to them.

  Options:

    * `--scope` — scope slug. **Required**: there is no default population
      (#77 §2).
    * `--strict-only` — skip the corroboration pass, to see the bare ladder
    * `--threshold` — the confidence L1 counts from (default 0.8)
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.{Health, Lexicon, Sources}
  alias DevilsDictionary.Absorb.Linker

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [scope: :string, strict_only: :boolean, threshold: :float]
      )

    scope = Lexicon.get_scope_by_slug!(opts[:scope] || require_scope!("dd.link"))
    threshold = opts[:threshold] || 0.8

    run_row = Sources.start_run("link", scope_id: scope.id)
    started = System.monotonic_time(:millisecond)

    Mix.shell().info("linking #{scope.slug}…")

    try do
      written =
        Linker.run(scope,
          skip_corroboration: opts[:strict_only],
          run_id: run_row.id
        )

      elapsed = System.monotonic_time(:millisecond) - started

      links = Health.links(scope.slug, threshold)
      conflicts = Health.conflicts(scope.slug)
      taxonomy = Health.taxonomy(scope.slug)
      disambiguation = Health.disambiguation(scope.slug)
      promotion = Linker.promotion_counts(scope)

      report(written, links, conflicts, taxonomy, disambiguation, elapsed)
      promotion_section(written.corroboration, promotion)

      Sources.finish_run(run_row, %{
        "elapsed_ms" => elapsed,
        "rungs" => stringify(written.rungs),
        "corroboration" => stringify(written.corroboration),
        "retired_unevidenced_people" => written.retired_unevidenced_people,
        "retired_unsupported" => stringify(written.retired_unsupported),
        "l1_pct" => links.pct,
        "l1_strict_pct" => links.strict_pct,
        "l2_conflicts" => conflicts.count,
        "l3_pct" => taxonomy[:pct],
        "l4_hits" => disambiguation.hits,
        "promoted_lexemes" => promotion.promoted_lexemes,
        "word_level_lexemes" => promotion.word_level_lexemes
      })
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp report(written, links, conflicts, taxonomy, disambiguation, elapsed) do
    say("\nrungs — #{fmt_ms(elapsed)}")
    for {method, n} <- written.rungs, do: row(method, n)
    row("retired name-only people", written.retired_unevidenced_people)

    for {method, n} <- written.retired_unsupported,
        do: row("retired #{method}, evidence gone", n)

    if written.corroboration != %{} do
      say("\ncorroboration")
      for {kind, n} <- written.corroboration, do: row(kind, n)
    end

    say("\nhistogram (method · confidence · links)")

    for {method, confidence, n} <- links.histogram do
      say("  #{String.pad_trailing(to_string(method), 18)} #{confidence}  #{fmt(n)}")
    end

    say("\nL1  link rate over #{fmt(links.scope_total)} scope lexemes")
    row("at >= #{links.threshold}", "#{fmt(links.linked)}  #{links.pct}%")
    row("strict ladder only", "#{fmt(links.strict_linked)}  #{links.strict_pct}%")
    row("any confidence", "#{fmt(links.any_linked)}  #{links.any_pct}%")

    say("\nL2  conflicts (two concepts >= 0.7 for one lexeme)")
    row("lexemes", conflicts.count)

    for c <- Enum.take(conflicts.sample, 10) do
      say("     #{c.lemma} (#{c.pos}) — #{c.concepts} concepts")
    end

    taxonomy_section(taxonomy)

    say("\nL4  disambiguation (by lemma)")
    row("scope lemmas that hit one", fmt(disambiguation.hits))

    row(
      "with candidates stored",
      "#{fmt(disambiguation.with_candidates)}  #{disambiguation.pct}%"
    )

    row("of nominal lemmas", "#{disambiguation.nominal_pct}%")
    row("no nominal lexeme", fmt(disambiguation.non_nominal))
    row("candidate links", fmt(disambiguation.candidates))
    row("promoted to 0.6", fmt(disambiguation.promoted))
  end

  # Both ways, as L1 is: what promotion moved to a sense, and what is still
  # read for the word alone because no sense of it refers to anything.
  defp promotion_section(corroboration, promotion) do
    say("\npromotion (gloss corroboration → a sense's refers_to)")

    if Map.has_key?(corroboration, :promoted),
      do: row("written this run", fmt(corroboration.promoted), 36)

    if Map.has_key?(corroboration, :unpromoted),
      do: row("withdrawn, evidence gone", fmt(corroboration.unpromoted), 36)

    row("lexemes with a promoted sense link", fmt(promotion.promoted_lexemes), 36)
    row("lexemes still at the word level", fmt(promotion.word_level_lexemes), 36)
  end

  # A scope with no `wikidata_root` has no root to reach (#70 S5c).
  defp taxonomy_section(%{root: nil}) do
    say("\nL3  taxonomy")
    row("root", "none — this scope is not a taxonomy")
  end

  defp taxonomy_section(taxonomy) do
    say("\nL3  taxonomy reaches #{taxonomy.root}")
    row("asserted concepts", fmt(taxonomy.linked_concepts))
    row("reaching #{taxonomy.root}", "#{fmt(taxonomy.reaching_root)}  #{taxonomy.pct}%")

    row(
      "incl. candidates",
      "#{fmt(taxonomy.with_candidates_reaching)} / #{fmt(taxonomy.with_candidates)}  #{taxonomy.with_candidates_pct}%"
    )
  end
end
