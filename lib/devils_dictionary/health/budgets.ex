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

  Warm cache, stated: a cold-cache figure measures the disk, and every page a
  reader sees is served warm.
  """

  import Ecto.Query

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
      measure(words, fn slug -> slug |> Lexicon.lookup() |> WordPage.build() end)
      |> Map.merge(%{
        measured: true,
        budget_ms: @page_budget_ms,
        population: "the #{length(words)} words with the most senses and relations",
        probes: words
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

  # Warm, and said so. A cold-cache figure measures the disk; every page a
  # reader sees is served warm, and the budget is about the reader.
  defp measure(subjects, fun) do
    for subject <- Enum.take(subjects, @warmup), do: fun.(subject)

    timings =
      for subject <- subjects do
        {microseconds, _} = :timer.tc(fn -> fun.(subject) end)
        microseconds / 1_000
      end

    sorted = Enum.sort(timings)

    %{
      runs: length(timings),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      max: sorted |> List.last() |> round_ms()
    }
  end

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    index = min(round(p * length(sorted)), length(sorted) - 1)
    sorted |> Enum.at(max(index, 0)) |> round_ms()
  end

  defp round_ms(value), do: Float.round(value, 3)

  # ── populations ───────────────────────────────────────────────────────────

  # The words with the most to compose: senses first, because a card is a
  # sense group and the placement rule runs per sense. Falls back to any
  # enriched word on a small database, so the row measures something rather
  # than reporting nothing.
  defp busiest_words(sample) do
    Repo.all(
      from s in "senses",
        join: l in "lexemes",
        on: l.object_id == s.lexeme_id,
        group_by: l.slug,
        order_by: [desc: count(s.object_id)],
        limit: ^sample,
        select: l.slug
    )
  end

  defp busiest_objects(sample) do
    Repo.all(
      from r in "assertion_revisions",
        where: r.is_current,
        group_by: r.object_object_id,
        order_by: [desc: count(r.id)],
        limit: ^sample,
        select: r.object_object_id
    )
  end

  defp top_degree do
    Repo.one(
      from r in "assertion_revisions",
        where: r.is_current,
        group_by: r.object_object_id,
        order_by: [desc: count(r.id)],
        limit: 1,
        select: count(r.id)
    ) || 0
  end
end
