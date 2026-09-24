defmodule DevilsDictionary.Quotations.BadgeTest do
  @moduledoc "#158 build 5's badge rule and #65's score, on findings alone."
  use ExUnit.Case, async: true

  alias DevilsDictionary.Quotations.Badge

  defp cited(source, extra \\ %{}),
    do: Map.merge(%{source: source, kind: :cited, role: :supports, work: "A work"}, extra)

  defp primary, do: %{source: "gutenberg", kind: :primary, role: :supports}
  defp register(note), do: %{source: "wikiquote", kind: :register, role: :contradicts, note: note}

  test "verified: two independent sources, one a primary text, nothing against" do
    assert %{badge: "verified", agreements: 2} = Badge.compute([cited("wikiquote"), primary()])
  end

  test "two cited claims and no primary text are plausible, never verified" do
    assert %{badge: "plausible", agreements: 2} =
             Badge.compute([cited("wikiquote"), cited("wiktionary")])
  end

  test "a primary text alone is one source, not two" do
    assert %{badge: "plausible", agreements: 1} = Badge.compute([primary()])
  end

  test "the same source twice is one agreement" do
    assert %{badge: "plausible", agreements: 1} =
             Badge.compute([cited("wikiquote"), cited("wikiquote")])
  end

  test "a register that names who did say it disputes; one that names nobody is apocryphal" do
    assert %{badge: "disputed"} = Badge.compute([register("Evelyn Beatrice Hall (1906)")])
    assert %{badge: "apocryphal"} = Badge.compute([register(nil)])
  end

  test "a contradiction outranks any agreement" do
    assert %{badge: "disputed"} = Badge.compute([cited("wikiquote"), primary(), register(nil)])
  end

  test "nothing known, nothing said" do
    assert %{badge: nil, score: nil} = Badge.compute([])
  end

  test "the #65 score, from its own signal table" do
    # primary 0.40 + cited aggregator 0.15 + author with dates 0.10
    assert Badge.compute([cited("wikiquote"), primary()], author_dated?: true).score == 0.65
    # cited 0.15, no title or year −0.10
    assert Badge.compute([cited("wikiquote", %{work: nil})]).score == 0.05
    # a known misattribution −0.30, no citation −0.10, clamped at zero
    assert Badge.compute([register(nil)]).score == 0.0
  end
end
