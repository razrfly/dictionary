defmodule DevilsDictionary.Discovery.Providers.Wikiquote.ParserTest do
  @moduledoc """
  #158 build 4a: the probe's stdlib parser, ported, asserted on the pages it
  was measured on. The counts are the issue's where the page is unchanged; the
  ones that moved are stated beside the revision that moved them.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Providers.Wikiquote.Parser
  alias DevilsDictionary.WikiquoteFixtures

  defp parse(slug), do: slug |> WikiquoteFixtures.body() |> Parser.parse()

  defp in_section(page, section),
    do: Enum.filter(page.quotations ++ page.register, &(&1.section == section))

  test "Voltaire: 116 quotations under Quotes and 83 set aside in the register" do
    page = parse("voltaire")

    assert page.title == "Voltaire"
    assert is_integer(page.revision_id)
    assert length(in_section(page, "Quotes")) == 116
    assert length(page.register) == 83

    assert page.register |> Enum.frequencies_by(& &1.register) ==
             %{attributed: 63, disputed: 5, misattributed: 15}

    # The issue's 116 is the Quotes section. Other people's words *about* him
    # are quotations too (62 of them), but not his, and they say so.
    about = Enum.filter(page.quotations, & &1.about_subject)
    assert length(about) == 62
    assert length(page.quotations) == 116 + 62
  end

  test "Voltaire's register holds the two misattributions from #158's test case" do
    register = parse("voltaire").register

    for line <- ["I disapprove of what you say", "No snowflake in an avalanche"] do
      assert Enum.any?(register, &(&1.register == :misattributed and &1.text =~ line)),
             "#{line} is not in Voltaire's Misattributed section"
    end
  end

  test "Kurt Vonnegut's register holds Wear sunscreen, and nothing of his is lost" do
    page = parse("kurt_vonnegut")

    assert length(page.register) == 3
    assert Enum.all?(page.register, &(&1.register == :misattributed))
    assert Enum.any?(page.register, &(&1.text =~ ~r/sunscreen/i))

    # 333 on 2026-09-22; one line was added before the 2026-09-23 capture
    # (revision in the fixture's metadata).
    assert length(in_section(page, "Quotes")) == 334
  end

  test "Nepotism: three lines, and Bierce's is cited, dated and linked to his page" do
    page = parse("nepotism")

    assert length(page.quotations) == 3
    assert page.register == []
    bierce = List.last(page.quotations)

    assert bierce.text ==
             "NEPOTISM, n. Appointing your grandmother to office for the good of the party."

    assert bierce.work == "The Devil's Dictionary"
    assert bierce.year == 1911
    assert bierce.citation_links == ["Ambrose Bierce"]
    assert {bierce.section, bierce.position} == {"Quotes", 3}
  end

  test "Grief: 79, every one cited" do
    page = parse("grief")
    assert length(page.quotations) == 79
    assert Enum.all?(page.quotations, & &1.citation)
  end

  test "the redirect and the missing page are what the API answered" do
    assert %{status: 307, headers: %{"location" => location}} = WikiquoteFixtures.load("bank")
    assert location =~ "/Banking/"
    assert parse("banking").title == "Banking"
    assert %{status: 404} = WikiquoteFixtures.load("situationship")
    assert %{status: 429, headers: %{"retry-after" => "60"}} = WikiquoteFixtures.load("throttled")
  end

  test "everything extracted is a substring of the page (#101's rule)" do
    for slug <- ~w(grief nepotism banking voltaire kurt_vonnegut) do
      html = WikiquoteFixtures.body(slug)
      {:ok, document} = Floki.parse_document(html)
      page_text = document |> Floki.text(sep: " ") |> String.replace(~r/\s+/u, " ")

      for item <- parse(slug).quotations ++ parse(slug).register,
          field <- [item.text, item.work],
          is_binary(field) do
        # Compared word by word, because the parser turns `<br>` into a space
        # and the page text runs two block elements together.
        assert String.contains?(squash(page_text), squash(field)),
               "#{slug}: #{inspect(String.slice(field, 0, 80))} is not on the page"
      end
    end
  end

  defp squash(text), do: String.replace(text, ~r/\s+/u, "")

  describe "the rules, one at a time" do
    defp html(body),
      do: ~s(<html><head></head><body><section><h2>Quotes</h2>#{body}</section></body></html>)

    test "a nested li is the citation, not a quotation" do
      [q] =
        Parser.parse(
          html(
            "<ul><li>We must cultivate our garden, said he.<ul><li><i>Candide</i> (1759)</li></ul></li></ul>"
          )
        ).quotations

      assert q.text == "We must cultivate our garden, said he."
      assert q.citation == "Candide (1759)"
      assert {q.work, q.year} == {"Candide", 1759}
    end

    test "references and styles are skipped; short items dropped" do
      page =
        Parser.parse(
          html(
            ~s(<ul><li>A line long enough to keep.<sup class="reference">[1]</sup><style>.x{}</style></li><li>Too short.</li></ul>)
          )
        )

      assert Enum.map(page.quotations, & &1.text) == ["A line long enough to keep."]
    end

    test "External links, See also and References are not quotations, and the lead is not either" do
      body =
        "<section><ul><li>A lead paragraph list item, long enough.</li></ul></section>" <>
          "<section><h2>See also</h2><ul><li>Another page about the subject</li></ul></section>" <>
          "<section><h2>External links</h2><ul><li>Wikipedia has an article about it</li></ul></section>"

      assert Parser.parse("<html><body>#{body}</body></html>").quotations == []
    end

    test "the h3 is the work on an author page, and the h2 survives its section" do
      body =
        "<section><h2>Quotes</h2><section><h3>Candide (1759)</h3>" <>
          "<ul><li>We must cultivate our garden.</li></ul></section></section>"

      [q] = Parser.parse("<html><body>#{body}</body></html>").quotations

      assert {q.section, q.subsection, q.work, q.year} ==
               {"Quotes", "Candide (1759)", "Candide", 1759}
    end
  end
end
