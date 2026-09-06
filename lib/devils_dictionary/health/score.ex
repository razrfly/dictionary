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
    forget_page_measurements()

    bars = bars(scope)

    absorb_rows(scope, bars) ++
      materialize_rows(opts) ++
      resolve_rows() ++
      link_rows(scope, bars) ++
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

  defp absorb_rows(scope, bars) do
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
        "every source absorbed",
        "#{a1.absorbed} / #{a1.expected} absorbed, #{a1.pinned} pinned",
        "#{a1.expected} / #{a1.expected}",
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
        ">= #{fmt(a4.wants)} and 0 unreasoned",
        a4.total >= a4.wants and a4.without_reason == 0
      ),
      # Amended in S1 (#69 v7) and in the S4 audit (#69 v12): Wiktionary files
      # scientific names — binomials, and genus, family and order names alike —
      # under Translingual, so the English index can never hold them. They are
      # excluded from the denominator and still reported; the bar rose from
      # 85 % to 90 % with the wider exclusion.
      row(
        "A5",
        "Wiktionary coverage of scope",
        "#{a5.pct}% raw · #{amended_a5(a5)}% excl. #{fmt(scientific_names(a5))} scientific names",
        ">= 90% of the remainder",
        amended_a5(a5) >= 90.0
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
        "#{fmt(a7.asserted_answered)} / #{fmt(a7.asserted)} asserted = #{a7.asserted_pct}% · " <>
          "#{fmt(a7.answered)} / #{fmt(a7.with_sitelink)} incl. candidates = #{a7.pct}%",
        "100% of asserted",
        a7.asserted_pct >= 100.0,
        detail:
          "v13 (S5): graded on concepts a scope word links to at auto/confirmed. " <>
            "A 0.40 disambiguation candidate is a thing a page mentioned, and every " <>
            "summary fetched names more, so the all-sitelinked denominator grows " <>
            "faster than any pass can fill it — the split the S3 audit recommended " <>
            "for the second scope"
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
        ">= #{bars["a10"]}%",
        a10.pct >= bars["a10"]
      )
    ]
  end

  # The bars are the scope's, not Animals'. A4's 7,500, A10's 80 % and L1's
  # 70 % were measured on 21,277 animals with a Wikipedia article each; asking
  # an 809-word scope of abstract nouns to clear them grades the scope rather
  # than the pipeline. `rules["bars"]` in `priv/scopes/<slug>.json` overrides
  # any of them; the defaults are what Animals set.
  @default_bars %{"a4" => 7_500, "a10" => 80.0, "l1" => 70.0, "l3" => 60.0}

  defp bars(scope_slug) do
    case Lexicon.get_scope_by_slug(scope_slug) do
      nil -> @default_bars
      scope -> Map.merge(@default_bars, Map.get(scope.rules, "bars", %{}))
    end
  end

  # L3 asks whether a scope's things hang off its root. A scope with no
  # `wikidata_root` has no such question — *emotions* is not under Animalia and
  # never will be — so the row reports instead of failing at 0 %.
  defp l3_row(%{root: nil}, _bars) do
    row("L3", "taxonomy reaches the scope root", "no wikidata_root", "n/a", :report)
  end

  defp l3_row(l3, bars) do
    row(
      "L3",
      "taxonomy reaches #{l3.root}",
      "#{fmt(l3.reaching_root)} / #{fmt(l3.linked_concepts)} = #{l3.pct}%",
      ">= #{bars["l3"]}%",
      l3.pct >= bars["l3"]
    )
  end

  defp reasons(a4) do
    a4.by_reason |> Enum.sort() |> Enum.map_join(" · ", fn {r, n} -> "#{r} #{fmt(n)}" end)
  end

  defp scientific_names(a5), do: Map.get(a5.missing_by_kind, "scientific_name", 0)

  defp amended_a5(a5) do
    denominator = a5.total - scientific_names(a5)
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
      row("M1", "parity, every source", "skipped (--skip-parity)", "0 gaps", :pending)
    else
      results = Enum.map(Absorb.implemented(), &Health.parity/1)
      gaps = results |> Enum.map(& &1.gaps) |> Enum.sum()
      records = results |> Enum.map(& &1.records) |> Enum.sum()

      row(
        "M1",
        "parity, every source",
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
      row("R3", "chains render", chains_actual(), "yes", chains().passed == chains().total)
    ]
  end

  # ── L: link ──────────────────────────────────────────────────────────────

  defp link_rows(scope, bars) do
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
        ">= #{bars["l1"]}% of reachable",
        l1.reachable_pct >= bars["l1"]
      ),
      row(
        "L2",
        "conflicts surfaced",
        "#{fmt(l2.count)} lexemes with two concepts >= 0.7",
        "listed",
        :report
      ),
      l3_row(l3, bars),
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
      row(
        "X1",
        "every word has a page",
        pages_sample_actual(),
        "0 errors",
        word_pages().passed == word_pages().total
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
        flagships_actual(),
        "all three",
        flagships().passed == flagships().total
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
      row(
        "U6",
        "every card links out",
        cards_out_actual(),
        "100%",
        cards_link_out().passed == cards_link_out().total
      )
    ]
  end

  # **X1, U2, U6, R3** — the four rows the word page answers (#71 §8a.4). They
  # are measured by building the page rather than by rendering it, so `mix
  # dd.score` and `mix test` are looking at the same thing.
  #
  # Each is asked for twice — once for the actual, once for the status — so the
  # result is cached in the process dictionary for the length of one `rows/1`
  # call. X1 alone is 200 page builds.
  #
  # For the length of *one* call: `rows/1` forgets them first. A cache with no
  # end is not a cache, it is a stale answer waiting for a second caller — and
  # the health page's *recompute* button is exactly that second caller.
  @page_measurements [:word_pages, :flagships, :cards_link_out, :chains]

  defp forget_page_measurements do
    Enum.each(@page_measurements, &Process.delete({__MODULE__, &1}))
  end

  defp word_pages, do: once(:word_pages, &Health.word_pages/0)
  defp flagships, do: once(:flagships, &Health.flagships/0)
  defp cards_link_out, do: once(:cards_link_out, &Health.cards_link_out/0)
  defp chains, do: once(:chains, &Health.chains/0)

  defp once(key, fun) do
    case Process.get({__MODULE__, key}) do
      nil ->
        value = fun.()
        Process.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  defp pages_sample_actual do
    x1 = word_pages()
    bare = Enum.count(x1.probes, &(&1.cards == 0))

    case Enum.reject(x1.probes, & &1.ok) do
      [] ->
        "#{x1.passed} / #{x1.total} random index lexemes render · #{bare} of them bare"

      failed ->
        "#{x1.passed} / #{x1.total} render · " <>
          Enum.map_join(Enum.take(failed, 3), "; ", &"#{&1.input}: #{&1.error}")
    end
  end

  defp flagships_actual do
    flagships().probes
    |> Enum.map_join(" · ", &"#{&1.input} #{&1.cards} cards / #{&1.tiers} tiers")
  end

  defp cards_out_actual do
    u6 = cards_link_out()

    case u6.probes do
      [] ->
        "#{u6.passed} / #{u6.total} cards resolve a link out = 100%"

      missing ->
        "#{u6.passed} / #{u6.total} · no url: " <> Enum.map_join(missing, ", ", & &1.card)
    end
  end

  defp chains_actual do
    chains().probes
    |> Enum.map_join(" · ", fn p ->
      "#{p.input}: WordNet #{Enum.join(Enum.take(p.chain, 4), " > ")}" <>
        ", Wiktionary broader #{length(p.broader)}"
    end)
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

  # The three claims #69 §7 makes about the architecture rather than about the
  # data. S5 turned them from prose into measurements: E1 counts migrations,
  # E2 counts scopes that exist without a code change, and E3 — like M3 — is
  # proven by an experiment that cannot live in a query.
  defp extensibility_rows do
    [e1_row(), e2_row(), e3_row()]
  end

  # "0 migrations" is literal: the baseline schema and Oban's job table are the
  # only two this app has ever run, and adding the sixth source did not make a
  # third. Every enum-like column is a plain string backed by `Ecto.Enum`, so a
  # new tier, kind or relation type would not make one either.
  @baseline_migrations 2
  @proof_source "johnson"

  defp e1_row do
    migrations = Repo.aggregate("schema_migrations", :count)
    added? = @proof_source in Absorb.implemented()

    actual =
      if added? do
        "#{@proof_source}: 1 sources row, 1 module, 1 registry line; #{migrations} migrations"
      else
        "#{@proof_source} not added; #{migrations} migrations"
      end

    row(
      "E1",
      "a new source is cheap",
      actual,
      "0 migrations",
      added? and migrations == @baseline_migrations,
      detail: "the baseline schema and Oban's job table; the sixth source added neither"
    )
  end

  # Every scope, `animals` included, is now a `priv/scopes/<slug>.json` file
  # read by `Catalog.scopes/0` — there is no scope defined in Elixir to point
  # at. So the measure is: more than one scope is built, and every member of
  # every one of them knows why it is there (the question A4 asks of the first).
  defp e2_row do
    built =
      for scope <- Lexicon.list_scopes(),
          total = Lexicon.count_scope_lexemes(scope),
          total > 0,
          do: {scope, total, Lexicon.count_scope_lexemes_without_reason(scope)}

    actual =
      case built do
        [] ->
          "no scope built"

        scopes ->
          Enum.map_join(scopes, " · ", fn {scope, total, _} ->
            "#{scope.slug} #{fmt(total)} from #{roots(scope)}"
          end) <> "; 0 code changes"
      end

    if length(built) < 2 do
      row("E2", "a new scope is data", actual, "no code change", :pending, session: "S5")
    else
      row(
        "E2",
        "a new scope is data",
        actual,
        "no code change",
        Enum.all?(built, fn {_scope, _total, without} -> without == 0 end),
        detail: "priv/scopes/*.json, created by mix dd.scope.new, built by mix dd.scope.build"
      )
    end
  end

  defp roots(scope) do
    case scope.rules["wordnet_roots"] || [] do
      [] -> "its rules"
      [one] -> "1 WordNet root (#{one})"
      many -> "#{length(many)} WordNet roots"
    end
  end

  # Like M3, this is an experiment, not a query: the migration was generated,
  # applied to a full development database, diffed against a schema dump taken
  # before it, rolled back, and moved out of `priv/repo/migrations` so it can
  # never run again. The sketch is kept because deleting the evidence would
  # make the claim unfalsifiable.
  @community_sketch "docs/sketches/community_layer_migration.exs"

  defp e3_row do
    row(
      "E3",
      "the community layer fits",
      "users + examples + votes migrate and roll back cleanly",
      "0 changes to existing tables",
      File.exists?(@community_sketch),
      detail: "#{@community_sketch} — applied, schema-diffed, rolled back, unshipped"
    )
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
    # By `sources.access`, not by a literal list: a sixth source counts the day
    # its row exists (scorecard E1). A static book is a dump for timing.
    {apis, dumps} =
      Absorb.implemented()
      |> Enum.map(&Sources.get_source_by_slug!/1)
      |> Enum.split_with(&(&1.access == :api))

    dumps = Enum.map(dumps, & &1.slug)
    apis = Enum.map(apis, & &1.slug)

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
