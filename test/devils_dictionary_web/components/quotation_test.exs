defmodule DevilsDictionaryWeb.QuotationTest do
  @moduledoc """
  The one quotation card (#158): what it draws from its attributes, and what
  the two surfaces that use it put in the slots.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevilsDictionaryWeb.Quotation

  @wiktionary %{
    slug: "wiktionary",
    name: "Wiktionary (English) via Kaikki",
    tier: :middle,
    logo: nil
  }
  @wikiquote %{slug: "wikiquote", name: "Wikiquote", tier: :middle, logo: nil}

  defp card(assigns) do
    assigns =
      assigns
      |> assign_new(:href, fn -> nil end)
      |> assign_new(:text_id, fn -> nil end)
      |> assign_new(:sources, fn -> [@wiktionary] end)
      |> assign_new(:provenance, fn -> nil end)
      |> assign_new(:note, fn -> nil end)
      |> assign_new(:agreements, fn -> nil end)
      |> assign_new(:clamp, fn -> nil end)
      |> assign_new(:citation, fn -> nil end)
      |> assign_new(:footer, fn -> nil end)

    ~H"""
    <Quotation.card
      id="q"
      text={@text}
      href={@href}
      text_id={@text_id}
      sources={@sources}
      provenance={@provenance}
      agreements={@agreements}
      note={@note}
      clamp={@clamp}
    >
      <:citation :if={@citation}>{@citation}</:citation>
      <:footer :if={@footer}>{@footer}</:footer>
    </Quotation.card>
    """
  end

  defp html(attrs),
    do: render_component(&card/1, Keyword.put_new(attrs, :text, "We must cultivate our garden."))

  defp doc(attrs), do: attrs |> html() |> LazyHTML.from_fragment()

  test "the words come first, quoted, and link out only when given somewhere to go" do
    plain = doc([])

    assert plain |> LazyHTML.query("blockquote #q-text") |> LazyHTML.text() ==
             "“We must cultivate our garden.”"

    assert plain |> LazyHTML.query("blockquote a") |> Enum.count() == 0

    linked =
      doc(href: "https://en.wiktionary.org/wiki/garden") |> LazyHTML.query("blockquote a#q-text")

    assert Enum.count(linked) == 1
    assert LazyHTML.attribute(linked, "href") == ["https://en.wiktionary.org/wiki/garden"]
    assert LazyHTML.attribute(linked, "rel") == ["noreferrer"]
  end

  test "the caller's own id for the words wins over the derived one" do
    assert doc(text_id: "culture-entry-title-7")
           |> LazyHTML.query("#culture-entry-title-7")
           |> Enum.count() == 1

    assert doc(text_id: "culture-entry-title-7") |> LazyHTML.query("#q-text") |> Enum.count() == 0
  end

  test "one badge per source holding the line, each named for a reader who cannot see it" do
    doc = doc(sources: [@wiktionary, @wikiquote])

    assert doc |> LazyHTML.query("#q-source-wiktionary") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#q-source-wikiquote") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#q-source-wikiquote .sr-only") |> LazyHTML.text() =~ "Wikiquote"
  end

  test "the provenance badge is its own element, worded and tinted by the answer, and absent without one" do
    assert doc([]) |> LazyHTML.query("#q-provenance") |> Enum.count() == 0

    for {value, word, tint} <- [
          {"plausible", "Plausible", "bg-mist-950/5"},
          {"disputed", "Disputed", "bg-amber-100"},
          {"apocryphal", "Apocryphal", "bg-rose-100"}
        ] do
      badge = doc(provenance: value) |> LazyHTML.query("#q-provenance")
      assert Enum.count(badge) == 1
      assert LazyHTML.text(badge) |> String.trim() == word
      assert LazyHTML.attribute(badge, "class") |> hd() =~ tint
    end
  end

  test "a note prints beneath the badges and is the provenance badge's title" do
    doc = doc(provenance: "disputed", note: "Misattributed to Voltaire.")

    assert doc |> LazyHTML.query("#q-note") |> LazyHTML.text() |> String.trim() ==
             "Misattributed to Voltaire."

    assert doc |> LazyHTML.query("#q-provenance") |> LazyHTML.attribute("title") == [
             "Misattributed to Voltaire."
           ]
  end

  test "the caption and the footer are the caller's, and neither is drawn when empty" do
    bare = doc([])
    assert bare |> LazyHTML.query("figcaption") |> Enum.count() == 0
    assert bare |> LazyHTML.query("figure > p") |> Enum.count() == 0

    full = doc(citation: "1759, Voltaire, Candide", footer: "CC BY-SA 4.0")

    assert full |> LazyHTML.query("figcaption") |> LazyHTML.text() |> String.trim() ==
             "1759, Voltaire, Candide"

    assert full |> LazyHTML.query("figure > p") |> LazyHTML.text() |> String.trim() ==
             "CC BY-SA 4.0"
  end

  test "a clamp is the caller's choice; without one the words show whole" do
    assert doc([])
           |> LazyHTML.query("blockquote")
           |> LazyHTML.attribute("class")
           |> hd()
           |> String.contains?("line-clamp") == false

    assert doc(clamp: "line-clamp-5")
           |> LazyHTML.query("blockquote")
           |> LazyHTML.attribute("class")
           |> hd() =~ "line-clamp-5"
  end

  test "Verified is the verifier's word, and the title counts sources honestly" do
    verified = doc(provenance: "verified", agreements: 2)
    badge = LazyHTML.query(verified, "#q-provenance")
    assert LazyHTML.text(badge) =~ "Verified"
    assert LazyHTML.attribute(badge, "title") == ["2 independent sources agree"]

    one = doc(provenance: "plausible", agreements: 1)

    assert LazyHTML.attribute(LazyHTML.query(one, "#q-provenance"), "title") == [
             "1 source cites this line"
           ]

    # The register's sentence wins over the count.
    noted = doc(provenance: "disputed", agreements: 1, note: "Evelyn Beatrice Hall, 1906.")

    assert LazyHTML.attribute(LazyHTML.query(noted, "#q-provenance"), "title") == [
             "Evelyn Beatrice Hall, 1906."
           ]
  end
end
