defmodule DevilsDictionary.Curation.ExcerptTest do
  @moduledoc """
  The lead quotes a verbatim prefix of the stored entry, cut only where a
  sentence ends (#156).
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.Excerpt

  @love "A temporary insanity curable by marriage or by removal of the patient from the influences under which he incurred the disorder. This disease, like *caries* and many other ailments, is prevalent only among civilized races living under artificial conditions; barbarous nations breathing pure air and eating simple food enjoy immunity from its ravages. It is sometimes fatal, but more frequently to the physician than to the patient."

  test "the first sentence of Bierce on love, verbatim, and a prefix of the body" do
    assert {:ok, excerpt} = Excerpt.sentences(@love, :markdown, 1)

    assert excerpt.text ==
             "A temporary insanity curable by marriage or by removal of the patient from the influences under which he incurred the disorder."

    assert String.starts_with?(@love, excerpt.markdown)
    assert excerpt.clipped?
    assert excerpt.chars == 428
  end

  test "more sentences take more of the same paragraph, and markup is rendered, not invented" do
    assert {:ok, excerpt} = Excerpt.sentences(@love, :markdown, 2)

    assert excerpt.html =~ "like <em>caries</em> and many"
    assert excerpt.text =~ "like caries and many"
    assert String.ends_with?(excerpt.text, "enjoy immunity from its ravages.")
    assert String.starts_with?(@love, excerpt.markdown)
  end

  test "a one-sentence entry is whole, and says it is not clipped" do
    body = "Appointing your grandmother to office for the good of the party."

    assert {:ok, %{text: ^body, clipped?: false}} = Excerpt.sentences(body, :markdown, 1)
    assert {:ok, %{text: ^body, clipped?: false}} = Excerpt.sentences(body, :markdown, 3)
  end

  test "only the first block is quoted: Johnson's citations stay in the card" do
    body =
      "A grain, which in England is generally given to horses, but in Scotland supports the people.\n\n> The oats have eaten the horses. Shakespeare."

    assert {:ok, excerpt} = Excerpt.sentences(body, :markdown, 2)

    assert excerpt.text ==
             "A grain, which in England is generally given to horses, but in Scotland supports the people."

    assert excerpt.clipped?
  end

  test "an entry that opens in verse has no sentence to lead with" do
    assert {:error, :no_prose_opening} =
             Excerpt.sentences("> Love is a sickness full of woes.\n\nA sonnet.", :markdown, 1)
  end

  test "a first paragraph with no sentence end is refused rather than cut mid-clause" do
    assert {:error, :no_sentence_boundary} =
             Excerpt.sentences("A clause that trails off, and on", :markdown, 1)

    assert {:error, :empty} = Excerpt.sentences("  ", :markdown, 1)
    assert {:error, :empty} = Excerpt.sentences(nil, :markdown, 1)
  end

  test "an initial or an abbreviation is not a sentence end" do
    body = "Cited by Mr. Johnson and J. Boswell as a fault. A second sentence."

    assert {:ok, %{text: "Cited by Mr. Johnson and J. Boswell as a fault."}} =
             Excerpt.sentences(body, :markdown, 1)
  end

  test "text is escaped before any markup, so a body cannot inject HTML" do
    assert {:ok, excerpt} = Excerpt.sentences("Less <b>than</b> & more. Next.", :markdown, 1)

    refute excerpt.html =~ "<b>"
    assert excerpt.html =~ "&lt;b&gt;"
    assert excerpt.text == "Less <b>than</b> & more."
  end
end
