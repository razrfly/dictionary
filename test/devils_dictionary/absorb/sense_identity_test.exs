defmodule DevilsDictionary.Absorb.SenseIdentityTest do
  @moduledoc """
  The policy that ends the position-key defect, and the claim its moduledoc
  makes about how it scores.

  `SenseIdentity.similarity/2` says it is a faithful reimplementation of
  `pg_trgm`'s. That is worth having as a pure function — the whole absorb path
  is unit-testable offline (row O3), and it is one query per batch rather than
  one per incoming sense — and it is worth *checking*, because "faithful" is
  otherwise an intention.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.SenseIdentity
  alias DevilsDictionary.Repo

  # Real glosses, plus the pairs the Gate 0 spike scored: byte-identical text,
  # a rewording, a genuinely different meaning, and two that are too close to
  # tell apart.
  @pairs [
    {"Money; profit.", "Money; profit."},
    {"Money; profit.", "Money, or profit."},
    {"A branch office of such an institution.", "Money; profit."},
    {"A domesticated carnivorous mammal.", "A small domesticated carnivorous mammal."},
    {"An edge of a river.", "The edge of a river."},
    {"", "Money; profit."},
    {"A slimy, gobby shellfish", "A bivalve testaceous fish"},
    {"one", "two"}
  ]

  describe "similarity/2 against the database's own pg_trgm" do
    test "agrees on every pair, which is what makes it safe to score in Elixir" do
      for {a, b} <- @pairs do
        ours = SenseIdentity.similarity(a, b)
        theirs = postgres_similarity(a, b)

        assert_in_delta ours, theirs, 0.0001, """
        similarity(#{inspect(a)}, #{inspect(b)})
          ours:     #{ours}
          pg_trgm:  #{theirs}
        """
      end
    end

    test "identical text is 1.0 and unrelated text is far below the threshold" do
      assert SenseIdentity.similarity("Money; profit.", "Money; profit.") == 1.0

      assert SenseIdentity.similarity(
               "A branch office of such an institution.",
               "Money; profit."
             ) < SenseIdentity.strong()
    end
  end

  describe "decide/2 — the three outcomes" do
    test "byte-identical input keeps every identity and writes no case" do
      existing = [
        held(1, "Money; profit."),
        held(2, "A branch office of such an institution.")
      ]

      incoming = [
        incoming("bank/noun/1#0", "A branch office of such an institution."),
        incoming("bank/noun/1#1", "Money; profit.")
      ]

      assert [{:matched, 2, 1.0}, {:matched, 1, 1.0}] = SenseIdentity.decide(incoming, existing)
    end

    test "a meaning that moved position keeps its identity, and the new one is new" do
      # The audit's reproduction: delete a sense from position 1 and everything
      # after it shifts down. "Money; profit." moves and must keep its id.
      existing = [held(20_000_005, "Money; profit."), held(20_000_006, "A river bank.")]

      incoming = [
        # Same text, new position — the position is not part of the decision.
        incoming("bank/noun/1#4", "Money; profit."),
        incoming("bank/noun/1#5", "A place where blood is stored for transfusion.")
      ]

      assert [{:matched, 20_000_005, score}, {:new, nil}] =
               SenseIdentity.decide(incoming, existing)

      assert score == 1.0
    end

    test "two candidates too close to choose between open a case, not a guess" do
      # Gate 0 measured 0.897 with a 0.000 gap, where picking the higher would
      # have been decided by the row id.
      existing = [held(1, "An edge of a river."), held(2, "An edge of a river.")]
      incoming = [incoming("k", "An edge of a river.")]

      assert [{:ambiguous, candidates, :too_close}] = SenseIdentity.decide(incoming, existing)
      assert length(candidates) == 2
    end

    test "a different etymology is a different word, never a rewording" do
      # Wiktionary's four `bank` etymologies are four words spelled alike, and a
      # gloss from one is never a rewording of a gloss from another — so an
      # identical string across etymologies is `new`, not `matched`.
      existing = [held(1, "An edge of a river.", %{"etymology_number" => 1})]
      incoming = [incoming("k", "An edge of a river.", %{"etymology_number" => 2})]

      assert [{:new, nil}] = SenseIdentity.decide(incoming, existing)
    end

    test "one old meaning cannot become two new ones" do
      existing = [held(1, "Money; profit.")]

      incoming = [
        incoming("a", "Money; profit."),
        incoming("b", "Money; profit.")
      ]

      # The first claims it; the second cannot also be it, and is ambiguous or
      # new rather than silently sharing an identity.
      assert [{:matched, 1, _}, second] = SenseIdentity.decide(incoming, existing)
      refute match?({:matched, 1, _}, second)
    end
  end

  describe "decide/3 — a source whose keys are stable" do
    # The defect the first full WordNet re-import found. Two synsets share the
    # lemma *sequoia* and their glosses differ by two words, so content matching
    # collapsed them into one identity — and then flip-flopped its gloss on
    # every pass, one revision each way, for ever.
    @tree "either of two huge coniferous California trees that reach a height of 300 feet"
    @wood "wood of either of two huge coniferous California trees that reach a height of 300 feet"

    test "two different keys stay two meanings, however alike they read" do
      assert SenseIdentity.similarity(@tree, @wood) > SenseIdentity.strong()

      existing = [held(1, @wood, %{}, "oewn-84481488-n#sequoia")]
      incoming = [incoming("oewn-89665091-n#sequoia", @tree)]

      assert [{:matched, 1, _}] = SenseIdentity.decide(incoming, existing)
      assert [{:new, nil}] = SenseIdentity.decide(incoming, existing, :stable)
    end

    test "the same key is the same meaning even when the gloss was rewritten" do
      existing = [held(7, "an old wording", %{}, "oewn-84481488-n#sequoia")]
      incoming = [incoming("oewn-84481488-n#sequoia", "a completely unrelated wording")]

      assert [{:new, nil}] = SenseIdentity.decide(incoming, existing)
      assert [{:matched, 7, 1.0}] = SenseIdentity.decide(incoming, existing, :stable)
    end

    test "nothing is ever ambiguous, so no case opens and no id is guessed" do
      existing = [held(1, @tree, %{}, "a"), held(2, @wood, %{}, "b")]
      incoming = [incoming("c", @tree), incoming("a", @wood)]

      assert [{:new, nil}, {:matched, 1, 1.0}] =
               SenseIdentity.decide(incoming, existing, :stable)
    end
  end

  defp postgres_similarity(a, b) do
    %{rows: [[score]]} = Repo.query!("SELECT similarity($1, $2)::float8", [a, b])
    score
  end

  defp held(id, gloss, metadata \\ %{}, external_key \\ nil),
    do: %{
      object_id: id,
      external_key: external_key || "held-#{id}",
      gloss: gloss,
      metadata: metadata
    }

  defp incoming(key, gloss, metadata \\ %{}),
    do: %{key: key, gloss: gloss, metadata: metadata}
end
