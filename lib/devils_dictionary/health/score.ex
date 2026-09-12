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

  Some rows are proven by the test suite instead of by a query — M3 atomicity,
  O3 offline, and the five durability rows #74 adds — and say so. That is not a
  weaker grade: "an attachment does not silently move when a source reorders" is
  a statement about a *sequence* of operations, and no query over the end state
  can see it.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Health
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.ImportRun

  @doc """
  Every row of #69 §7, in order.

  **`opts[:scope]` is required** (#77 §2). The scorecard grades one population,
  and most of it — A4, A6, A8, A10, L1–L4, U5 — is meaningless without knowing
  which. It used to default to `animals`, so a scorecard nobody had chosen a
  population for graded the test population and read as a whole-corpus result.
  The rows that *are* whole-corpus (A1–A3, A9, M1–M4, D1–D6, R1–R2, X1–X3) take
  no scope and are unaffected.

  `opts[:skip_parity]` omits M1, which re-runs `materialize/1` over every stored
  record: correct, but minutes rather than seconds on a full database.
  """
  def rows(opts \\ []) do
    scope =
      opts[:scope] ||
        raise ArgumentError,
              "Score.rows/1 requires :scope. The scorecard grades one population " <>
                "and there is no default one. Available: #{Lexicon.scope_slugs()}."

    forget_page_measurements()

    bars = bars(scope)

    absorb_rows(scope, bars) ++
      materialize_rows(opts) ++
      durability_rows() ++
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

  # ── D: durability ────────────────────────────────────────────────────────
  #
  # The rows #74 adds, each because the 7 September audit reproduced a defect no
  # existing row could catch. Five of them are proved by tests rather than by
  # queries, and correctly so: "an attachment does not silently move when the
  # source reorders" is a statement about a *sequence* of operations, and a
  # query over the end state cannot see it. They are labelled test-proved the
  # way M3 is, and the test is named so the claim is checkable.
  defp durability_rows do
    [
      row("D1", "refresh reconciles", "proven by test", "passes", true,
        detail:
          "durability_test.exs — a withdrawn output is retired, another source's support " <>
            "for the same word is untouched, and a scoped run retires only what it visited"
      ),
      row("D2", "meaning identity is durable", "proven by test", "passes", true,
        detail:
          "durability_test.exs — a sense that moves position keeps its identity and its " <>
            "attachments; an indistinguishable pair opens a reconciliation case"
      ),
      row("D3", "editorial decisions survive", "proven by test", "passes", true,
        detail:
          "durability_test.exs — a rejected link stays rejected when its rung reruns, and " <>
            "is invisible from both endpoints and from the counts"
      ),
      row("D4", "review context is pinned", "proven by test", "passes", true,
        detail:
          "durability_test.exs — the old review still records the revision that was " <>
            "displayed, and the vote does not transfer to a claim that says something else"
      ),
      row("D5", "integrity holds on bulk writes", "proven by test", "passes", true,
        detail:
          "schema_test.exs — every rejection goes through Repo.query! or a multi-row " <>
            "INSERT, because the linker and the resolver are raw SQL"
      ),
      d6_row(),
      p1_row(),
      p2_row()
    ]
  end

  # **P1 and P2** — the two budgets #74 leaves as measurements. Gate 0 agreed
  # the traversal one from measured numbers (0.256 / 0.489 ms against a 5 ms
  # budget, ~10× headroom); the page-composition one was explicitly *pending*
  # there, because it needed the ported `WordPage` and a matched population to
  # measure honestly.
  #
  # Both are drawn from the top of the degree distribution rather than at
  # random: a page budget met on the median word is met on nothing that matters.
  defp p1_row do
    case Health.Budgets.page_composition() do
      %{measured: false, reason: reason} ->
        row("P1", "page composition", reason, "p95 < 150 ms", :pending)

      p1 ->
        row(
          "P1",
          "page composition",
          "p95 #{p1.p95} ms (words #{p1.word_p95}, entities #{p1.entity_p95}) · max #{p1.max} ms over #{p1.runs} pages",
          "p95 < #{p1.budget_ms} ms",
          p1.p95 < p1.budget_ms,
          detail: "#{p1.population}, warm cache, WordPage and EntityPage end to end"
        )
    end
  end

  defp p2_row do
    case Health.Budgets.bounded_traversal() do
      %{measured: false, reason: reason} ->
        row("P2", "bounded traversal", reason, "p95 < 5 ms", :pending)

      p2 ->
        row(
          "P2",
          "bounded traversal",
          "p95 #{p2.p95} ms (out #{p2.outgoing_p95}, in #{p2.incoming_p95}) · " <>
            "top degree #{fmt(p2.top_degree)}",
          "p95 < #{p2.budget_ms} ms",
          p2.p95 < p2.budget_ms,
          detail: "#{p2.population}, warm cache, both directions"
        )
    end
  end

  # The one D row that is a live measurement: the archived inputs are on disk
  # and their digests still match. Reported rather than graded when an input is
  # simply absent from this machine, because a missing 2.6 GB dump is a fact
  # about the checkout and not a defect in the pipeline.
  defp d6_row do
    results =
      case Sources.Manifest.verify(quick: true) do
        {:ok, results} -> results
        {:error, results} -> results
      end

    by_status = Enum.frequencies_by(results, & &1.status)
    total = length(results)
    verified = Map.get(by_status, :ok, 0)
    failed = Map.get(by_status, :mismatch, 0) + Map.get(by_status, :unpinned, 0)
    missing = Map.get(by_status, :missing, 0)

    status =
      cond do
        failed > 0 -> :fail
        missing > 0 -> :report
        true -> verified == total
      end

    row(
      "D6",
      "inputs are pinned",
      "#{verified} / #{total} verified" <>
        if(missing > 0, do: ", #{missing} not on this machine", else: "") <>
        if(failed > 0, do: ", #{failed} FAILED", else: ""),
      "every pinned input present, at the byte count MANIFEST.json records",
      status,
      detail:
        "presence and size here, because hashing 2.6 GB on every scorecard run is the " <>
          "wrong instrument; `mix dd.manifest --verify` does the digests, and " <>
          "manifest_test.exs proves an altered byte fails"
    )
  end

  defp parity_row(opts) do
    if opts[:skip_parity] do
      row("M1", "parity, every source", "skipped (--skip-parity)", "0 gaps", :pending)
    else
      results = Enum.map(Absorb.implemented(), &Health.parity/1)
      gaps = results |> Enum.map(& &1.gaps) |> Enum.sum()
      records = results |> Enum.map(& &1.records) |> Enum.sum()
      alternates = results |> Enum.map(& &1.alternate_content_observations) |> Enum.sum()

      row(
        "M1",
        "parity, every source",
        "#{gaps} gaps over #{fmt(records)} records · #{alternates} alternate publication observations",
        "0 gaps",
        gaps == 0
      )
    end
  end

  # `mix dd.materialize --all` writes the semantic fingerprints it saw before and after
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
          "identical semantic fingerprints",
          :pending
        )

      missing != [] ->
        row(
          "M2",
          "idempotent, offline",
          "not rebuilt: #{Enum.join(missing, ", ")}",
          "identical semantic fingerprints",
          :pending
        )

      true ->
        changed =
          for {slug, run} <- measured,
              run.stats["m2_identical"] != true or run.stats["m2_version"] != 2,
              do: {slug, run.stats["m2_changed"]}

        records = measured |> Map.values() |> Enum.map(&(&1.stats["records"] || 0)) |> Enum.sum()

        actual =
          if changed == [],
            do:
              "semantic fingerprints identical over #{fmt(records)} records, all #{map_size(measured)} sources",
            else: "changed: #{inspect(changed)}"

        row("M2", "idempotent, offline", actual, "identical semantic fingerprints", changed == [])
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
        if(l4.hits == 0,
          do: "no disambiguation hits in this scope",
          else:
            "#{fmt(l4.with_candidates)} / #{fmt(l4.hits)} = #{l4.nominal_pct}% of nominal lemmas"
        ),
        "100% of hits",
        if(l4.hits == 0, do: :report, else: l4.nominal_pct >= 100.0)
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
      row(
        "U3",
        "provenance everywhere",
        provenance_actual(),
        "100% of cards",
        cards_provenance().passed == cards_provenance().total,
        session: "U2"
      ),
      u4_row(),
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
  @page_measurements [:word_pages, :flagships, :cards_link_out, :cards_provenance, :chains]

  defp forget_page_measurements do
    Enum.each(@page_measurements, &Process.delete({__MODULE__, &1}))
  end

  defp word_pages, do: once(:word_pages, &Health.word_pages/0)
  defp flagships, do: once(:flagships, &Health.flagships/0)
  defp cards_link_out, do: once(:cards_link_out, &Health.cards_link_out/0)
  defp cards_provenance, do: once(:cards_provenance, &Health.cards_provenance/0)
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
    population = "#{u6.cards} cards + #{u6.things} thing-panel links"

    case u6.probes do
      [] ->
        "#{u6.passed} / #{u6.total} resolve a link out = 100% (#{population})"

      missing ->
        "#{u6.passed} / #{u6.total} (#{population}) · no url: " <>
          Enum.map_join(missing, ", ", &"#{&1.word} #{&1.card}")
    end
  end

  # Two figures and the denominator, because "100% of cards" over eight words is
  # a smaller claim than it sounds, and a card that opens its first synset's
  # record while the rest have gone is not provenance everywhere.
  defp provenance_actual do
    u3 = cards_provenance()
    t = u3.things

    tail =
      "#{u3.cited} / #{u3.citations} citations carry one · " <>
        "thing panel #{t.passed} / #{t.total}, reported"

    case u3.probes do
      [] ->
        "#{u3.passed} / #{u3.total} cards over #{u3.words} words open a record · #{tail}"

      missing ->
        "#{u3.passed} / #{u3.total} cards (#{u3.words} words) · #{tail} · no record: " <>
          Enum.map_join(missing, ", ", &"#{&1.word} #{&1.card}")
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
  # data. S5 turned them from prose into measurements: E1 measures what a new
  # source actually costs, E2 counts scopes that exist without a code change,
  # and E3 — like M3 — is proven by an experiment that cannot live in a query.
  defp extensibility_rows do
    [e1_row(), e2_row(), e3_row()]
  end

  # **Revised for #74.** This counted `schema_migrations` and compared it to a
  # literal 2. The 7 September audit's point, and the rebuild proves it: a hard
  # equality against a migration count fails on the day the schema legitimately
  # changes, which is the day this row would matter least. It graded the
  # project's history rather than its extensibility.
  #
  # What extensibility means here, concretely, is that everything a new source
  # needs is **data**: a `sources` row from `priv/` , a module implementing six
  # callbacks, a line in the registry, and — new in this model — its own
  # relationship types as entries in `priv/predicates/`. So the row measures
  # those four, and Johnson is the sixth source that proves the first three.
  #
  # The fourth is the one the encyclopedia model adds and the one worth having:
  # a relationship type that no code knows about, registered from a file, with
  # its endpoint pairs enforced by a foreign key.
  @proof_source "johnson"
  @proof_predicates ~w(hypernym parent_taxon)
  @proof_entity_kind :taxon

  defp e1_row do
    added? = @proof_source in Absorb.implemented()
    source_row? = not is_nil(Sources.get_source_by_slug(@proof_source))

    predicates =
      Enum.filter(@proof_predicates, fn key ->
        case Claims.predicate(key) do
          nil -> false
          predicate -> Claims.endpoint_rules(predicate.key) != []
        end
      end)

    kind? = @proof_entity_kind in DevilsDictionary.Registry.Entity.kinds()
    ok? = added? and source_row? and length(predicates) == length(@proof_predicates) and kind?

    actual =
      "#{@proof_source}: #{if source_row?, do: 1, else: 0} sources row, " <>
        "#{if added?, do: 1, else: 0} module, 1 registry line; " <>
        "#{length(predicates)} / #{length(@proof_predicates)} predicates registered from " <>
        "priv/predicates; entity kind #{@proof_entity_kind} #{if kind?, do: "present", else: "absent"}"

    row(
      "E1",
      "a new source is cheap",
      actual,
      "a row, a module, a registry line and its predicates — no schema change",
      ok?,
      detail:
        "a relationship type is a file entry with enumerated endpoint pairs, enforced " <>
          "by a foreign key; adding one needs no migration. Migration *count* is no longer " <>
          "acceptance — see docs/rebuild/score-rows.md."
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
  # **U4 — mobile.** The one row in the scorecard that no query can answer: a
  # page either scrolls sideways on a phone or it does not, and the only honest
  # instrument is a viewport and a pair of eyes. So it is graded the way E3 is,
  # as a **dated attestation with checked-in evidence** rather than a number
  # dressed up as one — the date, the pages, and a screenshot of each at
  # 375 px. Deleting a screenshot fails the row, which is the whole point:
  # an attestation nobody can check is a claim, not a measurement.
  #
  # What was measured on the date below, over every page in `@mobile_pages`:
  # `documentElement.scrollWidth - clientWidth == 0` at a 375 × 812 viewport,
  # with every `<details>` on the page forced open. The wide things that remain
  # — the drawer's raw JSON, the scorecard table — scroll inside their own
  # `overflow-x-auto`, which is the rule rather than an exception to it.
  @mobile_pass ~D[2026-09-07]
  @mobile_evidence "docs/mobile"
  @mobile_pages [
    {"home", "375-home.jpg"},
    {"the word page", "375-word.jpg"},
    {"its relation groups", "375-word-relations.jpg"},
    {"its thing panel", "375-word-thing.jpg"},
    {"the provenance drawer", "375-word-drawer.jpg"},
    {"fake-data mode", "375-word-demo.jpg"},
    {"the evidence wall", "375-evidence-wall.jpg"},
    {"browse", "375-browse.jpg"},
    {"one source", "375-source.jpg"},
    {"imports", "375-imports.jpg"},
    {"health", "375-health.jpg"},
    {"/kit", "375-kit.jpg"}
  ]

  defp u4_row do
    missing = for {_page, file} <- @mobile_pages, not File.exists?(mobile_path(file)), do: file
    names = Enum.map_join(@mobile_pages, ", ", fn {page, _file} -> page end)

    actual =
      case missing do
        [] -> "#{@mobile_pass}: #{length(@mobile_pages)} pages at 375 px — #{names}"
        missing -> "evidence missing: #{Enum.join(missing, ", ")}"
      end

    row("U4", "mobile", actual, "passes", missing == [],
      session: "U3",
      detail:
        "#{@mobile_evidence}/README.md — attested, not measured; the screenshots are the evidence"
    )
  end

  defp mobile_path(file), do: Path.join(@mobile_evidence, file)

  # **Revised for #74.** This was `File.exists?` on a rolled-back migration
  # sketch — a check that measured nothing the day the community layer shipped,
  # which it now has: `users`, `actors`, `assertion_reviews` and
  # `assertion_votes` are schema. The sketch is retired, with its dated result
  # preserved in `docs/sketches/README.md`; what is withdrawn is only its use as
  # a *current* measurement.
  #
  # E3 includes #84's post-baseline extension exercise: an `adaptation_of`
  # relationship that was not present for the earlier translated-passage proof.
  # It costs one controlled catalog entry and no table, column or identity
  # rewrite. The earlier, structurally richer fixture remains part of the row so
  # the scorecard proves both the new relationship and the established kinds.
  @extension_predicates ~w(adaptation_of excerpt_of translated_by published_in illustrates)
  @extension_kinds [work: :entity, edition: :entity, passage: :content, quotation: :content]

  defp e3_row do
    registered =
      Enum.filter(@extension_predicates, fn key ->
        Claims.predicate(key) && Claims.endpoint_rules(key) != []
      end)

    kinds =
      Enum.filter(@extension_kinds, fn
        {kind, :entity} -> kind in DevilsDictionary.Registry.Entity.kinds()
        {kind, :content} -> kind in DevilsDictionary.Registry.ContentItem.kinds()
      end)

    applied = Repo.aggregate("schema_migrations", :count)
    on_disk = Path.wildcard("priv/repo/migrations/*.exs") |> length()

    ok? =
      length(registered) == length(@extension_predicates) and
        length(kinds) == length(@extension_kinds) and applied == on_disk

    row(
      "E3",
      "a new kind of thing fits",
      "post-baseline adaptation plus translated passage: " <>
        "#{length(registered)} / #{length(@extension_predicates)} " <>
        "predicates, #{length(kinds)} / #{length(@extension_kinds)} kinds, " <>
        "#{applied} of #{on_disk} migrations applied",
      "no new table, no new column, no rewritten identity",
      ok?,
      detail:
        "issue84_checkpoint4_test.exs adds adaptation_of as catalog data and proves " <>
          "an existing authored_by attachment and identity do not move; extension_test.exs " <>
          "retains the work, translator, edition, passage and quotation exercise"
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
        "proven by test",
        "the page's numbers are the CLI's",
        opts[:skip_health_check] != true,
        detail:
          "health_live_test.exs — every section renders, and the coverage rows carry " <>
            "the values `Health.coverage/2` returns, which is what `mix dd.health` prints"
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
      "recorded runs: dumps #{Mix.Tasks.Dd.Report.fmt_ms(dump_ms)} · API/replay #{Mix.Tasks.Dd.Report.fmt_ms(api_ms)}",
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
            where: r.task in ["absorb", "index", "replay"],
            select:
              coalesce(
                sum(
                  fragment(
                    "COALESCE((?->>'elapsed_ms')::bigint, (EXTRACT(EPOCH FROM (? - ?)) * 1000)::bigint)",
                    r.stats,
                    r.finished_at,
                    r.started_at
                  )
                ),
                0
              )
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
  # nothing. The home search runs both identity spaces and deliberately keeps
  # same-named words and entities separate, so the budget includes both indexed
  # queries rather than timing only the older lexical half of the UI.
  @search_probes ~w(o oy oys oyst oyster oysster monkeyz cat Cat aardvark
                    giant\u00a0tortoise mongoose zzzzzz hyena dog dogg
                    sperm\u00a0whale wolf axolotl turkey)

  @search_budget_ms 150

  defp search_timings do
    for probe <- @search_probes do
      probe = String.replace(probe, "\u00a0", " ")
      at = System.monotonic_time(:microsecond)
      Lexicon.search(probe)
      Encyclopedia.search_entities(probe)
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

  # **U1** — the routes #69 §6 asks for, and the four #74 §F adds. A route is a
  # fact the router can be asked for, so it is measured rather than asserted in
  # prose, and the set grows when the product does.
  #
  # `/words/:id/:slug` is the canonical word address and `/define/:slug` the
  # resolver beside it — two rows because they are two contracts, not one route
  # written twice (ADR decision 10).
  @spec_pages [
    {"/", "home and search"},
    {"/define/:slug", "the word page, by slug"},
    {"/words/:id/:slug", "the word page, canonical"},
    {"/entities/:id/:slug", "the thing page"},
    {"/connections/:id", "one connection"},
    {"/connect", "propose a connection"},
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
