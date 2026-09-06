defmodule DevilsDictionary.HealthPagesTest do
  @moduledoc """
  The four scorecard rows the word page answers — **X1**, **U2**, **U6** and
  **R3** — measured on fixtures rather than on the development database, so the
  numbers `mix dd.score` prints have a test that says what they mean.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Fixtures, Health}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  # cat, dog and oyster as the scorecard needs them: four cards across two
  # tiers, a WordNet chain reaching `animal`, and Wiktionary broader chips.
  defp flagships!(ctx) do
    animal = word!(ctx, "animal", ~w(wordnet))

    animal_sense =
      sense!(ctx, animal, "wordnet", group_key: "oewn-animal-n", gloss: "a living thing")

    for lemma <- ~w(cat dog oyster) do
      word = word!(ctx, lemma, ~w(bierce johnson wiktionary wordnet))
      entry!(ctx, word, "bierce", body: "A #{lemma}.")
      entry!(ctx, word, "johnson", body: "A #{lemma}, in 1755.")
      sense!(ctx, word, "wiktionary", gloss: "A #{lemma}.")
      sense = sense!(ctx, word, "wordnet", group_key: "oewn-#{lemma}-n", gloss: "the animal")

      relation!(ctx, word, :hypernym, animal,
        source: "wordnet",
        from_sense: sense,
        to_group_key: "oewn-animal-n"
      )

      # Wiktionary's broader edge hangs off the part of speech, not the sense.
      relation!(ctx, word, :hypernym, animal, source: "wiktionary")
    end

    animal_sense
  end

  describe "X1 — every word has a page" do
    test "a sample of bare index rows all render", ctx do
      for i <- 1..30, do: word!(ctx, "bareword#{i}", [], enriched_at: nil)

      result = Health.word_pages(20)

      assert result.total == 20
      assert result.passed == 20
      assert Enum.all?(result.probes, & &1.ok)
    end

    test "an empty index reports nothing rather than dividing by zero", _ctx do
      assert %{total: 0, passed: 0} = Health.word_pages(20)
    end
  end

  describe "U2 — the flagship words" do
    test "each has four cards across two tiers", ctx do
      flagships!(ctx)

      result = Health.flagships()

      assert result.passed == 3
      assert result.total == 3

      for probe <- result.probes do
        assert probe.cards >= 4, "#{probe.input} has only #{probe.cards} cards"
        assert probe.tiers >= 2
      end
    end

    test "a word with one tier fails the row rather than passing on card count", ctx do
      # Four Wiktionary cards, one tier: the row is about spread, not volume.
      for pos <- ~w(noun verb adj adv) do
        word = word!(ctx, "cat", ~w(wiktionary), pos: pos)
        sense!(ctx, word, "wiktionary", gloss: "A cat, as a #{pos}.")
      end

      probe = Enum.find(Health.flagships().probes, &(&1.input == "cat"))

      assert probe.cards == 4
      assert probe.tiers == 1
      refute probe.ok
    end
  end

  describe "U6 — every card links out" do
    test "every card resolves a target", ctx do
      flagships!(ctx)

      result = Health.cards_link_out()

      assert result.total > 0
      assert result.passed == result.total
      assert result.probes == []
    end
  end

  describe "R3 — chains render" do
    test "cat and dog reach animal by WordNet and are broadened by Wiktionary", ctx do
      flagships!(ctx)

      result = Health.chains()

      assert result.passed == 2
      assert result.total == 2

      for probe <- result.probes do
        assert "animal" in probe.chain
        assert "animal" in probe.broader
      end
    end

    test "a WordNet chain alone is not two sources", ctx do
      animal = word!(ctx, "animal", ~w(wordnet))
      sense!(ctx, animal, "wordnet", group_key: "oewn-animal-n", gloss: "a living thing")

      for lemma <- ~w(cat dog) do
        word = word!(ctx, lemma, ~w(wordnet))
        sense = sense!(ctx, word, "wordnet", group_key: "oewn-#{lemma}-n", gloss: "the animal")

        relation!(ctx, word, :hypernym, animal,
          source: "wordnet",
          from_sense: sense,
          to_group_key: "oewn-animal-n"
        )
      end

      result = Health.chains()

      assert result.passed == 0
      assert Enum.all?(result.probes, &("animal" in &1.chain and &1.broader == []))
    end
  end
end
