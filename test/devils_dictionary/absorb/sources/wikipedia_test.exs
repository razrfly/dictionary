defmodule DevilsDictionary.Absorb.Sources.WikipediaTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Wikipedia
  alias DevilsDictionary.Fixtures

  @lemmas ~w(cat dog oyster seal)

  defp record(lemma), do: Fixtures.one_raw("wikipedia", lemma)

  defp out(lemma, attrs \\ []) do
    raw = record(lemma)

    {:ok, out} =
      raw
      |> Wikipedia.trim()
      |> Fixtures.source_record(Keyword.merge([source_id: 4, id: 99], attrs))
      |> Wikipedia.materialize()

    out
  end

  describe "trim/1" do
    test "keeps only the declared keys" do
      for lemma <- @lemmas do
        trimmed = Wikipedia.trim(record(lemma))
        assert Enum.sort(Map.keys(trimmed)) -- Wikipedia.kept_keys() == []
      end
    end

    test "drops the revision and rendering chaff the Action API adds" do
      trimmed = Wikipedia.trim(record("cat"))

      for key <- ~w(lastrevid touched contentmodel editurl pagelanguage length) do
        refute Map.has_key?(trimmed, key)
      end
    end

    test "loses nothing materialized" do
      for lemma <- @lemmas do
        raw = record(lemma)
        full = Fixtures.source_record(raw, source_id: 4, id: 99)
        lean = Fixtures.source_record(Wikipedia.trim(raw), source_id: 4, id: 99)

        assert Wikipedia.materialize(full) == Wikipedia.materialize(lean)
      end
    end
  end

  describe "materialize/1" do
    test "an article becomes a concept and one entry" do
      out = out("cat")

      assert [concept] = out.concepts
      assert concept.qid == "Q146"
      assert concept.wikipedia_title == "Cat"
      assert concept.wikipedia_pageid == 6678
      assert concept.description == "Small domesticated carnivorous mammal"

      assert [entry] = out.entries
      assert entry.concept == "Q146"
      assert entry.headword == "Cat"
      assert entry.body =~ "domesticated"
      assert entry.position == 0
      assert entry.url == "https://en.wikipedia.org/wiki/Cat"
    end

    test "the probe's lexeme keys carry the title, and only those keys" do
      out = out("cat")

      assert Enum.sort(Enum.map(out.lexemes, & &1.key)) == [
               {"en", "cat", "adj"},
               {"en", "cat", "noun"},
               {"en", "cat", "verb"}
             ]

      for lexeme <- out.lexemes do
        assert lexeme.metadata["wikipedia_title"] == "Cat"
        refute Map.has_key?(lexeme.metadata, "wikipedia_disambiguation")
      end
    end

    test "the utm tracking parameters never reach the database" do
      assert [%{image_url: url}] = out("cat").concepts
      assert url =~ "upload.wikimedia.org"
      refute url =~ "utm_"
    end

    test "a disambiguation page is flagged, keeps its candidates, and gets no entry" do
      out = out("seal")

      assert Enum.all?(out.lexemes, & &1.metadata["wikipedia_disambiguation"])

      # No entry: "Seal may refer to…" is not an encyclopedia article, and
      # rendering it as a source card would be a definition we never made.
      assert out.entries == []

      qids = Enum.map(out.concepts, & &1.qid)
      assert "Q257102" in qids
      assert length(qids) > 10

      candidate = Enum.find(out.concepts, &(&1.qid == "Q114414285"))
      assert candidate.metadata["from_disambiguation"] == "Seal"
    end

    test "an absent marker materializes to nothing at all" do
      record = Fixtures.source_record(%{}, source_id: 4, id: 99)
      assert {:ok, out} = Wikipedia.materialize(record)
      assert out == %{}
    end
  end

  describe "the behaviour" do
    test "slug and rate limit" do
      assert Wikipedia.slug() == "wikipedia"
      assert Wikipedia.rate_limit_ms() >= 200
    end
  end
end
