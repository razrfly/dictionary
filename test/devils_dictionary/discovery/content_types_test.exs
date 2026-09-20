defmodule DevilsDictionary.Discovery.ContentTypesTest do
  @moduledoc """
  The content-type table is data the reader renders, so what it is missing is a
  page that renders wrong rather than a compile error.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.ContentTypes

  alias DevilsDictionary.Discovery.MatchReason

  test "every known type carries a heading, a column and a title clamp" do
    for type <- ContentTypes.known() do
      entry = ContentTypes.fetch!(type)

      assert is_binary(entry.heading) and entry.heading != ""
      assert is_binary(ContentTypes.column(type))
      assert is_binary(ContentTypes.title_clamp(type))
    end
  end

  test "every row says what a card owes its maker and which evidence it admits" do
    # #116 M4 and M6, as data. The renderer reads both off whichever row it is
    # handed and the conformance suite asserts every result against the
    # second, so a row missing either is a page that renders wrong.
    for type <- ContentTypes.known() do
      assert ContentTypes.attribution(type) in [:required, :credited, :none]

      evidence = ContentTypes.evidence(type)
      assert evidence != []
      assert Enum.all?(evidence, &(&1 in [:identity, :attestation, :query]))
    end
  end

  test "the image shelf requires attribution and is the only one that admits a search" do
    # Every file on it is shown under its own licence, whose one condition is
    # the credit; and a stock-photo search is text, honest about being one
    # (M6). The heading is *Images*, settled in Phase 1 of #116: Commons's
    # files are photographs but also engravings, maps and posters.
    assert ContentTypes.fetch!(:image).heading == "Images"
    assert ContentTypes.attribution(:image) == :required
    assert ContentTypes.evidence(:image) == [:identity, :query]

    for type <- ContentTypes.known() -- [:image, :gif] do
      refute ContentTypes.admits?(type, :query),
             "#{type} admits a bare search result"
    end
  end

  test "a text shelf admits attestation and nothing else" do
    # A text is never *about* the word; it uses it (K11).
    assert ContentTypes.evidence(:text) == [:attestation]
    assert ContentTypes.admits?(:text, %MatchReason{kind: :attestation})
    refute ContentTypes.admits?(:text, %MatchReason{kind: :tag})
    refute ContentTypes.admits?(:text, %MatchReason{kind: :query})
  end

  test "admits?/2 reads a reason's evidence class" do
    assert ContentTypes.admits?(:artwork, %MatchReason{kind: :tag})
    assert ContentTypes.admits?(:artwork, %MatchReason{kind: :depiction})
    assert ContentTypes.admits?(:artwork, %MatchReason{kind: :gene})
    assert ContentTypes.admits?(:film, %MatchReason{kind: :keyword})
    refute ContentTypes.admits?(:artwork, %MatchReason{kind: :attestation})
    refute ContentTypes.admits?(:film, %MatchReason{kind: :query})
    assert ContentTypes.admits?(:image, %MatchReason{kind: :query})
  end

  test "a text card is wider than a poster card and spends the extra line on its title" do
    # `:text` is the only type with no image slot, which is exactly why it needs
    # its own column: nothing else on the card sets a width. Measured on
    # `/define/war` at 375 px, where the poster column showed two lines of a
    # title that wanted seven (#109 Phase 3b).
    assert ContentTypes.fetch!(:text).aspect == nil
    assert ContentTypes.column(:text) != ContentTypes.column(:film)
    assert ContentTypes.title_clamp(:text) == "line-clamp-3"

    # One line under a thumbnail since #131 Phase 2: every kind is on screen
    # at once, and a rail of twelve reads by its pictures. The text card has
    # no picture, so the title is the card and keeps its three.
    for type <- ContentTypes.known() -- [:text] do
      assert ContentTypes.fetch!(type).aspect
      assert ContentTypes.title_clamp(type) == "line-clamp-1"
    end
  end
end
