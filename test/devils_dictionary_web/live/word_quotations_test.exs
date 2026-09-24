defmodule DevilsDictionaryWeb.WordQuotationsTest do
  @moduledoc """
  Wiktionary's quotations under the sense each illustrates (#158 build 1):
  the words first and the citation second, as text; one source badge and a
  provenance badge per card; a few open and the rest behind one disclosure
  that counts them; nothing on the culture rail.

  Ids, not words — a quotation about war says *war* a dozen times, and so
  does the rest of the page.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Quotations.Fingerprint

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    Map.put(ctx, :sources, sources)
  end

  @sherman %{
    "type" => "quotation",
    "text" => "War is cruelty, and you cannot refine it.",
    "ref" => "1864 September 12, William T. Sherman, letter to the mayor of Atlanta:"
  }

  @kjv %{
    "type" => "quotation",
    "text" => "And they warred against the Midianites, as the Lord commanded Moses.",
    "ref" => "1611, King James Version, Numbers 31:7:"
  }

  @daniel %{
    "type" => "quotation",
    "text" => "...to war the Scot, and borders to defend...",
    "ref" => "1595, Samuel Daniel, The First Four Books of the Civil Wars:"
  }

  @life %{
    "type" => "quotation",
    "text" => "Through much of the War, Hitler carried his painter's kit.",
    "ref" => "1939 October 30, “Paintings by Adolf Hitler”, in Life, page 52:"
  }

  @usage %{"type" => "example", "text" => "flame war... edit war..."}

  defp war!(ctx, examples) do
    war = word!(ctx, "war", ~w(wiktionary))
    conflict = sense!(ctx, war, "wiktionary", gloss: "Organized conflict.", examples: examples)
    campaign = sense!(ctx, war, "wiktionary", gloss: "A campaign against a problem.", position: 1)
    %{conflict: conflict, campaign: campaign}
  end

  defp sense_id(sense), do: "card-wiktionary-group-0-sense-#{sense.object_id}"

  defp card_id(sense, example) do
    "#{sense_id(sense)}-quotations-#{String.slice(Fingerprint.fingerprint(example["text"]), 0, 12)}-card"
  end

  describe "under the sense" do
    test "the words first and the citation second, both text and neither a link", ctx do
      %{conflict: conflict} = war!(ctx, [@sherman])

      {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

      card = card_id(conflict, @sherman)
      assert has_element?(live, "##{sense_id(conflict)}-quotations")
      assert has_element?(live, "##{card} blockquote", "War is cruelty")
      # The `ref` verbatim, but for the colon that introduced the passage.
      assert live
             |> element("##{card} figcaption")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() ==
               "1864 September 12, William T. Sherman, letter to the mayor of Atlanta"

      refute has_element?(live, "##{card} blockquote a")
      refute has_element?(live, "##{card} figcaption a")
    end

    test "one source badge and a Plausible badge on every card, and they are not the same element",
         ctx do
      %{conflict: conflict} = war!(ctx, [@sherman, @kjv])

      {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

      for example <- [@sherman, @kjv] do
        card = card_id(conflict, example)
        assert has_element?(live, "##{card}-source-wiktionary")
        assert has_element?(live, "##{card}-provenance", "Plausible")
        refute has_element?(live, "##{card}-source-wiktionary", "Plausible")

        html = live |> element("##{card}") |> render()

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("[id$='-source-wiktionary']")
               |> Enum.count() == 1
      end
    end

    test "a sense with no quotations has no block, and the culture rail holds none of them",
         ctx do
      %{campaign: campaign} = war!(ctx, [@sherman])

      {:ok, live, html} = live(ctx.conn, ~p"/define/war")

      refute has_element?(live, "##{sense_id(campaign)}-quotations")
      refute html =~ "culture-quote-"
    end
  end

  describe "how many" do
    test "a few show and the rest wait behind one disclosure that counts them", ctx do
      %{conflict: conflict} = war!(ctx, [@sherman, @kjv, @daniel, @life])

      {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

      more = "##{sense_id(conflict)}-quotations-more"
      assert has_element?(live, "#{more} summary", "2 more quotations for this sense")

      for example <- [@sherman, @kjv] do
        refute has_element?(live, "#{more} ##{card_id(conflict, example)}")
        assert has_element?(live, "##{card_id(conflict, example)}")
      end

      for example <- [@daniel, @life] do
        assert has_element?(live, "#{more} ##{card_id(conflict, example)}")
      end
    end

    test "one held back is one quotation, singular", ctx do
      %{conflict: conflict} = war!(ctx, [@sherman, @kjv, @daniel])

      {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

      assert has_element?(
               live,
               "##{sense_id(conflict)}-quotations-more summary",
               "1 more quotation for this sense"
             )
    end

    test "a usage example is not a quotation, and two spellings of one line are one card", ctx do
      restyled = %{@sherman | "text" => "“War is cruelty — and you cannot refine it”"}
      %{conflict: conflict} = war!(ctx, [@sherman, @usage, restyled])

      {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

      html = live |> element("##{sense_id(conflict)}-quotations") |> render()
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("figure") |> Enum.count() == 1
      refute html =~ "flame war"
      refute has_element?(live, "##{sense_id(conflict)}-quotations-more")
    end
  end
end
