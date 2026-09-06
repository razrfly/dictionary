defmodule DevilsDictionary.Absorb.Sources.JohnsonTest do
  @moduledoc """
  Segmentation on a hand-built snippet, then `materialize/1` on the real
  fixtures as a pure function.

  The snippet carries the shapes that decide whether Johnson lands on the index
  or beside it: the stress apostrophe, the soft hyphen that joins a word broken
  across a printed line, the `To ` verb marker, alternate headwords, a
  comma-separated prose gloss that is *not* an alternate, numbered senses,
  quotations, and a homograph.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Johnson
  alias DevilsDictionary.Fixtures

  # Line endings are the file's own CRLF, and the soft hyphens are real U+00AD:
  # both are load-bearing, and a snippet that quietly normalised them would test
  # a document we do not have.
  @snippet """
  <root><leme no="1345">
  <wordentry type="h"><form lang="en">CAT. <class type="pos">n. s.</class></form>\
   <xpln lang="en"><etym lang="tbd">[katz, Teuton. <term lang="fr">chat,</term> Fr.]</etym>\
   A domestick animal that\r\ncatches mice, commonly reckoned by naturalists the lowest or­\r\nder\
   of the leonine species.\r\n<term lang="quo">Thrice the brinded cat hath mew'd.\
   Shakesp. Macbeth.</term></xpln></wordentry>
  <wordentry type="h"><form lang="en">CAT. <class type="pos">n. s.</class></form>\
   <xpln lang="en">A sort of ship.</xpln></wordentry>
  <wordentry type="h"><form lang="en">A’BBEY, or ABBY. <class type="pos">n. s.</class></form>\
   <xpln lang="en">A monastery of religious persons.</xpln></wordentry>
  <wordentry type="h"><form lang="en">To ABI’DE.  I abode or abid. <class type="pos">v. n.</class></form>\
   <xpln lang="en">1. To dwell in a place.\r\n2. To remain.\r\n<term lang="quo">Let him abide. Hooker.</term></xpln></wordentry>
  <wordentry type="h"><form lang="en">METHO’UGHT, the preterite of methinks.</form>\
   <xpln lang="en">It seemed to me. See METHINKS.</xpln></wordentry>
  </root>
  """

  defp entries, do: Johnson.segment(@snippet)

  describe "segment/1" do
    test "finds every wordentry and keeps the document order" do
      assert length(entries()) == 5
      assert Enum.map(entries(), & &1.position) == [0, 1, 2, 3, 4]
    end

    test "counts the homograph, because only the whole document can" do
      [cat, ship | _] = entries()

      assert cat.headword == "CAT"
      assert cat.occurrence == 0
      assert ship.headword == "CAT"
      assert ship.occurrence == 1

      # Which is what keeps them apart in `source_records`.
      refute Johnson.external_id(cat.headword, cat.pos, cat.occurrence) ==
               Johnson.external_id(ship.headword, ship.pos, ship.occurrence)
    end

    test "separates the printed part of speech from the headword" do
      assert Enum.map(entries(), & &1.pos) == ["n. s.", "n. s.", "n. s.", "v. n.", nil]
      refute Enum.any?(entries(), &String.contains?(&1.headword, "n. s."))
    end

    test "keeps the printed headword beside the parsed one" do
      abbey = Enum.at(entries(), 2)

      assert abbey.printed_headword == "A’BBEY, or ABBY."
      assert abbey.headword == "A’BBEY"
      assert abbey.alt_headwords == ["ABBY"]
    end

    test "stores the explanation as its own markup, not as flattened text" do
      [cat | _] = entries()

      assert cat.xpln =~ ~s|<xpln lang="en">|
      assert cat.xpln =~ ~s|<term lang="quo">|
      assert cat.xpln =~ "</xpln>"
      refute cat.xpln =~ "<wordentry"
    end
  end

  describe "split_headword/1" do
    test "the apostrophe is a stress mark and the entry keeps it" do
      assert Johnson.split_headword("ABA’CKE.") == {["ABA’CKE"], false}
      assert Johnson.lemma("ABA’CKE") == "abacke"
      assert Johnson.lemma("ABA'CKE") == "abacke"
    end

    test "a leading To is the verb marker of the period, not part of the word" do
      assert Johnson.split_headword("To ABA’NDON.") == {["ABA’NDON"], true}
    end

    test "alternates are separated by a comma, an or, or an and" do
      assert Johnson.split_headword("A’BBEY, or ABBY.") == {["A’BBEY", "ABBY"], false}
      assert Johnson.split_headword("A, B, C.") == {["A", "B", "C"], false}
      assert Johnson.split_headword("AC, AK, or AKE.") == {["AC", "AK", "AKE"], false}
    end

    test "a part that is not upper case is prose about the word, not another name" do
      # The comma is Johnson explaining himself. Splitting on it naively puts
      # "the preterite of methinks" in the lexicon as a word.
      assert Johnson.split_headword("METHO’UGHT, the preterite of methinks.") ==
               {["METHO’UGHT"], false}

      assert Johnson.split_headword("To BEGI’N. I began, or begun; I have begun.") ==
               {["BEGI’N"], true}
    end

    test "the headword ends where the printed grammar note begins, period or not" do
      assert Johnson.split_headword("To ABI’DE.  I abode or abid.") == {["ABI’DE"], true}

      # No full stop after the headword at all — the only signal is the case.
      assert Johnson.split_headword("To SINK pret I sunk, anciently sank; part. sunk.") ==
               {["SINK"], true}
    end

    test "a run of single-letter abbreviations is the headword" do
      assert Johnson.split_headword("A. Bp.") == {["A. Bp."], false}

      assert Johnson.split_headword("F. R. S. Fellow of the Royal Society.") ==
               {["F. R. S."], false}

      # But a single one is not: the lower-case gloss ends it.
      assert Johnson.split_headword("I. pronoun personal.") == {["I"], false}
    end

    test "a headword with no upper case at all is kept as printed" do
      assert Johnson.split_headword("An ABRI’DGER.") == {["An ABRI’DGER"], false}
    end
  end

  describe "pos/1" do
    test "maps the head of the distribution" do
      assert Johnson.pos("n. s.") == "noun"
      assert Johnson.pos("adj.") == "adj"
      assert Johnson.pos("v. a.") == "verb"
      assert Johnson.pos("v. n.") == "verb"
      assert Johnson.pos("adv.") == "adv"
      assert Johnson.pos("interject.") == "intj"
    end

    test "reads a marker out of the long tail rather than guessing" do
      assert Johnson.pos("n. s. It has no singular.") == "noun"
      assert Johnson.pos("tree. n. s.") == "noun"
      assert Johnson.pos("participial adj.") == "adj"
    end

    test "an absent or unreadable marker is unknown, never a guess" do
      assert Johnson.pos(nil) == "unknown"
      assert Johnson.pos("something else entirely") == "unknown"
    end

    test "every mapped marker resolves to a part of speech the lexicon uses" do
      for marker <- Johnson.pos_markers() do
        assert Johnson.pos(marker) in ~w(noun verb adj adv prep pron conj intj)
      end
    end
  end

  describe "materialize/1" do
    # A lemma is several records — Johnson defines `CAT` four times, twice as a
    # phrase — so the fixture is picked by its printed headword rather than by
    # position, which would silently drift when the fixture is recaptured.
    defp materialize(fixture, printed) do
      raws = Fixtures.raw("johnson", fixture)

      raw = Enum.find(raws, &(&1["printed_headword"] == printed))

      refute is_nil(raw), "no #{fixture} fixture printed as #{inspect(printed)}"

      record =
        Fixtures.source_record(raw,
          external_id: raw["headword"],
          url: "https://leme.library.utoronto.ca/lexicons/1345/"
        )

      {:ok, out} = Johnson.materialize(record)
      out
    end

    test "cat is the definition #69 quotes, with its printed line breaks healed" do
      out = materialize("cat", "CAT.")
      [entry] = out.entries

      assert entry.headword == "CAT"
      assert entry.lexeme == {"en", "cat", "noun"}
      assert entry.author == "samuel-johnson"
      assert entry.year == 1755
      assert entry.body_format == :markdown

      assert entry.body =~
               "A domestick animal that catches mice, commonly reckoned by " <>
                 "naturalists the lowest order of the leonine species."

      # `or­\r\nder` really is one word.
      refute entry.body =~ "or­der"
      refute entry.body =~ "­"
    end

    test "the etymology is metadata, not body" do
      out = materialize("cat", "CAT.")
      [entry] = out.entries

      assert entry.metadata["etymology"] =~ "katz, Teuton."
      refute entry.body =~ "katz"
    end

    test "quotations are blockquotes, in order, with Johnson's own citation" do
      out = materialize("cat", "CAT.")
      [entry] = out.entries

      assert entry.metadata["quotations"] >= 3
      assert entry.body =~ "> Thrice the brinded cat hath mew'd. Shakesp. Macbeth."
    end

    test "numbered senses open their own paragraph" do
      out = materialize("dog", "DOG.")
      [entry] = out.entries

      assert entry.body =~ "1. A domestick animal remarkably various in his species"
      assert entry.body =~ "\n\n2. A constellation called Sirius"
      assert entry.body =~ "\n\n3. A reproachful name for a man."
    end

    test "an alternate headword becomes a lexeme and an alt_of relation" do
      out = materialize("abbey", "A'BBEY, or ABBY.")

      assert {"en", "abbey", "noun"} in Enum.map(out.lexemes, & &1.key)
      assert {"en", "abby", "noun"} in Enum.map(out.lexemes, & &1.key)

      assert [%{type: :alt_of, to_lemma: "abbey"} = relation] =
               Enum.filter(out.relations, &(&1.type == :alt_of))

      assert relation.from_lexeme == {"en", "abby", "noun"}
    end

    test "See HEADWORD becomes an unresolved see_also, for dd.resolve to fill" do
      out = materialize("methought", "METHO’UGHT, the preterite of methinks.")

      assert [relation] = Enum.filter(out.relations, &(&1.type == :see_also))
      assert relation.to_lemma == "methinks"
      assert relation.from_lexeme == {"en", "methought", "unknown"}
      # Unresolved on purpose: `mix dd.resolve` owns the other end (#69 §4).
      refute Map.has_key?(relation, :to_lexeme_id)
    end

    test "an inflected entry names its base word, so the word page redirects" do
      # "METHO’UGHT, the preterite of methinks" and "GEESE. The plural of
      # goose." — 115 entries where Johnson says which word this is a form of.
      # Without the edge, `geese` keeps its own page and X3 fails.
      out = materialize("methought", "METHO’UGHT, the preterite of methinks.")

      assert [%{to_lemma: "methinks", from_lexeme: {"en", "methought", _}}] =
               Enum.filter(out.relations, &(&1.type == :form_of))
    end

    test "the printed marker survives even where the mapping loses it" do
      out = materialize("cat", "CAT.")
      [entry] = out.entries

      assert entry.pos == "n. s."
      assert entry.metadata["pos_marker"] == "n. s."
      assert entry.metadata["printed_headword"] == "CAT."
    end

    test "the ten-way homograph keeps ten separate entries" do
      raws = Fixtures.raw("johnson", "a")

      assert length(raws) >= 10
      assert Enum.map(raws, & &1["headword"]) |> Enum.uniq() == ["A"]
      assert Enum.map(raws, & &1["occurrence"]) |> Enum.uniq() |> length() > 1
    end

    test "a printed grammar note does not become part of the verb" do
      out = materialize("abide", "To ABI'DE. I abode or abid.")
      [entry] = out.entries

      assert entry.lexeme == {"en", "abide", "verb"}
      assert entry.metadata["printed_headword"] == "To ABI'DE. I abode or abid."
      refute Enum.any?(out.lexemes, &(elem(&1.key, 1) =~ "abode"))
    end

    test "a record with no raw yields nothing rather than a half-built entry" do
      assert Johnson.materialize(%DevilsDictionary.Sources.SourceRecord{raw: %{}}) == {:ok, %{}}
    end
  end

  describe "trim/1" do
    test "is the identity: a public-domain dictionary is imported whole" do
      raw = Fixtures.one_raw("johnson", "cat")
      assert Johnson.trim(raw) == raw
    end
  end
end
