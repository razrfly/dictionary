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
    test "drops exactly the four declared keys" do
      assert Wiktionary.trimmed_keys() ==
               ~w(translations descendants etymology_templates head_templates)

      for record <- all_records() do
        trimmed = Wiktionary.trim(record)

        for key <- Wiktionary.trimmed_keys() do
          refute Map.has_key?(trimmed, key)
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

  test "materialize/1 says plainly that it lands in S1" do
    assert_raise RuntimeError, ~r/S1/, fn ->
      Wiktionary.materialize(Fixtures.source_record(%{}))
    end
  end
end
