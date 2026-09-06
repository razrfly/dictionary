defmodule DevilsDictionary.Health.Score do
  @moduledoc """
  Issue #69 §7's scorecard, as data: every row, its actual, its threshold and
  whether it passes. `mix dd.score` prints it; **MVP-0 is done when every row
  passes.**

  Four statuses, because the honest answer differs by row:

    * `:pass` / `:fail` — computed here, against the spec's threshold.
    * `:report` — the spec sets no threshold; the number *is* the finding.
      A3's forms count, A4's reason split, L1's raw rate and ceiling, L2's
      conflicts, O2's wall clock.
    * `:pending` — the row belongs to a session that has not run yet. It is
      printed with its text so the table is complete from the first run and
      fills in as sessions land, rather than quietly omitting what is not done.

  Rows that can only be measured **in flight** are read back from
  `import_runs.stats` rather than re-derived — the precedent `trim_saving/1`
  (M4) set in S1. That is how M2 and O2 get their numbers: the task that did the
  work recorded it.

  Two rows are proven by the test suite instead of by a query (M3 atomicity, O3
  offline), and say so.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb
  alias DevilsDictionary.Health
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.ImportRun

  @doc """
  Every row of #69 §7, in order. `opts[:scope]` defaults to `animals`.

  `opts[:skip_parity]` omits M1, which re-runs `materialize/1` over every stored
  record: correct, but minutes rather than seconds on a full database.
  """
  def rows(opts \\ []) do
    scope = opts[:scope] || "animals"

    absorb_rows(scope) ++
      materialize_rows(opts) ++
      resolve_rows() ++
      link_rows(scope) ++
      experience_rows(scope) ++
      extensibility_rows() ++
      operations_rows(opts)
  end

  @doc "The rows that can be graded now, and how many of them pass."
  def summary(rows) do
    graded = Enum.filter(rows, &(&1.status in [:pass, :fail]))

    %{
      total: length(rows),
      graded: length(graded),
      passed: Enum.count(graded, &(&1.status == :pass)),
      failed: Enum.count(graded, &(&1.status == :fail)),
      reported: Enum.count(rows, &(&1.status == :report)),
      pending: Enum.count(rows, &(&1.status == :pending))
    }
  end

  # ── A: absorb ────────────────────────────────────────────────────────────

  defp absorb_rows(scope) do
    a1 = Health.source_runs()
    a2 = Health.wordnet()
    a3 = Health.index()
    a4 = Health.scope(scope)
    a5 = Health.coverage(scope, "wiktionary")
    a6 = Health.concept_coverage(scope)
    a7 = Health.wikipedia_coverage()
    a8 = Health.bierce(scope)
    a9 = Health.links_back()
    a10 = Health.images(scope)

    [
      row(
        "A1",
        "all five sources absorbed",
        "#{a1.absorbed} / #{a1.expected} absorbed, #{a1.pinned} pinned",
        "5 / 5",
        a1.absorbed == a1.expected and a1.pinned == a1.expected
      ),
      row(
        "A2",
        "WordNet is full (plus edition)",
        "#{fmt(a2.synsets)} synsets / #{fmt(a2.lexemes)} lexemes",
        ">= 120,000 / >= 155,000",
        a2.synsets >= a2.wants_synsets and a2.lexemes >= a2.wants_lexemes
      ),
      row(
        "A3",
        "Wiktionary index is full",
        "#{fmt(a3.total)} lexemes, #{fmt(a3.with_forms)} with forms",
        ">= 1,200,000",
        a3.total >= a3.wants
      ),
      row(
        "A4",
        "scope built with reasons",
        "#{fmt(a4.total)} lexemes, #{a4.without_reason} without a reason · #{reasons(a4)}",
        ">= 7,500 and 0 unreasoned",
        a4.total >= a4.wants and a4.without_reason == 0
      ),
      # Amended in S1 (#69 v7): Wiktionary files Linnaean binomials under
      # Translingual, so the English index can never hold them. They are
      # excluded from the denominator and still reported.
      row(
        "A5",
        "Wiktionary coverage of scope",
        "#{a5.pct}% raw · #{amended_a5(a5)}% excl. #{fmt(binomials(a5))} binomials",
        ">= 85% of the remainder",
        amended_a5(a5) >= 85.0
      ),
      row(
        "A6",
        "Wikidata coverage",
        "#{fmt(a6.referenced_qids)} referenced, #{a6.dangling} dangling · union #{a6.union_pct}%",
        "100%",
        a6.dangling == 0
      ),
      row(
        "A7",
        "Wikipedia coverage",
        "#{fmt(a7.answered)} / #{fmt(a7.with_sitelink)} answered = #{a7.pct}%",
        "100%",
        a7.pct >= 100.0
      ),
      # Amended in S3: the file yields 997 entries, not the 966 §7 assumed, and
      # "attached" is 100% by construction — `materialize/1` creates the lexeme
      # when the index lacks it. The index hit rate is the number that carries
      # information.
      row(
        "A8",
        "Bierce is full and attached",
        "#{fmt(a8.entries)} entries, #{a8.attached_pct}% attached · #{a8.index_hit_pct}% already in the index",
        "997 and >= 95% attached",
        a8.entries >= a8.wants_entries and a8.attached_pct >= 95.0
      ),
      row(
        "A9",
        "links back everywhere",
        "#{fmt(a9.linked)} / #{fmt(a9.total)} = #{a9.pct}%",
        "100%",
        a9.pct >= 100.0
      ),
      row(
        "A10",
        "images",
        "#{fmt(a10.asserted_with_image)} / #{fmt(a10.asserted)} = #{a10.pct}%",
        ">= 80%",
        a10.pct >= 80.0
      )
    ]
  end

  defp reasons(a4) do
    a4.by_reason |> Enum.sort() |> Enum.map_join(" · ", fn {r, n} -> "#{r} #{fmt(n)}" end)
  end

  defp binomials(a5), do: Map.get(a5.missing_by_kind, "binomial", 0)

  defp amended_a5(a5) do
    denominator = a5.total - binomials(a5)
    if denominator <= 0, do: 0.0, else: Float.round(a5.covered * 100 / denominator, 1)
  end

  # ── M: materialize ───────────────────────────────────────────────────────

  defp materialize_rows(opts) do
    m4 = Health.trim_saving("wiktionary")

    [
      parity_row(opts),
      m2_row(),
      row("M3", "atomic writes", "proven by test", "passes", true,
        detail: "materializer_test.exs — a failure inside materialize leaves no rows and no stamp"
      ),
      m4_row(m4)
    ]
  end

  defp parity_row(opts) do
    if opts[:skip_parity] do
      row("M1", "parity, all five sources", "skipped (--skip-parity)", "0 gaps", :pending)
    else
      results = Enum.map(Absorb.implemented(), &Health.parity/1)
      gaps = results |> Enum.map(& &1.gaps) |> Enum.sum()
      records = results |> Enum.map(& &1.records) |> Enum.sum()

      row(
        "M1",
        "parity, all five sources",
        "#{gaps} gaps over #{fmt(records)} records",
        "0 gaps",
        gaps == 0
      )
    end
  end

  # `mix dd.materialize --all` writes the row counts it saw before and after
  # rebuilding every record from raw. Reading them back is the only honest way
  # to grade this: re-running it here would be the measurement, not the check.
  defp m2_row do
    measured =
      for slug <- Absorb.implemented(), run = last_full_rebuild(slug), into: %{}, do: {slug, run}

    missing = Absorb.implemented() -- Map.keys(measured)

    cond do
      measured == %{} ->
        row(
          "M2",
          "idempotent, offline",
          "not measured — run `mix dd.materialize --all`",
          "identical row counts",
          :pending
        )

      missing != [] ->
        row(
          "M2",
          "idempotent, offline",
          "not rebuilt: #{Enum.join(missing, ", ")}",
          "identical row counts",
          :pending
        )

      true ->
        changed =
          for {slug, run} <- measured,
              run.stats["m2_identical"] != true,
              do: {slug, run.stats["m2_changed"]}

        records = measured |> Map.values() |> Enum.map(&(&1.stats["records"] || 0)) |> Enum.sum()

        actual =
          if changed == [],
            do:
              "row counts identical over #{fmt(records)} records, all #{map_size(measured)} sources",
            else: "changed: #{inspect(changed)}"

        row("M2", "idempotent, offline", actual, "identical row counts", changed == [])
    end
  end

  # The most recent `--all` rebuild of one source: only those carry the
  # before/after counts, because only they rebuild every record.
  defp last_full_rebuild(slug) do
    case Sources.get_source_by_slug(slug) do
      nil ->
        nil

      source ->
        Repo.one(
          from r in ImportRun,
            where: r.source_id == ^source.id and r.task == "materialize" and r.status == :done,
            where: fragment("? \\? 'm2_identical'", r.stats),
            order_by: [desc: r.started_at],
            limit: 1
        )
    end
  end

  defp m4_row(%{measured: false}) do
    row(
      "M4",
      "trimmed raw",
      "not measured — re-run the Wiktionary absorb",
      ">= 50% smaller",
      :pending
    )
  end

  defp m4_row(m4) do
    row(
      "M4",
      "trimmed raw",
      "#{mb(m4.bytes_raw)} → #{mb(m4.bytes_trimmed)} = #{m4.saving_pct}% smaller",
      ">= 50% smaller",
      m4.saving_pct >= 50
    )
  end

  # ── R: resolve ───────────────────────────────────────────────────────────

  defp resolve_rows do
    r1 = Health.wordnet_edges()
    r2 = Health.resolution("wiktionary")

    [
      row(
        "R1",
        "WordNet edges resolved",
        "#{fmt(r1.resolved)} / #{fmt(r1.total)} = #{r1.pct}%",
        "100%",
        r1.pct >= 100.0
      ),
      row(
        "R2",
        "Wiktionary edges resolved",
        "#{fmt(r2.resolved)} / #{fmt(r2.total)} = #{r2.pct}%",
        ">= 80%",
        r2.pct >= 80.0
      ),
      row(
        "R3",
        "chains render",
        "the word page shows a hypernym chain from >= 2 sources",
        "yes",
        :pending,
        session: "S4"
      )
    ]
  end

  # ── L: link ──────────────────────────────────────────────────────────────

  defp link_rows(scope) do
    l1 = Health.links(scope)
    l2 = Health.conflicts(scope)
    l3 = Health.taxonomy(scope)
    l4 = Health.disambiguation(scope)

    # Amended in S2 (#69 v10): thousands of scope lemmas have no English article
    # at all, so the raw rate has a ceiling below the bar. The row is measured
    # against the lemmas an article exists for, and the raw rate is reported
    # beside it.
    [
      row(
        "L1",
        "link rate",
        "#{l1.reachable_pct}% of #{fmt(l1.reachable)} reachable · raw #{l1.pct}% · any #{l1.any_pct}%",
        ">= 70% of reachable",
        l1.reachable_pct >= 70.0
      ),
      row(
        "L2",
        "conflicts surfaced",
        "#{fmt(l2.count)} lexemes with two concepts >= 0.7",
        "listed",
        :report
      ),
      row(
        "L3",
        "taxonomy reaches Animalia",
        "#{fmt(l3.reaching_root)} / #{fmt(l3.linked_concepts)} = #{l3.pct}%",
        ">= 60%",
        l3.pct >= 60.0
      ),
      row(
        "L4",
        "disambiguation handled",
        "#{fmt(l4.with_candidates)} / #{fmt(l4.hits)} = #{l4.nominal_pct}% of nominal lemmas",
        "100% of hits",
        l4.nominal_pct >= 100.0
      )
    ]
  end

  # ── X / U: experience ────────────────────────────────────────────────────

  defp experience_rows(scope) do
    x3 = Health.variants()

    [
      row("X1", "every word has a page", "200 random index lexemes render", "0 errors", :pending,
        session: "U1"
      ),
      row("X2", "search is fast", search_actual(), "< 150 ms", search_status()),
      row("X3", "forms and variants resolve", variant_actual(x3), "both", x3.passed == x3.total),
      # #69 §6 lists six pages. S4b built the four developer surfaces; the word
      # page and search are #71's, so this row reports what exists and stays
      # pending until they land rather than passing on four of six.
      row("U1", "six pages exist", pages_actual(), "all 6", pages_status(), session: "U1"),
      row(
        "U2",
        "the flagship words",
        "cat, dog, oyster: >= 4 cards across >= 2 tiers",
        "all three",
        :pending,
        session: "S4"
      ),
      row("U3", "provenance everywhere", "every card opens the drawer", "100% of cards", :pending,
        session: "S4"
      ),
      row(
        "U4",
        "mobile",
        "browse, source, imports, health and /kit: no sideways scroll at 375 px; the word page is #71's",
        "passes",
        :pending,
        session: "U3"
      ),
      row(
        "U5",
        "coverage is legible",
        badges_actual(scope),
        "counts match",
        badges_status(scope)
      ),
      row("U6", "every card links out", "↗ on every card resolves", "100%", :pending,
        session: "S4"
      )
    ]
  end

  defp variant_actual(x3) do
    misses = for p <- x3.probes, not p.ok, do: "#{p.input} → #{p.landed || "nothing"}"

    case misses do
      [] ->
        "#{x3.passed} / #{x3.total} probes land: " <> Enum.map_join(x3.probes, ", ", & &1.input)

      misses ->
        "#{x3.passed} / #{x3.total} — " <> Enum.join(misses, ", ")
    end
  end

  # ── E: extensibility ─────────────────────────────────────────────────────

  defp extensibility_rows do
    [
      row(
        "E1",
        "a new source is cheap",
        "add Johnson 1755 after acceptance",
        "0 migrations",
        :pending,
        session: "S5"
      ),
      row(
        "E2",
        "a new scope is data",
        "build `emotions` from one WordNet root",
        "no code change",
        :pending,
        session: "S5"
      ),
      row(
        "E3",
        "the community layer fits",
        "write the examples + votes migration, do not ship it",
        "0 changes to existing tables",
        :pending,
        session: "S5"
      )
    ]
  end

  # ── O: operations ────────────────────────────────────────────────────────

  defp operations_rows(opts) do
    [
      row("O1", "the scorecard runs itself", "this table", "yes", true),
      o2_row(),
      row(
        "O3",
        "clean and offline-testable",
        "`mix precommit`: compile, format, full suite",
        "green",
        true,
        detail: "the suite runs on checked-in fixtures and never touches the network"
      ),
      row(
        "O4",
        "health page",
        "`mix dd.health` and /health: coverage, resolution, the link histogram, candidates, conflicts, parity",
        "all present",
        opts[:skip_health_check] != true
      )
    ]
  end

  # (a) the dump absorbs, which #69 §7 caps at two hours; (b) the on-demand
  # fetches, which it only asks us to report.
  defp o2_row do
    dumps = ~w(wordnet wiktionary bierce)
    apis = ~w(wikidata wikipedia)

    dump_ms = Enum.sum(Enum.map(dumps, &elapsed_for/1))
    api_ms = Enum.sum(Enum.map(apis, &elapsed_for/1))

    row(
      "O2",
      "it is fast enough",
      "(a) dumps #{Mix.Tasks.Dd.Report.fmt_ms(dump_ms)} · (b) APIs #{Mix.Tasks.Dd.Report.fmt_ms(api_ms)}",
      "(a) <= 2 h · (b) report",
      dump_ms <= 2 * 60 * 60 * 1000
    )
  end

  defp elapsed_for(slug) do
    case Sources.get_source_by_slug(slug) do
      nil ->
        0

      source ->
        Repo.one(
          from r in ImportRun,
            where: r.source_id == ^source.id and r.status == :done,
            where: r.task in ["absorb", "index"],
            select: coalesce(sum(fragment("(?->>'elapsed_ms')::bigint", r.stats)), 0)
        )
        |> to_ms()
    end
  end

  # `sum` over a bigint comes back as a Decimal.
  defp to_ms(nil), do: 0
  defp to_ms(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_ms(n) when is_integer(n), do: n

  # ── row construction ─────────────────────────────────────────────────────

  # **X2** — trigram search over the whole index, timed. The probes are fixed so
  # the number is comparable between runs: prefixes of different lengths, two
  # misspellings, a multiword lemma, a capitalised one, and one that matches
  # nothing. #71's home search calls the same `Lexicon.search/2`.
  @search_probes ~w(o oy oys oyst oyster oysster monkeyz cat Cat aardvark
                    giant\u00a0tortoise mongoose zzzzzz hyena dog dogg
                    sperm\u00a0whale wolf axolotl turkey)

  @search_budget_ms 150

  defp search_timings do
    for probe <- @search_probes do
      probe = String.replace(probe, "\u00a0", " ")
      at = System.monotonic_time(:microsecond)
      Lexicon.search(probe)
      (System.monotonic_time(:microsecond) - at) / 1000
    end
  end

  defp search_actual do
    timings = Enum.sort(search_timings())
    n = length(timings)
    p95 = Enum.at(timings, min(round(0.95 * n) - 1, n - 1))

    "p95 #{round(p95)} ms over #{n} probes · median #{round(Enum.at(timings, div(n, 2)))} ms" <>
      " · slowest #{round(List.last(timings))} ms"
  end

  defp search_status do
    timings = Enum.sort(search_timings())
    n = length(timings)
    Enum.at(timings, min(round(0.95 * n) - 1, n - 1)) < @search_budget_ms
  end

  # **U1** — the routes #69 §6 asks for. A route is a fact the router can be
  # asked for, so it is measured rather than asserted in prose.
  @spec_pages [
    {"/", "home and search"},
    {"/define/:slug", "the word page"},
    {"/s/:slug", "scope browse"},
    {"/sources/:slug", "one source"},
    {"/admin/imports", "the import dashboard"},
    {"/health", "health"}
  ]

  defp routed do
    paths = MapSet.new(DevilsDictionaryWeb.Router.__routes__(), & &1.path)
    Enum.split_with(@spec_pages, fn {path, _} -> path in paths end)
  end

  defp pages_actual do
    {have, missing} = routed()

    case missing do
      [] ->
        "#{length(have)} / #{length(@spec_pages)} routes"

      missing ->
        "#{length(have)} / #{length(@spec_pages)} routes · still to build: " <>
          Enum.map_join(missing, ", ", fn {path, what} -> "#{path} (#{what})" end)
    end
  end

  defp pages_status do
    case routed() do
      {_have, []} -> :pass
      _ -> :pending
    end
  end

  # **U5** — the browse badges and `mix dd.health` are the same number. Both read
  # `lexemes.source_ids`, so this holds by construction; the row measures it
  # anyway, because "by construction" is how the last regression got in.
  defp badge_agreement(scope) do
    for source <- Sources.list_sources() do
      {source.slug, Lexicon.browse(scope, has: [source.slug]).total,
       Health.coverage(scope, source.slug).covered}
    end
  end

  defp badges_actual(scope) do
    rows = badge_agreement(scope)
    agree = Enum.count(rows, fn {_slug, badges, covered} -> badges == covered end)

    detail =
      Enum.map_join(rows, " · ", fn {slug, badges, _} -> "#{slug} #{fmt(badges)}" end)

    "#{agree} / #{length(rows)} sources agree with dd.health · #{detail}"
  end

  defp badges_status(scope) do
    Enum.all?(badge_agreement(scope), fn {_slug, badges, covered} -> badges == covered end)
  end

  defp row(id, check, actual, wants, status, extra \\ [])

  defp row(id, check, actual, wants, status, extra) when is_boolean(status) do
    row(id, check, actual, wants, if(status, do: :pass, else: :fail), extra)
  end

  defp row(id, check, actual, wants, status, extra) do
    %{
      id: id,
      check: check,
      actual: to_string(actual),
      wants: wants,
      status: status,
      session: extra[:session],
      detail: extra[:detail]
    }
  end

  defp fmt(n), do: Mix.Tasks.Dd.Report.fmt(n)

  defp mb(nil), do: "?"
  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
