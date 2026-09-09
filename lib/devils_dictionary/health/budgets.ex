defmodule DevilsDictionary.Health.Budgets do
  @moduledoc """
  Scorecard rows **P1** (page composition) and **P2** (bounded traversal), the
  two #74 leaves as measurements rather than assertions.

  Gate 0 agreed the numbers, on the whole resolved corpus rather than a sample:

  | Budget | Value | Basis |
  |---|---|---|
  | bounded incoming/outgoing read p95 | < 5 ms | measured 0.256 / 0.489 ms; ~10× headroom |
  | single-assertion write p95 | < 10 ms | measured 0.904 ms at 8 clients |
  | full word-page composition p95 | < 150 ms | **pending at P0** — it needed the ported `WordPage` |

  That last row is the one this module exists for. #74 is explicit that it is
  "pending, not guessed", and that it needs the real builder against a matched
  population — a budget measured on ten fixtures is a budget for ten fixtures.

  ## How it measures

  The **highest-degree** nodes, not random ones. A page budget met on the median
  word is met on nothing that matters: `cat` and `human` are the pages that fall
  over, and the 1,768-degree lexeme is the traversal that does. So the sample is
  drawn from the top of the degree distribution and the p95 is reported beside
  the population it was drawn from — which is what makes the number comparable
  across a rebuild, and what the audit meant by "with their actual populations
  and measurement definitions".

  Warm cache, stated: cold-cache behavior is not covered by these measurements.
  """

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Repo

  @sample 20
  @warmup 3

  @page_budget_ms 150
  @traversal_budget_ms 5

  @doc "The agreed budgets, in milliseconds."
  def budgets, do: %{page: @page_budget_ms, traversal: @traversal_budget_ms}

  @doc """
  **P1** — full word-page composition on the highest-degree words.

  `WordPage.build/2` end to end: the cards, the placement rule, the chain, the
  thing panel and the trail. Not a query — the page.
  """
  def page_composition(sample \\ @sample) do
    words = busiest_words(sample)

    if words == [] do
      %{measured: false, reason: "no enriched words to measure"}
    else
      word_result =
        measure(words, fn id ->
          word = Lexicon.by_object_id(id)
          WordPage.build(%{lexemes: [word], via: :lemma, matched: word.lemma})
        end)

      entities =
        Repo.query!(
          """
          WITH degrees AS (
            SELECT object_object_id id,count(*) n FROM assertion_revisions WHERE is_current GROUP BY object_object_id
            UNION ALL
            SELECT subject_object_id id,count(*) n FROM assertion_revisions WHERE is_current GROUP BY subject_object_id
          ) SELECT e.object_id FROM entities e JOIN degrees d ON d.id=e.object_id
          GROUP BY e.object_id ORDER BY sum(d.n) DESC,e.object_id LIMIT $1
          """,
          [sample],
          timeout: :infinity
        ).rows
        |> Enum.map(&hd/1)

      entity_result = measure(entities, &DevilsDictionary.Encyclopedia.EntityPage.build/1)

      Map.merge(word_result, %{
        measured: true,
        p95: max(word_result.p95, entity_result.p95),
        word_p95: word_result.p95,
        entity_p95: entity_result.p95,
        max: max(word_result.max, entity_result.max),
        runs: word_result.runs + entity_result.runs,
        budget_ms: @page_budget_ms,
        population:
          "#{length(words)} high-degree words and #{length(entities)} high-degree entities; 3 warmups and 5 rounds per page",
        probes: %{words: words, entities: entities}
      })
    end
  end

  @doc """
  **P2** — bounded incoming and outgoing reads on the highest-degree object.

  Both directions, because a claim read from one end and not the other is the
  defect the whole model is arranged against, and both are what the page pays.
  """
  def bounded_traversal(sample \\ @sample) do
    ids = busiest_objects(sample)

    if ids == [] do
      %{measured: false, reason: "no assertions to traverse"}
    else
      outgoing = measure(ids, &Claims.outgoing/1)
      incoming = measure(ids, &Claims.incoming/1)

      %{
        measured: true,
        budget_ms: @traversal_budget_ms,
        outgoing_p95: outgoing.p95,
        incoming_p95: incoming.p95,
        p95: max(outgoing.p95, incoming.p95),
        max: max(outgoing.max, incoming.max),
        runs: outgoing.runs + incoming.runs,
        population: "the #{length(ids)} objects with the most current assertions",
        top_degree: top_degree()
      }
    end
  end

  # ── measurement ───────────────────────────────────────────────────────────

  # Warm, and said so. A cold-cache figure measures the disk; this is explicitly a warm-cache budget, not a cold-start claim.
  defp measure(subjects, fun) do
    for _ <- 1..@warmup, subject <- subjects, do: fun.(subject)

    timings =
      for _ <- 1..5, subject <- subjects do
        {microseconds, _} = :timer.tc(fn -> fun.(subject) end)
        microseconds / 1_000
      end

    sorted = Enum.sort(timings)

    %{
      runs: length(timings),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      max: round_ms(List.last(sorted) || 0.0)
    }
  end

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    index = min(ceil(p * length(sorted)) - 1, length(sorted) - 1)
    sorted |> Enum.at(max(index, 0)) |> round_ms()
  end

  defp round_ms(value), do: Float.round(value, 3)

  # ── populations ───────────────────────────────────────────────────────────

  # The words with the most to compose: senses first, because a card is a
  # sense group and the placement rule runs per sense. Falls back to any
  # enriched word on a small database, so the row measures something rather
  # than reporting nothing.
  defp busiest_words(sample) do
    Repo.query!(
      """
      WITH counts AS (
        SELECT s.lexeme_id AS id, count(*) AS n FROM senses s GROUP BY s.lexeme_id
        UNION ALL
        SELECT coalesce(s.lexeme_id, l.object_id), count(*) FROM assertion_revisions r
          LEFT JOIN senses s ON s.object_id = r.subject_object_id
          LEFT JOIN lexemes l ON l.object_id = r.subject_object_id
          WHERE r.is_current AND coalesce(s.lexeme_id, l.object_id) IS NOT NULL
          GROUP BY coalesce(s.lexeme_id, l.object_id)
      ) SELECT id FROM counts GROUP BY id ORDER BY sum(n) DESC, id LIMIT $1
      """,
      [sample],
      timeout: :infinity
    ).rows
    |> Enum.map(&hd/1)
  end

  defp busiest_objects(sample) do
    Repo.query!(
      """
        (SELECT subject_object_id FROM assertion_revisions WHERE is_current
         GROUP BY subject_object_id ORDER BY count(*) DESC, subject_object_id LIMIT $1)
        UNION
        (SELECT object_object_id FROM assertion_revisions WHERE is_current
         GROUP BY object_object_id ORDER BY count(*) DESC, object_object_id LIMIT $1)
      """,
      [sample],
      timeout: :infinity
    ).rows
    |> Enum.map(&hd/1)
    |> Enum.sort()
  end

  defp top_degree do
    Repo.query!(
      """
        SELECT max(n) FROM (
          SELECT count(*) n FROM assertion_revisions WHERE is_current GROUP BY subject_object_id
          UNION ALL
          SELECT count(*) n FROM assertion_revisions WHERE is_current GROUP BY object_object_id
        ) degrees
      """,
      [],
      timeout: :infinity
    ).rows
    |> hd()
    |> hd() || 0
  end
end
