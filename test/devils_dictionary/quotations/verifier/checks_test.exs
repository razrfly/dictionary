defmodule DevilsDictionary.Quotations.Verifier.ChecksTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Quotations.Verifier.Checks

  # Gutenberg's own layout: a title, blank lines, a stanza a line at a time.
  @text """
  LEAVES OF GRASS


  O Captain! my Captain! our fearful trip is done,
  The ship has weather'd every rack, the prize we sought is won,
  The port is near, the bells I hear, the people all exulting,
  While follow eyes the steady keel, the vessel grim and daring;
    But O heart! heart! heart!
      O the bleeding drops of red,
        Where on the deck my Captain lies,
          Fallen cold and dead.
  """

  defp text do
    lines = String.split(@text, "\n")

    %{
      ebook: "1322",
      label: "Leaves of Grass",
      revision_id: nil,
      lines: lines,
      line_index: Checks.index_lines(lines),
      normalised: Fingerprint.normalise(@text)
    }
  end

  test "a passage longer than three lines is located at the line it starts on" do
    stanza =
      "O captain! my captain! our fearful trip is done; The ship has weather'd every rack; " <>
        "the prize we sought is won; The port is near, the bells I hear, the people all exulting, " <>
        "While follow eyes the steady keel, the vessel grim and daring: But O heart! heart! heart! " <>
        "O the bleeding drops of red! Where on the deck my captain lies, Fallen cold and dead."

    assert [%{kind: :primary, locator: "Leaves of Grass (Gutenberg #1322), line 4"}] =
             Checks.match_texts([text()], stanza)
  end

  test "a sentence wrapped over a line break starts where it starts" do
    assert [%{locator: "Leaves of Grass (Gutenberg #1322), line 5"}] =
             Checks.match_texts([text()], "the prize we sought is won, The port is near")
  end

  test "a text without its line index is indexed on the spot" do
    assert [%{locator: "Leaves of Grass (Gutenberg #1322), line 8"}] =
             Checks.match_texts([Map.delete(text(), :line_index)], "But O heart! heart! heart!")
  end

  describe "text_body/1" do
    test "a gzip file served as the body is opened" do
      assert Checks.text_body(:zlib.gzip("Candide, or Optimism")) == "Candide, or Optimism"
    end

    test "a Latin-1 body is read as Latin-1, so it can be case-folded" do
      latin1 = <<"Voltaire, Po", 0xE8, "me sur le d", 0xE9, "sastre de Lisbonne">>
      text = Checks.text_body(latin1)

      assert String.valid?(text)
      assert text == "Voltaire, Poème sur le désastre de Lisbonne"
      assert Fingerprint.normalise(text) =~ "poème"
    end

    test "UTF-8 is left alone" do
      assert Checks.text_body("déjà vu") == "déjà vu"
    end
  end
end
