defmodule DevilsDictionary.Quotations.Badge do
  @moduledoc """
  The four-way provenance badge and the #65 score, from what is known about a
  line (#158 build 5). Pure: findings in, a verdict out.

  A **finding** is `%{source, kind, role}` plus whatever explains it:

    * `kind: :cited` — a source cites the line to its author (a provider's
      claim, or the author's own Wikiquote page listing it under a cited work)
    * `kind: :primary` — the line is in a text Wikidata says the author wrote
    * `kind: :register` — a register files the line as misattributed,
      disputed or unsourced; `role: :contradicts`, and `note` is the
      register's sentence when it gives one

  ## The badge, by agreements (#158's rule)

    * **verified** — at least two *independent* sources agree (distinct
      `source` among cited and primary findings), one of them a primary text,
      and nothing contradicts
    * **plausible** — a cited claim and nothing against it
    * **disputed** — something contradicts, and a cited claim exists: another
      source cites it, or the register itself says who did say it
    * **apocryphal** — something contradicts and nobody cites the line at all

  A line with no finding of any kind has no badge (`nil`): the verifier has
  nothing to say about it, and the provider's own label stands.

  ## The score, by #65's signal table

  Primary source +0.40, fact-check site +0.25, a cited aggregator +0.15, an
  author record with dates +0.10, a known misattribution −0.30, no source title
  or year −0.10, clamped to [0, 1]. Recorded beside the badge and landed as the
  claim's `confidence`; the badge is decided by the agreements, not by #65's
  score thresholds, because #158 made "two independent agreements" the rule for
  *Verified* after #65 was written. Where the two disagree the record says so.
  """

  @version 1

  @doc "The rule's version, recorded with every verdict."
  def version, do: @version

  @doc """
  `%{badge, score, agreements, sources}` for a line's findings.

  `opts[:author_dated?]` — the credited person has birth or death dates on
  record (#65's author signal).
  """
  def compute(findings, opts \\ []) when is_list(findings) do
    supports = Enum.filter(findings, &(&1.kind in [:cited, :primary]))
    contradicts = Enum.filter(findings, &(&1.role == :contradicts))

    sources = supports |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
    primary? = Enum.any?(supports, &(&1.kind == :primary))
    # A register that names who did say it is a cited claim in its own right.
    cited? =
      supports != [] or Enum.any?(contradicts, &(is_binary(&1[:note]) and &1[:note] != ""))

    badge =
      cond do
        findings == [] -> nil
        contradicts != [] and cited? -> "disputed"
        contradicts != [] -> "apocryphal"
        length(sources) >= 2 and primary? -> "verified"
        cited? -> "plausible"
        true -> nil
      end

    %{
      badge: badge,
      score: score(findings, opts),
      agreements: length(sources),
      sources: sources,
      version: @version
    }
  end

  defp score([], _opts), do: nil

  defp score(findings, opts) do
    signals = [
      {Enum.any?(findings, &(&1.kind == :primary)), 0.40},
      {Enum.any?(findings, &(&1[:fact_check] == true)), 0.25},
      {Enum.any?(findings, &(&1.kind == :cited)), 0.15},
      {opts[:author_dated?] == true, 0.10},
      {Enum.any?(findings, &(&1.role == :contradicts)), -0.30},
      {not Enum.any?(findings, &(&1.kind == :cited and (&1[:work] || &1[:year]))), -0.10}
    ]

    signals
    |> Enum.reduce(0.0, fn {on?, points}, acc -> if on?, do: acc + points, else: acc end)
    |> max(0.0)
    |> min(1.0)
    |> Float.round(2)
  end
end
