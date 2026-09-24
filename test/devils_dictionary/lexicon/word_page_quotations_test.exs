defmodule DevilsDictionary.Lexicon.WordPageQuotationsTest do
  @moduledoc """
  The quotations a sense carries (#158 build 1): which of the absorbed
  examples count, how they fold, where they are cut, and what each one says
  about itself. The data contract, not the HTML — the template only shows it.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Quotations.Fingerprint

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  @sherman %{
    "type" => "quotation",
    "text" =>
      "War is cruelty, and you cannot refine it; and those who brought war into our Country deserve all the curses and maledictions a people can pour out.",
    "ref" =>
      "1864 September 12, William T. Sherman, letter to the mayor and city council of Atlanta:"
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
    "ref" =>
      "1939 October 30, “Paintings by Adolf Hitler”, in Life, volume 7, number 18, page 52:"
  }

  @usage %{"type" => "example", "text" => "flame war... edit war..."}

  defp quotations(ctx, word, examples) do
    lexeme = word!(ctx, word, ~w(wiktionary))
    sense = sense!(ctx, lexeme, "wiktionary", gloss: "a meaning", examples: examples)

    page = word |> Lexicon.lookup() |> WordPage.build()
    [%{groups: [%{senses: senses}]}] = page.cards
    %{quotations: quotations} = Enum.find(senses, &(&1.id == sense.object_id))
    quotations
  end

  describe "which examples are quotations" do
    test "a typed quotation with a citation counts; a usage example and an uncited or untyped line do not",
         ctx do
      examples = [
        @sherman,
        @usage,
        # Kaikki's third kind: no `type` at all, even with a citation.
        %{"text" => "And they warred against the Midianites.", "ref" => "1611, King James Bible"},
        # A quotation the wiki left uncited is a claim with nothing to check.
        %{"type" => "quotation", "text" => "War is hell."},
        %{"type" => "quotation", "text" => "War is hell.", "ref" => "  "},
        %{"type" => "quotation", "text" => "", "ref" => "1864, someone"}
      ]

      assert %{total: 1, shown: [line], rest: []} = quotations(ctx, "war", examples)
      assert line.text == @sherman["text"]
    end

    test "a line with no words left after normalising is not a quotation", ctx do
      assert %{total: 0} =
               quotations(ctx, "war", [
                 %{"type" => "quotation", "text" => "…", "ref" => "1611, KJV"}
               ])
    end

    test "a sense with no examples, or whose column holds the database's empty object, has none",
         ctx do
      assert %{shown: [], rest: [], total: 0} = quotations(ctx, "war", [])
      assert %{shown: [], rest: [], total: 0} = quotations(ctx, "peace", %{})
    end
  end

  describe "what a quotation carries" do
    test "the words, the ref untouched, the citation, its fingerprint and a plausible provenance",
         ctx do
      assert %{shown: [line]} = quotations(ctx, "war", [@sherman])

      assert line.text == @sherman["text"]
      assert line.ref == @sherman["ref"]
      assert line.fingerprint == Fingerprint.fingerprint(@sherman["text"])
      # Derived, stored nowhere, the same for every absorbed line: one cited
      # claim that nothing has verified yet.
      assert line.provenance == "plausible"
    end

    test "the citation drops the colon that introduced the passage on the wiki, and only that",
         ctx do
      assert %{shown: [sherman, kjv]} = quotations(ctx, "war", [@sherman, @kjv])

      assert sherman.citation ==
               "1864 September 12, William T. Sherman, letter to the mayor and city council of Atlanta"

      # One colon: the verse reference keeps its own.
      assert kjv.citation == "1611, King James Version, Numbers 31:7"
    end
  end

  describe "the fold and the cap" do
    test "two examples with one wording are one quotation, the first as filed (ADR 0003)", ctx do
      retyped = %{
        @sherman
        | "text" =>
            "“WAR IS CRUELTY, and you cannot refine it; and those who brought war into our Country deserve all the curses and maledictions a people can pour out.”",
          "ref" => "a second citation:"
      }

      assert %{total: 1, shown: [line]} = quotations(ctx, "war", [@sherman, retyped])
      assert line.text == @sherman["text"]
      assert line.citation =~ "Sherman"
    end

    test "a few show and the rest are held back, in the source's order", ctx do
      assert %{shown: shown, rest: rest, total: 4} =
               quotations(ctx, "war", [@sherman, @kjv, @daniel, @life])

      assert length(shown) == WordPage.quotation_cap()
      assert Enum.map(shown, & &1.citation) |> Enum.map(&String.slice(&1, 0, 4)) == ~w(1864 1611)
      assert Enum.map(rest, & &1.citation) |> Enum.map(&String.slice(&1, 0, 4)) == ~w(1595 1939)
    end
  end
end
