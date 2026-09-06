defmodule DevilsDictionary.Absorb.Sources.BierceTest do
  @moduledoc """
  Segmentation on a hand-built snippet, then `materialize/1` on the real
  fixtures as a pure function.

  The snippet carries every shape that made the old Rails parser wrong: verse in
  a `<pre>`, an attribution under it, a definition that resumes lowercase after
  its verse, a stub whose whole body is the verse, an entry the HTML wraps in a
  `<pre>`, alternate headwords, and a chapter boundary.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Bierce
  alias DevilsDictionary.Fixtures

  # Two chapters, so the letter-essay rule and the chapter boundary are both
  # exercised. Whitespace is hard-wrapped exactly as Gutenberg wraps it.
  @snippet """
  <div class="chapter">
      <h2><a id="link2H_4_0002"></a>
        A
      </h2>
      <p>
        ABASEMENT, n. A decent and customary mental attitude in the presence of
        wealth or power.
      </p>
      <p>
        ABDICATION, n. An act whereby a sovereign attests his sense of the high
        temperature of the throne.
      </p>
  <pre>
    Poor Isabella's dead, whose abdication
    Set all tongues wagging in the Spanish nation.
  </pre>
      <p>
        G.J.
      </p>
      <p>
        ABRACADABRA.
      </p>
  <pre>
    By <i>Abracadabra</i> we signify
        An infinite number of things.
  </pre>
      <p>
        ACADEMY, n. [from ACADEME] A modern school where football is taught.
      </p>
      <p>
        BABE or BABY, n. A misshapen creature of no particular age, sex, or
        condition.
      </p>
      <p>
        BRUTE, n. See HUSBAND.
      </p>
      <p>
        MONUMENT, n. A structure intended to commemorate something which either
        needs no commemoration or cannot be commemorated.
      </p>
  <pre>
    The bones of Agammemnon are a show,
    And ruined is his royal monument,
  </pre>
      <p>
        but Agammemnon's fame suffers no diminution in consequence. The monument
        custom has its <i>reductiones ad absurdum</i> in monuments "to the unknown
        dead".
      </p>
  <pre>
  EUCHARIST, n.  A sacred feast of the religious sect of Theophagi.
    A dispute once unhappily arose among the members of this sect.
  </pre>
      <p>
        HABEAS CORPUS. A writ by which a man may be taken out of jail when
        confined for the wrong crime.
      </p>
      <p>
        HASH, x. There is no definition for this word&mdash;nobody knows what hash is.
      </p>
      <p>
        LL.D. Letters indicating the degree <i>Legumptionorum Doctor</i>, one
        learned in laws.
      </p>
      <p>
        PIE, n. An advance agent of the reaper whose name is Indigestion.
      </p>
  <pre>
    Cold pie is a detestable
    American comestible.
  </pre>
      <p>
        W.J. Candleton
      </p>
  </div><!--end chapter-->

  <div class="chapter">
      <h2><a id="link2H_4_0026"></a>
        X
      </h2>
      <p>
        X in our alphabet being a needless letter has an added invincibility to
        the attacks of the spelling reformers.
      </p>
  </div><!--end chapter-->
  """

  defp entries, do: Bierce.segment(@snippet)

  defp entry(headword) do
    Enum.find(entries(), &(&1.headword == headword)) ||
      flunk("no entry for #{headword}; got #{inspect(Enum.map(entries(), & &1.headword))}")
  end

  defp kinds(entry), do: Enum.map(entry.blocks, &elem(&1, 0))

  describe "segment/1" do
    test "one entry per headword, in document order" do
      assert Enum.map(entries(), & &1.headword) == [
               "ABASEMENT",
               "ABDICATION",
               "ABRACADABRA",
               "ACADEMY",
               "BABE",
               "BRUTE",
               "MONUMENT",
               "EUCHARIST",
               "HABEAS CORPUS",
               "HASH",
               "LL.D",
               "PIE",
               "X"
             ]
    end

    test "verse belongs to the entry above it, and so does its attribution" do
      assert kinds(entry("ABDICATION")) == [:headword, :verse, :attribution]
    end

    test "a stub's whole definition is the verse under it" do
      # `ABRACADABRA.` has no part of speech and no prose. A rule that needs
      # text after the marker loses 21 entries this way.
      assert entry("ABRACADABRA").pos == nil
      assert kinds(entry("ABRACADABRA")) == [:headword, :verse]
    end

    test "a definition interrupted by verse resumes as a continuation" do
      # The paragraph after MONUMENT's verse starts "but Agammemnon's fame…".
      # Short and capitalised would have made it an attribution; it is neither.
      assert kinds(entry("MONUMENT")) == [:headword, :verse, :continuation]
    end

    test "a <pre> that opens with a headword is an entry, not verse" do
      # The HTML mis-wraps EUCHARIST. Every other <pre> in the book is verse.
      assert entry("EUCHARIST").pos == "n"
      assert kinds(entry("EUCHARIST")) == [:headword]
    end

    test "alternate headwords attach to the first" do
      assert entry("BABE").alt_headwords == ["BABY"]
    end

    test "a headword with no part of speech still opens an entry" do
      assert entry("HABEAS CORPUS").pos == nil
    end

    test "initials under verse are an attribution, not a headword" do
      # `W.J. Candleton` has exactly the shape of `LL.D. Letters indicating…`:
      # capitals, a stop, more text. What separates them is that only one of
      # them is a sentence, so both must land on the right side of the line.
      refute Enum.any?(entries(), &String.starts_with?(&1.headword, "W.J"))
      assert kinds(entry("PIE")) == [:headword, :verse, :attribution]
      # …and the entry with the same shape stays an entry.
      assert entry("LL.D").pos == nil
    end

    test "a chapter's first block opens an entry, so a letter essay is one" do
      # Chapter X is only this paragraph. Without the rule it glues itself to
      # the last entry of chapter W.
      assert entry("X").pos == nil
      assert entry("X").letter == "X"
    end

    test "each entry carries its chapter letter and anchor" do
      assert entry("ABASEMENT").letter == "A"
      assert entry("ABASEMENT").anchor == "link2H_4_0002"
      assert entry("X").anchor == "link2H_4_0026"
    end

    test "the preface is not a chapter of the dictionary" do
      preface = """
      <div class="chapter">
          <h2><a id="link2H_4_0001"></a>
            AUTHOR'S PREFACE
          </h2>
          <p>
            THE DEVIL'S DICTIONARY was begun in a weekly paper in 1881.
          </p>
      </div>
      """

      assert Bierce.segment(preface) == []
    end
  end

  describe "split_alternates/1" do
    test "the three shapes Bierce actually uses" do
      assert Bierce.split_alternates("BABE or BABY") == {"BABE", ["BABY"]}
      assert Bierce.split_alternates("CONFIDANT, CONFIDANTE") == {"CONFIDANT", ["CONFIDANTE"]}
      assert Bierce.split_alternates("TZETZE (or TSETSE) FLY") == {"TZETZE FLY", ["TSETSE FLY"]}
      assert Bierce.split_alternates("ABASEMENT") == {"ABASEMENT", []}
    end
  end

  describe "headword_prefix/1" do
    test "the printed phrase, alternates and all" do
      assert Bierce.headword_prefix("ABASEMENT, n. A decent and customary mental attitude.") ==
               {:ok, "ABASEMENT, n."}

      # The three alternate shapes. The whole printed phrase is the headword, so
      # the whole printed phrase comes off the body — this is what left `BABE`
      # reading "or BABY, n. A misshapen…" when the prefix was rebuilt from the
      # `headword` column, which knows only the first of the two.
      assert Bierce.headword_prefix("BABE or BABY, n. A misshapen creature.") ==
               {:ok, "BABE or BABY, n."}

      assert Bierce.headword_prefix("CONFIDANT, CONFIDANTE, n. One entrusted by A.") ==
               {:ok, "CONFIDANT, CONFIDANTE, n."}

      assert Bierce.headword_prefix("TZETZE (or TSETSE) FLY, n. An African insect.") ==
               {:ok, "TZETZE (or TSETSE) FLY, n."}
    end

    test "the marker's own oddities" do
      # The 1911 typo, the joke marker, a compound marker, and no marker at all.
      assert Bierce.headword_prefix("IMPOSTOR n. A rival aspirant to public honors.") ==
               {:ok, "IMPOSTOR n."}

      assert Bierce.headword_prefix("HASH, x. There is no definition for this word.") ==
               {:ok, "HASH, x."}

      assert Bierce.headword_prefix("REASON, v.i. To weigh probabilities.") ==
               {:ok, "REASON, v.i."}

      assert Bierce.headword_prefix("HABEAS CORPUS. A writ by which a man may be taken.") ==
               {:ok, "HABEAS CORPUS. "}

      assert Bierce.headword_prefix("ABRACADABRA.") == {:ok, "ABRACADABRA."}
    end

    test "a letter essay has no headword phrase" do
      # The letter is the first word of a sentence, not a printed headword. A
      # bare-headword fallback stripped it and left "is the first letter…".
      assert Bierce.headword_prefix("I is the first letter of the alphabet.") == :no
      assert Bierce.headword_prefix("W (double U) has the only cumbrous name.") == :no
      assert Bierce.headword_prefix("X in our alphabet being a needless letter.") == :no
      assert Bierce.headword_prefix("T, the twentieth letter of the alphabet.") == :no
    end

    test "an attribution is not a headword phrase" do
      # `W.J. Candleton` has the shape of `LL.D. Letters indicating…`; only the
      # sentence test separates them.
      assert Bierce.headword_prefix("W.J. Candleton") == :no
      assert Bierce.headword_prefix("Jamrach Holobom") == :no
    end
  end

  describe "pos/1" do
    test "every marker in the text maps to a lexicon part of speech" do
      assert Bierce.pos("n") == "noun"
      assert Bierce.pos("n.pl") == "noun"
      assert Bierce.pos("v.t") == "verb"
      assert Bierce.pos("v.i") == "verb"
      assert Bierce.pos("p.p") == "verb"
      assert Bierce.pos("adj") == "adj"
      assert Bierce.pos("pro") == "pron"
      assert Bierce.pos(nil) == "unknown"
    end

    test "x is a joke, not a missing value" do
      # `HASH, x. There is no definition for this word…`. A whitelist that
      # rejected it would drop the entry.
      assert "x" in Bierce.pos_markers()
      assert Bierce.pos("x") == "unknown"
    end
  end

  describe "materialize/1" do
    defp materialize(fixture) do
      raw = Fixtures.one_raw("bierce", fixture)
      record = Fixtures.source_record(raw, external_id: raw["headword"], url: "https://example/x")
      {:ok, out} = Bierce.materialize(record)
      out
    end

    test "the flagship entry, prose then verse then attribution" do
      out = materialize("cat")
      [entry] = out.entries

      assert entry.headword == "CAT"
      assert entry.pos == "n"
      assert entry.lexeme == {"en", "cat", "noun"}
      assert entry.body_format == :markdown
      assert entry.year == 1911
      assert entry.author == "ambrose-bierce"

      assert entry.body =~
               "A soft, indestructible automaton provided by nature to be kicked"

      # Verse is a blockquote and keeps its line breaks: it is the joke.
      assert entry.body =~ ">   This is a dog,"
      assert entry.body =~ "— Elevenson"
      assert entry.metadata["verse"] == true
      assert entry.metadata["attributions"] == ["Elevenson"]
    end

    test "the headword and its marker are columns, not body text" do
      [entry] = materialize("cat").entries
      refute String.starts_with?(entry.body, "CAT")
    end

    test "an alternate headword's body starts at the definition too" do
      [entry] = materialize("babe").entries

      assert String.starts_with?(entry.body, "A misshapen creature")
      refute entry.body =~ "BABY"
    end

    test "a stub's body is only its verse" do
      [entry] = materialize("insectivora").entries
      assert String.starts_with?(entry.body, ">")
      assert entry.metadata["verse"] == true
    end

    test "italics survive, because the fragments are stored as markup" do
      # `<i>` is the only inline tag in the corpus — foreign phrases and titles.
      [entry] = materialize("monument").entries
      assert entry.body =~ "*reductiones ad absurdum*"
    end

    test "See X becomes a see_also relation with the target unresolved" do
      out = materialize("brute")

      assert [%{type: :see_also, to_lemma: "husband", from_lexeme: {"en", "brute", "noun"}}] =
               out.relations
    end

    test "[from X] becomes a related relation" do
      out = materialize("academy")
      assert [%{type: :related, to_lemma: "academe"}] = out.relations
    end

    test "an alternate headword becomes an alt_of pointing at the printed one" do
      out = materialize("babe")

      assert %{type: :alt_of, to_lemma: "babe", from_lexeme: {"en", "baby", "noun"}} =
               Enum.find(out.relations, &(&1.type == :alt_of))

      # Both words get a lexeme, so `baby` has a page that leads to `babe`.
      assert Enum.sort(Enum.map(out.lexemes, & &1.key)) ==
               [{"en", "babe", "noun"}, {"en", "baby", "noun"}]
    end

    test "the joke part of speech is kept verbatim and normalized separately" do
      [entry] = materialize("hash").entries
      assert entry.pos == "x"
      assert entry.lexeme == {"en", "hash", "unknown"}
      assert entry.metadata["pos_marker"] == "x"
    end

    test "the <pre>-wrapped entry materializes like any other" do
      [entry] = materialize("eucharist").entries
      assert entry.headword == "EUCHARIST"
      assert entry.body =~ "A sacred feast of the religious sect of Theophagi"
      assert entry.metadata["verse"] == false
    end

    test "an entry with 26 continuations keeps them all, in order" do
      [entry] = materialize("story").entries
      assert entry.metadata["continuations"] == 26
      assert entry.body =~ "STORY" == false
      assert length(String.split(entry.body, "\n\n")) == 27
    end

    test "a letter essay is an entry whose headword is the letter" do
      [entry] = materialize("x").entries
      assert entry.headword == "X"
      assert entry.lexeme == {"en", "x", "unknown"}
      assert entry.body =~ "needless letter"

      # And it keeps its opening letter: the letter is the sentence's subject,
      # not a printed headword to strip.
      assert String.starts_with?(entry.body, "X in our alphabet")
    end

    test "an empty record materializes to nothing rather than raising" do
      assert {:ok, out} = Bierce.materialize(Fixtures.source_record(%{}, external_id: "X/n"))
      assert out == %{}
    end
  end

  describe "trim/1" do
    test "a public-domain dictionary is imported in full" do
      raw = Fixtures.one_raw("bierce", "cat")
      assert Bierce.trim(raw) == raw
    end
  end
end
