defmodule Mix.Tasks.Dd.Health do
  @shortdoc "Coverage, resolution, links and parity, per source"

  @moduledoc """
  The operational view of the database: what each source covers, what is still
  unresolved, how the links are distributed, and whether raw still agrees with
  derived. Scorecard row **O4**; `/admin/imports` renders the same numbers.

      mix dd.health
      mix dd.health --scope animals
      mix dd.health --parity

  `mix dd.score` grades; this one describes. Parity is off by default because it
  re-runs `materialize/1` over every stored record — right, but minutes on a
  full database.

  Options:

    * `--scope` — scope slug (default `animals`)
    * `--parity` — also run the raw-vs-derived check (M1)
    * `--source` — restrict parity to one source
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.{Absorb, Health, Lexicon, Sources}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [scope: :string, parity: :boolean, source: :string])

    scope = Lexicon.get_scope_by_slug!(opts[:scope] || "animals")
    run_row = Sources.start_run("health", scope_id: scope.id)
    started = System.monotonic_time(:millisecond)

    try do
      numbers = report(scope, opts)
      elapsed = System.monotonic_time(:millisecond) - started

      say("\n  #{fmt_ms(elapsed)}")
      Sources.finish_run(run_row, Map.put(numbers, "elapsed_ms", elapsed))
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run_row, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp report(scope, opts) do
    sources_section()
    records_section(scope)
    coverage_section(scope)
    resolution_section()
    links_section(scope)
    bierce_section(scope)
    parity_section(opts)
  end

  defp sources_section do
    a1 = Health.source_runs()
    say("\nSOURCES")

    for s <- a1.sources do
      state =
        if s.present and (s.runs || 0) > 0, do: "#{s.runs} done run(s)", else: "never absorbed"

      row(s.slug, "#{state} · #{s.snapshot || "no snapshot pin"}", 14)
    end
  end

  # The record ledger. `/admin/imports` renders `Health.records/1` too, so the
  # page and the task cannot drift.
  defp records_section(scope) do
    say("\nRECORDS")
    say("  " <> header())

    for r <- Health.records(scope.slug) do
      say(
        "  " <>
          String.pad_trailing(r.slug, 12) <>
          String.pad_trailing(to_string(r.access), 8) <>
          String.pad_leading(fmt(r.records), 10) <>
          String.pad_leading(fmt(r.absent), 9) <>
          String.pad_leading(needs_fetch(r), 12) <>
          String.pad_leading(fmt(r.needs_materialization), 11) <>
          String.pad_leading(fmt(r.changed), 9) <>
          "   " <> last_run(r.last_run)
      )
    end

    say("  needs fetch is over " <> populations())
  end

  defp header do
    String.pad_trailing("source", 12) <>
      String.pad_trailing("access", 8) <>
      String.pad_leading("records", 10) <>
      String.pad_leading("absent", 9) <>
      String.pad_leading("needs fetch", 12) <>
      String.pad_leading("needs mat.", 11) <>
      String.pad_leading("changed", 9) <>
      "   last run"
  end

  # A dump has nothing to fetch: what is in the file is in the file. An em dash
  # says "the question does not apply", where a 0 would say "nothing to do".
  defp needs_fetch(%{needs_fetch: nil}), do: "—"
  defp needs_fetch(%{needs_fetch: n}), do: fmt(n)

  defp last_run(nil), do: "never"

  defp last_run(%{task: task, status: status, at: at}) do
    "#{task} #{status} #{at |> DateTime.to_naive() |> NaiveDateTime.to_string() |> binary_part(0, 16)}"
  end

  defp populations do
    Health.records()
    |> Enum.reject(&is_nil(&1.needs_fetch_of))
    |> Enum.map_join(", ", &"#{&1.slug}: #{&1.needs_fetch_of}")
  end

  defp coverage_section(scope) do
    say("\nCOVERAGE of #{scope.slug}")

    a4 = Health.scope(scope.slug)
    row("scope lexemes", fmt(a4.total), 22)

    for {reason, n} <- Enum.sort(a4.by_reason), do: row("  #{reason}", fmt(n), 22)

    a5 = Health.coverage(scope.slug, "wiktionary")
    row("wiktionary attests", "#{ratio(a5.covered, a5.total)}", 22)

    for {kind, n} <- Enum.sort(a5.missing_by_kind), do: row("  missing: #{kind}", fmt(n), 22)

    a6 = Health.concept_coverage(scope.slug)
    row("wikidata linked", "#{fmt(a6.wikidata_linked)} (#{a6.wikidata_linked_pct}%)", 22)
    row("union of the two", "#{a6.union_pct}%", 22)
    row("referenced QIDs", "#{fmt(a6.referenced_qids)}, #{a6.dangling} dangling", 22)

    a7 = Health.wikipedia_coverage()
    row("wikipedia answered", ratio(a7.answered, a7.with_sitelink), 22)

    a10 = Health.images(scope.slug)
    row("images on concepts", "#{ratio(a10.asserted_with_image, a10.asserted)}", 22)
  end

  defp resolution_section do
    say("\nRESOLUTION")

    for slug <- ~w(wordnet wiktionary bierce) do
      r = Health.resolution(slug)
      row(slug, ratio(r.resolved, r.total), 14)

      for {type, counts} <- Enum.sort(r.by_type), counts.resolved < counts.total do
        row("  #{type}", ratio(counts.resolved, counts.total), 14)
      end
    end

    unresolved = Health.resolution("wiktionary").top_unresolved
    if unresolved != [], do: say("  most-referenced unresolved: " <> sample(unresolved))
  end

  defp sample(rows) do
    rows |> Enum.take(8) |> Enum.map_join(", ", fn {lemma, n} -> "#{lemma} (#{n})" end)
  end

  defp links_section(scope) do
    say("\nLINKS in #{scope.slug}")

    l1 = Health.links(scope.slug)
    row("at >= #{l1.threshold}", "#{fmt(l1.linked)}  #{l1.pct}%", 22)
    row("strict ladder", "#{fmt(l1.strict_linked)}  #{l1.strict_pct}%", 22)
    row("any confidence", "#{fmt(l1.any_linked)}  #{l1.any_pct}%", 22)

    for {method, confidence, n} <- l1.histogram do
      row("  #{method} #{confidence}", fmt(n), 22)
    end

    l2 = Health.conflicts(scope.slug)
    row("conflicts (>= 0.7)", fmt(l2.count), 22)

    for c <- Enum.take(l2.sample, 5),
        do: say("     #{c.lemma} (#{c.pos}) — #{c.concepts} concepts")

    case Health.taxonomy(scope.slug) do
      %{root: nil} -> row("reaching the root", "n/a — no wikidata_root", 22)
      l3 -> row("reaching #{l3.root}", "#{ratio(l3.reaching_root, l3.linked_concepts)}", 22)
    end

    l4 = Health.disambiguation(scope.slug)
    row("disambiguation hits", fmt(l4.hits), 22)
    row("  candidates stored", fmt(l4.candidates), 22)
  end

  defp bierce_section(scope) do
    a8 = Health.bierce(scope.slug)
    say("\nTHE DEAD")
    row("bierce entries", fmt(a8.entries), 22)
    row("attached to a word", "#{ratio(a8.attached, a8.entries)}", 22)
    row("already in the index", "#{ratio(a8.known_to_the_index, a8.entries)}", 22)
    row("words he introduced", fmt(a8.introduced_by_bierce), 22)
    # Two different questions, and they give two different numbers: 64 entries
    # about a scope word, 66 scope words he attests. The extra two are the
    # alternate headwords, which get a lexeme and an `alt_of` but no entry of
    # their own. The browse badges count words, so both are printed here.
    row("entries in #{scope.slug}", fmt(a8.in_scope), 22)
    row("words he attests", fmt(Health.coverage(scope.slug, "bierce").covered), 22)
  end

  defp parity_section(opts) do
    if opts[:parity] do
      say("\nPARITY (M1)")

      slugs = if opts[:source], do: [opts[:source]], else: Absorb.implemented()

      gaps =
        Enum.map(slugs, fn slug ->
          result = Health.parity(slug)
          row(slug, "#{result.gaps} gaps over #{fmt(result.records)} records", 14)
          result.gaps
        end)

      %{"parity_gaps" => Enum.sum(gaps)}
    else
      say("\nPARITY  not run (pass --parity)")
      %{}
    end
  end
end
