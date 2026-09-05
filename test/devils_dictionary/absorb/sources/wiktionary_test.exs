defmodule DevilsDictionary.Absorb.Sources.WiktionaryTest do
  @moduledoc """
  `trim/1` and the index projection are pure, so they are tested directly
  against real captured records. The fixtures are untrimmed on purpose: M4
  measures the saving against them.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Wiktionary
  alias DevilsDictionary.Fixtures

  @lemmas ~w(cat dog oyster)

  defp records(lemma), do: Fixtures.raw("wiktionary", lemma)
  defp all_records, do: Enum.flat_map(@lemmas, &records/1)

  defp bytes(term), do: term |> Jason.encode!() |> byte_size()

  describe "trim/1 (scorecard M4)" do
    test "drops exactly the declared top-level keys" do
      assert Wiktionary.trimmed_keys() ==
               ~w(translations descendants etymology_templates head_templates
                  hyphenations wikipedia)

      for record <- all_records() do
        trimmed = Wiktionary.trim(record)

        for key <- Wiktionary.trimmed_keys() do
          refute Map.has_key?(trimmed, key)
        end
      end
    end

    test "narrows categories to the topical ones, entry- and sense-level" do
      record = "cat" |> records() |> hd()
      trimmed = Wiktionary.trim(record)

      assert "English 3-letter words" in record["categories"]
      refute "English 3-letter words" in trimmed["categories"]
      assert "en:Felids" in trimmed["categories"]

      sense_categories = Enum.flat_map(trimmed["senses"], &(&1["categories"] || []))
      assert Enum.all?(sense_categories, &String.starts_with?(&1, "en:"))

      # What survives has to be exactly what `categories/1` would have read.
      assert Wiktionary.categories(trimmed) == Wiktionary.categories(record)
    end

    test "drops the sense fields nothing renders" do
      trimmed = "cat" |> records() |> hd() |> Wiktionary.trim()

      for sense <- trimmed["senses"] do
        refute Map.has_key?(sense, "links")

        for example <- sense["examples"] || [] do
          assert Map.keys(example) -- ~w(text ref type) == []
        end
      end
    end

    test "keeps every key it does not explicitly drop" do
      for record <- all_records() do
        kept = record |> Map.keys() |> Enum.reject(&(&1 in Wiktionary.trimmed_keys()))
        trimmed = Wiktionary.trim(record)

        assert Enum.sort(Map.keys(trimmed)) == Enum.sort(kept)
      end
    end

    test "is idempotent — trimming a trimmed record changes nothing" do
      for record <- all_records() do
        trimmed = Wiktionary.trim(record)
        assert Wiktionary.trim(trimmed) == trimmed
      end
    end

    test "loses nothing the index pass materializes" do
      for record <- all_records() do
        trimmed = Wiktionary.trim(record)

        assert Wiktionary.index_row(trimmed, 1) == Wiktionary.index_row(record, 1)
      end
    end

    test "saves at least half the payload" do
      raw_bytes = all_records() |> Enum.map(&bytes/1) |> Enum.sum()
      trimmed_bytes = all_records() |> Enum.map(&bytes(Wiktionary.trim(&1))) |> Enum.sum()

      saving = 1 - trimmed_bytes / raw_bytes

      assert saving >= 0.5,
             "M4 wants >= 50% smaller, got #{Float.round(saving * 100, 1)}% " <>
               "(#{raw_bytes} -> #{trimmed_bytes} bytes)"
    end
  end

  describe "index_row/1" do
    test "keys the row on lemma and part of speech" do
      row = records("cat") |> hd() |> Wiktionary.index_row(3)

      assert row.lang == "en"
      assert row.lemma == "cat"
      assert row.pos in ~w(noun verb adj adv name)
      assert row.slug == "cat"
      assert row.origin_source_id == 3
      assert row.source_ids == [3]
    end

    test "carries inflected forms, which is how /define/cats resolves" do
      forms =
        records("cat")
        |> Enum.flat_map(&Wiktionary.index_row(&1, 1).forms)
        |> Enum.map(& &1["form"])

      assert "cats" in forms
      assert Enum.all?(forms, &is_binary/1)
    end

    test "form entries keep only form and tags" do
      for record <- all_records(), form <- Wiktionary.index_row(record, 1).forms do
        assert Enum.sort(Map.keys(form)) -- ["form", "tags"] == []
      end
    end

    test "a bare index row is bare: no senses, no enrichment" do
      row = records("oyster") |> hd() |> Wiktionary.index_row(1)

      refute Map.has_key?(row, :enriched_at)
      assert row.pronunciations == []
      assert row.etymology == nil
    end
  end

  describe "categories/1" do
    test "keeps only the en:-prefixed topical categories" do
      cats = records("oyster") |> Enum.flat_map(&Wiktionary.categories/1) |> Enum.uniq()

      assert cats != []
      assert Enum.all?(cats, &String.starts_with?(&1, "en:"))
      refute Enum.any?(cats, &String.contains?(&1, "English countable nouns"))
    end

    test "reads sense-level categories as well as entry-level ones" do
      record = records("cat") |> Enum.find(&(&1["pos"] == "noun"))
      sense_cats = Enum.flat_map(record["senses"] || [], &(&1["categories"] || []))
      en_sense_cats = Enum.filter(sense_cats, &String.starts_with?(&1, "en:"))

      if en_sense_cats != [] do
        assert Enum.all?(en_sense_cats, &(&1 in Wiktionary.categories(record)))
      end
    end

    test "categories land in the metadata the scope rule queries" do
      row = records("cat") |> Enum.find(&(&1["pos"] == "noun")) |> Wiktionary.index_row(1)

      assert is_list(row.metadata["wikt_categories"])
    end
  end

  describe "form_of?/1" do
    test "headwords are not form-of entries" do
      for lemma <- @lemmas, record <- records(lemma), record["pos"] == "noun" do
        refute Wiktionary.form_of?(record), "#{lemma} noun should be a headword"
      end
    end

    test "detects an inflected form" do
      record = %{
        "word" => "cats",
        "senses" => [%{"form_of" => [%{"word" => "cat"}], "tags" => ["form-of", "plural"]}]
      }

      assert Wiktionary.form_of?(record)
    end
  end

  describe "materialize/1" do
    test "a record becomes one lexeme, its senses and its relations" do
      [noun | _] = out = materialize("cat")

      assert noun.lexemes == [hd(noun.lexemes)]
      assert hd(noun.lexemes).key == {"en", "cat", "noun"}
      assert hd(noun.lexemes).etymology =~ "Old English"
      assert hd(noun.lexemes).etymology_source_id == 2

      assert Enum.all?(out, &(&1.entries == []))
      assert Enum.all?(out, &(&1.concepts == []))
      assert Enum.all?(out, &(&1.links == []))
    end

    test "a word with several etymologies keeps one lexeme per (lemma, pos)" do
      keys = "cat" |> materialize() |> Enum.map(&hd(&1.lexemes).key) |> Enum.uniq()

      assert {"en", "cat", "noun"} in keys
      assert {"en", "cat", "verb"} in keys
      assert {"en", "cat", "adj"} in keys
    end

    test "external ids carry the etymology number, senses hang off them" do
      raw = "cat" |> records() |> hd()

      assert Wiktionary.external_id(raw) == "cat/noun/1"

      [%{senses: [first | _]} | _] = materialize("cat")
      assert first.key == "cat/noun/1#0"
    end

    test "the gloss is the most specific one Kaikki nested" do
      [%{senses: [first | _]} | _] = materialize("cat")

      # Kaikki nests ["Terms relating to animals.", "A mammal of the family Felidae."]
      assert first.gloss == "A mammal of the family Felidae."
      assert "Terms relating to animals." in first.metadata["raw_glosses"]
    end

    test "senses keep tags, topics and examples, and drop offset noise" do
      senses = senses("cat")

      assert Enum.any?(senses, &("countable" in (&1.tags || [])))

      example =
        senses
        |> Enum.flat_map(& &1.examples)
        |> Enum.find(&(&1["ref"] != nil))

      assert example["text"] =~ "cat"
      assert Map.keys(example) -- ["text", "ref", "type"] == []
    end

    test "every sense links back (scorecard A9)" do
      for lemma <- @lemmas, sense <- senses(lemma) do
        assert sense.url == "https://en.wiktionary.org/wiki/#{lemma}#English"
      end
    end

    test "sense-carried Wikidata QIDs survive for S2's linker" do
      qids = senses("cat") |> Enum.flat_map(&(&1.metadata["wikidata"] || []))

      assert "Q146" in qids
    end

    test "pronunciations come from sounds, respellings and rhymes do not" do
      prons = "cat" |> materialize() |> hd() |> then(&hd(&1.lexemes).pronunciations)

      assert Enum.any?(prons, &(&1["ipa"] == "/ˈkæt/"))
      assert Enum.any?(prons, &(&1["mp3_url"] != nil))
      assert Enum.all?(prons, &(&1["source"] == "wiktionary"))
      # "kăt" is an enpr respelling with no ipa and no audio.
      refute Enum.any?(prons, &(&1["enpr"] != nil))
    end

    test "entry- and sense-level linkages both become relations" do
      relations = relations("cat")
      types = relations |> Enum.map(& &1.type) |> Enum.uniq()

      assert :hypernym in types
      assert :hyponym in types
      assert :synonym in types
      assert :derived in types

      assert Enum.any?(relations, &is_nil(&1.from_sense)), "expected entry-level relations"
      assert Enum.any?(relations, &(&1.from_sense != nil)), "expected sense-level relations"
      assert Enum.all?(relations, &(&1.from_lexeme == {"en", "cat", elem(&1.from_lexeme, 2)}))
    end

    test "form_of and alt_of senses become the edges dd.resolve reads" do
      types = "oyster" |> relations() |> Enum.map(& &1.type)

      assert :alt_of in types
    end

    test "a dirty target is cleaned, and what was dropped is kept" do
      # The real dump lists this synonym of `cat` as "panther[Panthera".
      dirty = Enum.find(relations("cat"), &(&1.metadata["raw"] == "panther[Panthera"))

      assert dirty.to_lemma == "panther"
    end

    test "clean_target/1 handles markup, qualifiers and namespaces" do
      assert Wiktionary.clean_target("[[monkey]]") == "monkey"
      assert Wiktionary.clean_target("[[Felis|cat]]") == "cat"
      assert Wiktionary.clean_target("panther[Panthera") == "panther"
      assert Wiktionary.clean_target("  spacious  ") == "spacious"
      assert Wiktionary.clean_target("Thesaurus:cat") == nil
      assert Wiktionary.clean_target("[") == nil
      assert Wiktionary.clean_target("") == nil
      assert Wiktionary.clean_target(nil) == nil
    end

    test "a thesaurus page listing the headword as its own synonym is skipped" do
      # `cat`'s Thesaurus:cat synonym list contains "cat".
      refute Enum.any?(relations("cat"), &(&1.type == :synonym and &1.to_lemma == "cat"))
    end

    test "no relation carries an empty target" do
      for lemma <- @lemmas, relation <- relations(lemma) do
        assert is_binary(relation.to_lemma) and relation.to_lemma != ""
      end
    end

    test "trimming loses nothing materialized (scorecard M4)" do
      for lemma <- @lemmas, raw <- records(lemma) do
        assert one(raw) == one(Wiktionary.trim(raw))
      end
    end
  end

  defp one(raw) do
    {:ok, out} = Wiktionary.materialize(Fixtures.source_record(raw, source_id: 2, id: 99))
    out
  end

  defp materialize(lemma), do: lemma |> records() |> Enum.map(&one/1)
  defp senses(lemma), do: lemma |> materialize() |> Enum.flat_map(& &1.senses)
  defp relations(lemma), do: lemma |> materialize() |> Enum.flat_map(& &1.relations)
end
