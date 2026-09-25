defmodule DevilsDictionary.Discovery.PageEvidenceTest do
  @moduledoc """
  The two tiers of #172 build B: a sense's `refers_to` first and alone, the
  word's corroborated candidate only when there is none, every entry saying
  which, and never the two in one recipe (C2).
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Discovery.PageEvidence

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    %{sources: catalog.sources, scopes: catalog.scopes}
  end

  defp candidate!(word, qid, label, confidence),
    do: link!(word, concept!(qid, label), method: :title_match, confidence: confidence)

  describe "entities/2" do
    test "a sense's refers_to is tier 1, marked sense", ctx do
      war = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, war, "wordnet")
      link!(war, concept!("Q198", "war"), sense: sense, confidence: 0.95)

      assert [%{"qid" => "Q198", "level" => "sense", "label" => "war"}] =
               PageEvidence.entities([war.object_id])

      assert PageEvidence.any?([war.object_id])
    end

    test "with no sense link, a corroborated candidate is tier 2, marked word", ctx do
      grief = word!(ctx, "grief", ~w(wordnet))
      sense!(ctx, grief, "wordnet")
      candidate!(grief, "Q1026040", "grief", 0.85)

      assert [%{"qid" => "Q1026040", "level" => "word"}] =
               PageEvidence.entities([grief.object_id])

      assert PageEvidence.any?([grief.object_id])
    end

    test "a candidate below the corroborated floor is no identity at all", ctx do
      love = word!(ctx, "love", ~w(wordnet))
      candidate!(love, "Q316", "love", 0.7)
      candidate!(love, "Q30311", "Love (disambiguation guess)", 0.6)

      assert PageEvidence.entities([love.object_id]) == []
      refute PageEvidence.any?([love.object_id])
    end

    test "a sense link keeps every candidate out, however confident (C2)", ctx do
      war = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, war, "wordnet")
      link!(war, concept!("Q198", "war"), sense: sense, confidence: 0.85)
      candidate!(war, "Q8465", "civil war", 0.9)

      entities = PageEvidence.entities([war.object_id])

      assert Enum.map(entities, & &1["qid"]) == ["Q198"]
      assert Enum.all?(entities, &(&1["level"] == "sense"))
    end
  end

  describe "the recipe" do
    test "the level is part of the digest when it is word, and only then" do
      sense = [%{"qid" => "Q316", "level" => "sense"}]
      word = [%{"qid" => "Q316", "level" => "word"}]
      before_the_level = [%{"qid" => "Q316"}]

      # A promotion keeps the QID and changes the recipe.
      refute PageEvidence.digest(word) == PageEvidence.digest(sense)

      # A sense-backed recipe digests as it did before the level existed, so
      # no existing mapping is re-versioned by it.
      assert PageEvidence.digest(sense) == PageEvidence.digest(before_the_level)
    end

    test "a recipe is one level, a known one" do
      assert PageEvidence.valid_entities?([%{"qid" => "Q1", "level" => "word"}])

      assert PageEvidence.valid_entities?([
               %{"qid" => "Q1"},
               %{"qid" => "Q2", "level" => "sense"}
             ])

      refute PageEvidence.valid_entities?([
               %{"qid" => "Q1", "level" => "sense"},
               %{"qid" => "Q2", "level" => "word"}
             ])

      refute PageEvidence.valid_entities?([%{"qid" => "Q1", "level" => "lexeme"}])
    end

    test "labelled/2 puts the level on every result, and the class and word on a word-level one" do
      page =
        {:ok, %{items: [%{match_details: %{"kind" => "sitelink", "evidence" => "identity"}}]}}

      assert {:ok, %{items: [%{match_details: word}]}} =
               PageEvidence.labelled(page, %{
                 "term" => "grief",
                 "entities" => [%{"qid" => "Q1026040", "level" => "word"}]
               })

      assert word == %{
               "kind" => "sitelink",
               "evidence" => "word_identity",
               "level" => "word",
               "query" => "grief"
             }

      assert {:ok, %{items: [%{match_details: sense}]}} =
               PageEvidence.labelled(page, %{
                 "term" => "war",
                 "entities" => [%{"qid" => "Q198", "level" => "sense"}]
               })

      assert sense == %{"kind" => "sitelink", "evidence" => "identity", "level" => "sense"}

      # Anything but a page is handed back unchanged.
      assert PageEvidence.labelled({:deferred, "x", 5}, %{}) == {:deferred, "x", 5}
    end
  end
end
