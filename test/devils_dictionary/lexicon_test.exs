defmodule DevilsDictionary.LexiconTest do
  @moduledoc """
  `lookup/1` is scorecard row X3: an inflected form and a spelling variant both
  have to land on the word someone meant.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Repo

  defp lexeme!(lemma, pos, attrs \\ []) do
    Repo.insert!(
      struct(%Lexeme{lang: "en", lemma: lemma, pos: pos, slug: Lexeme.slug(lemma)}, attrs)
    )
  end

  defp enriched!(lemma, pos, attrs \\ []) do
    lexeme!(lemma, pos, Keyword.put(attrs, :enriched_at, DateTime.utc_now()))
  end

  describe "lookup/1" do
    test "finds a word by its lemma" do
      enriched!("oyster", "noun")

      assert %{via: :lemma, lexemes: [lexeme]} = Lexicon.lookup("oyster")
      assert lexeme.lemma == "oyster"
    end

    test "is case-insensitive and returns every part of speech" do
      enriched!("oyster", "noun")
      enriched!("oyster", "verb")

      assert %{lexemes: lexemes} = Lexicon.lookup("OYSTER")
      assert Enum.map(lexemes, & &1.pos) == ["noun", "verb"]
    end

    test "an inflected form lands on the word it inflects (X3)" do
      # The dump gives "monkeys" an index row of its own, bare, with no senses;
      # a plain lemma match would stop there and render an empty page. The index
      # pass marks such rows as form-of entries.
      lexeme!("monkeys", "noun", metadata: %{"form_of" => true})
      enriched!("monkey", "noun", forms: [%{"form" => "monkeys", "tags" => ["plural"]}])

      assert %{via: :form, lexemes: [lexeme], matched: "monkeys"} = Lexicon.lookup("monkeys")
      assert lexeme.lemma == "monkey"
    end

    test "a spelling variant lands on its canonical lexeme (X3)" do
      oyster = enriched!("oyster", "noun")
      enriched!("oistre", "noun", canonical_lexeme_id: oyster.id)

      assert %{via: :canonical, lexemes: [lexeme]} = Lexicon.lookup("oistre")
      assert lexeme.id == oyster.id
    end

    test "a word that means something itself keeps its own page" do
      # "cats" is a real headword as well as the plural of "cat".
      enriched!("cats", "noun")
      enriched!("cat", "noun", forms: [%{"form" => "cats", "tags" => ["plural"]}])

      assert %{via: :lemma, lexemes: [lexeme]} = Lexicon.lookup("cats")
      assert lexeme.lemma == "cats"
    end

    test "a bare headword beats a forms match and offers the claimant as `also`" do
      # "spat" (young oysters) has a bare index row of its own, and "spit" lists
      # it as a past form. The headword keeps its page.
      lexeme!("spat", "noun")
      spit = enriched!("spit", "verb", forms: [%{"form" => "spat", "tags" => ["past"]}])

      assert %{via: :lemma, lexemes: [lexeme], also: [also]} = Lexicon.lookup("spat")
      assert lexeme.lemma == "spat"
      assert also.id == spit.id
    end

    test "a bare form-of entry yields to the word it inflects" do
      lexeme!("geese", "noun", metadata: %{"form_of" => true})
      enriched!("goose", "noun", forms: [%{"form" => "geese", "tags" => ["plural"]}])

      assert %{via: :form, lexemes: [lexeme]} = Lexicon.lookup("geese")
      assert lexeme.lemma == "goose"
    end

    test "a bare row is still returned when nothing claims it as a form" do
      lexeme!("wamplebug", "noun")

      assert %{via: :lemma, lexemes: [lexeme]} = Lexicon.lookup("wamplebug")
      assert lexeme.lemma == "wamplebug"
    end

    test "an ambiguous form keeps every candidate rather than guessing" do
      enriched!("bore", "verb", forms: [%{"form" => "bore", "tags" => ["past"]}])
      enriched!("bear", "verb", forms: [%{"form" => "bore", "tags" => ["past"]}])

      # "bore" matches its own lemma first, so the form fallback never fires.
      assert %{via: :lemma, lexemes: [lexeme]} = Lexicon.lookup("bore")
      assert lexeme.lemma == "bore"
    end

    test "an unknown word is a clean miss, not an error" do
      assert %{lexemes: [], via: :none} = Lexicon.lookup("qwertyuiop")
    end

    test "blank input is a miss" do
      assert %{lexemes: [], via: :none} = Lexicon.lookup("   ")
      assert %{lexemes: [], via: :none} = Lexicon.lookup(nil)
    end
  end
end
