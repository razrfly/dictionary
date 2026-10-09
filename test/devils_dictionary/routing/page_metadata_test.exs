defmodule DevilsDictionary.Routing.PageMetadataTest do
  @moduledoc """
  The text the metadata gate and the head's description are made from
  (#237 C1, C4): a registry description is one phrase, used whole; a
  biography's first sentence ends at a terminator followed by a capital,
  never after an initial, a known abbreviation or a dotted acronym.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.PageMetadata

  test "a description is one phrase, whole" do
    assert PageMetadata.phrase("2025 film directed by Jon M. Chu") ==
             "2025 film directed by Jon M. Chu"

    assert PageMetadata.phrase("fictional character from the G.I. Joe franchise") ==
             "fictional character from the G.I. Joe franchise"

    assert PageMetadata.phrase("1979 studio album by Kimiko Kasai ft. Herbie Hancock") ==
             "1979 studio album by Kimiko Kasai ft. Herbie Hancock"

    assert PageMetadata.phrase("  ") == nil
    assert PageMetadata.phrase(nil) == nil
  end

  test "the first sentence survives initials, abbreviations and acronyms" do
    assert PageMetadata.first_sentence("J. R. R. Tolkien was a writer. He wrote.") ==
             "J. R. R. Tolkien was a writer."

    assert PageMetadata.first_sentence("Dr. Johnson wrote a dictionary. It sold.") ==
             "Dr. Johnson wrote a dictionary."

    # Titles, plurals of address and reference marks (#243's final check).
    for {text, first} <- [
          {"Adm. Nelson won at Trafalgar. He died there.", "Adm. Nelson won at Trafalgar."},
          {"Gov. Smith signed it. Later he resigned.", "Gov. Smith signed it."},
          {"Sen. Jones and Rep. Brown voted. It passed.", "Sen. Jones and Rep. Brown voted."},
          {"Pres. Lincoln spoke. The crowd listened.", "Pres. Lincoln spoke."},
          {"Messrs. Gilbert and Sullivan wrote it. It ran.",
           "Messrs. Gilbert and Sullivan wrote it."},
          {"It stood on Fifth Ave. In 1900 it burned.",
           "It stood on Fifth Ave. In 1900 it burned."},
          {"See Fig. Three for the map. It is old.", "See Fig. Three for the map."},
          {"Vol. Two continues the tale. It ends.", "Vol. Two continues the tale."},
          {"Smith et al. Wrote the paper. It was cited.", "Smith et al. Wrote the paper."}
        ] do
      assert PageMetadata.first_sentence(text) == first, text
    end

    assert PageMetadata.first_sentence("See e.g. the first edition. Then the second.") ==
             "See e.g. the first edition."

    assert PageMetadata.first_sentence("A G.I. Joe character. Later a film.") ==
             "A G.I. Joe character."

    assert PageMetadata.first_sentence("Born in St. Louis in 1900. Died in 1950.") ==
             "Born in St. Louis in 1900."

    # A terminator followed by a lowercase word is not an end either.
    assert PageMetadata.first_sentence("It cost 1.5 million. Then more.") ==
             "It cost 1.5 million."

    # No terminator: the whole text.
    assert PageMetadata.first_sentence("A writer without a full stop") ==
             "A writer without a full stop"
  end

  test "tags and marks are removed and no space is left before punctuation" do
    assert PageMetadata.first_sentence("<p>Hello <b>world</b>.</p><p>Next.</p>") == "Hello world."

    assert PageMetadata.first_sentence("**Bold** start [link](http://x) here. More.") ==
             "Bold start link here."
  end

  test "a long sentence is cut at a word" do
    long = String.duplicate("word ", 80) <> "end."
    cut = PageMetadata.first_sentence(long)
    assert String.ends_with?(cut, "…")
    assert String.length(cut) <= 160
    refute String.contains?(cut, "wor…")
  end
end
