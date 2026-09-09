defmodule DevilsDictionary.HealthPagesTest do
  @moduledoc """
  The five scorecard rows the word page answers — **X1**, **U2**, **U3**, **U6**
  and **R3** — measured on fixtures rather than on the development database, so the
  numbers `mix dd.score` prints have a test that says what they mean.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  import Ecto.Query

  alias DevilsDictionary.{Fixtures, Health, Lexicon, Repo}

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

      # Sense to sense: WordNet's chain walks `group_key` to `group_key`.
      relation!(ctx, word, :hypernym, animal,
        source: "wordnet",
        from_sense: sense,
        to_sense: animal_sense
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

    test "the thing panel's two link-outs are in the population, counted apart", ctx do
      flagships!(ctx)
      cards_only = Health.cards_link_out()

      cat = Lexicon.get_lexeme("en", "cat", "noun")
      concept = concept!("Q146", "cat", wikipedia_title: "Cat")
      link!(cat, concept, confidence: 0.95)

      result = Health.cards_link_out()

      assert result.cards == cards_only.cards
      assert result.things == 2
      assert result.total == result.cards + 2
      assert result.passed == result.total
    end

    test "a word that names nothing adds no thing-panel probe to fail", ctx do
      flagships!(ctx)

      assert Health.cards_link_out().things == 0
    end
  end

  describe "U3 — provenance everywhere" do
    test "every card opens a record, and every citation carries one", ctx do
      flagships!(ctx)

      result = Health.cards_provenance()

      assert result.total > 0
      assert result.passed == result.total
      assert result.probes == []
      assert result.cited == result.citations
      assert result.citations >= result.total
      assert result.words == 6
    end

    test "a card whose records have been deleted fails the row", ctx do
      flagships!(ctx)
      cat = Lexicon.get_lexeme("en", "cat", "noun")
      sense!(ctx, cat, "wiktionary", gloss: "A second sense, unrecorded.", record: nil)

      # A card's citations reach the record through the revision each sense
      # cites, so deleting the records is what makes the drawer come up empty.
      Repo.delete_all(
        from r in DevilsDictionary.Sources.SourceRecord,
          where:
            r.id in subquery(
              from s in DevilsDictionary.Registry.Sense,
                join: rev in DevilsDictionary.Registry.SenseRevision,
                on: rev.sense_id == s.object_id,
                join: srr in DevilsDictionary.Corpus.SourceRecordRevision,
                on: srr.id == rev.source_record_revision_id,
                where: s.lexeme_id == ^cat.object_id,
                select: srr.source_record_id
            )
      )

      result = Health.cards_provenance()

      assert result.passed < result.total
      assert "card-wiktionary" in Enum.map(result.probes, & &1.card)
      assert result.cited < result.citations
    end

    test "the thing panel is reported beside the cards, never graded", ctx do
      flagships!(ctx)
      cat = Lexicon.get_lexeme("en", "cat", "noun")
      concept = concept!("Q146", "cat", wikipedia_title: "Cat")
      link!(cat, concept, confidence: 0.95)

      # No `source_records` row exists for Q146 in this fixture, so the panel
      # reports 0 of 1 — and the graded figure is untouched by it.
      result = Health.cards_provenance()

      assert result.things == %{passed: 0, total: 1}
      assert result.passed == result.total
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

      animal_sense =
        sense!(ctx, animal, "wordnet", group_key: "oewn-animal-n", gloss: "a living thing")

      for lemma <- ~w(cat dog) do
        word = word!(ctx, lemma, ~w(wordnet))
        sense = sense!(ctx, word, "wordnet", group_key: "oewn-#{lemma}-n", gloss: "the animal")

        relation!(ctx, word, :hypernym, animal,
          source: "wordnet",
          from_sense: sense,
          to_sense: animal_sense
        )
      end

      result = Health.chains()

      assert result.passed == 0
      assert Enum.all?(result.probes, &("animal" in &1.chain and &1.broader == []))
    end
  end
end
