defmodule DevilsDictionaryWeb.SourceBadgeTest do
  @moduledoc """
  The one way a source is identified (#152): the monogram a badge falls back
  to, the order the stack takes, and what the two draw.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DevilsDictionaryWeb.SourceBadge

  describe "initials/1" do
    test "the first two significant words of the name before its comma" do
      assert SourceBadge.initials("Samuel Johnson, A Dictionary of the English Language") == "SJ"
      assert SourceBadge.initials("Ambrose Bierce, The Devil's Dictionary") == "AB"
      assert SourceBadge.initials("Open Library") == "OL"
      assert SourceBadge.initials("Urban Dictionary") == "UD"
      assert SourceBadge.initials("The Guardian") == "G"
    end

    test "a parenthetical, a via and a year are not the name" do
      assert SourceBadge.initials("Wiktionary (English) via Kaikki") == "W"
      assert SourceBadge.initials("Wikipedia (English)") == "W"
      assert SourceBadge.initials("Open English WordNet 2025") == "OE"
    end

    test "nothing to draw is a question mark, never a crash" do
      assert SourceBadge.initials(nil) == "?"
      assert SourceBadge.initials("") == "?"
      assert SourceBadge.initials("(2025)") == "?"
    end
  end

  describe "compose/1" do
    test "tier then slug, one entry per slug, the first seen kept" do
      composed =
        SourceBadge.compose([
          %{slug: "wikidata", name: "Wikidata", tier: :middle, anchor: "#concept-card"},
          %{slug: "unsplash", name: "Unsplash", tier: :plebs, anchor: "#culture-shelf-image"},
          %{slug: "johnson", name: "Samuel Johnson", tier: :aristocracy, anchor: "#card-johnson"},
          %{slug: "wikidata", name: "Wikidata", tier: :middle, anchor: "#culture-shelf-artwork"},
          %{slug: "catalog", name: "Saved catalog", tier: nil, anchor: "#culture-shelf-artwork"},
          %{slug: "bierce", name: "Ambrose Bierce", tier: :aristocracy, anchor: "#card-bierce"}
        ])

      assert Enum.map(composed, & &1.slug) == ~w(bierce johnson wikidata unsplash catalog)
      assert Enum.find(composed, &(&1.slug == "wikidata")).anchor == "#concept-card"
    end
  end

  describe "badge/1" do
    test "a monogram, hidden from the tree when the name is printed beside it" do
      html =
        render_component(&SourceBadge.badge/1,
          source: %{slug: "johnson", name: "Samuel Johnson, A Dictionary", tier: :aristocracy},
          decorative: true
        )

      assert html =~ "SJ"
      assert html =~ ~s(aria-hidden)
      assert html =~ "bg-amber-100"
      refute html =~ "<img"
    end

    test "a local logo instead of the monogram; a hotlink is no logo at all" do
      local =
        render_component(&SourceBadge.badge/1,
          source: %{slug: "x", name: "Xyz", tier: :middle, logo: "/images/sources/x.svg"}
        )

      assert local =~ ~s(src="/images/sources/x.svg")
      assert local =~ ~s(role="img")
      assert local =~ ~s(aria-label="Xyz")

      remote =
        render_component(&SourceBadge.badge/1,
          source: %{slug: "x", name: "Xyz", tier: :middle, logo: "https://cdn.example/x.svg"}
        )

      refute remote =~ "<img"
      assert remote =~ "X"
    end
  end

  describe "stack/1" do
    test "one link per source to its block, the name on it, and the count" do
      html =
        render_component(&SourceBadge.stack/1,
          id: "page-sources",
          sources: [
            %{
              slug: "johnson",
              name: "Samuel Johnson, A Dictionary",
              tier: :aristocracy,
              logo: nil,
              anchor: "#card-johnson"
            },
            %{
              slug: "spotify",
              name: "Spotify",
              tier: :middle,
              logo: nil,
              anchor: "#culture-shelf-music"
            }
          ]
        )

      assert html =~ ~s(id="page-sources-johnson")
      assert html =~ ~s(href="#card-johnson")
      assert html =~ ~s(title="Samuel Johnson, A Dictionary")
      assert html =~ ~s(href="#culture-shelf-music")
      assert html =~ "2 sources on this page"
      # The tooltip is the short name; the title and the link text are whole.
      assert html =~ ~r/role="tooltip"[^>]*>\s*<span[^>]*>👑<\/span>\s*Samuel Johnson\s*</
    end

    test "folds everything past the cap behind a +N that opens in place (#162)" do
      sources =
        for n <- 1..15 do
          %{slug: "s#{n}", name: "Source #{n}", tier: :plebs, logo: nil, anchor: "#card-s#{n}"}
        end

      html = render_component(&SourceBadge.stack/1, id: "page-sources", sources: sources)

      # Twelve on the row, the rest behind the fold; every one still a link.
      for n <- 1..15, do: assert(html =~ ~s(id="page-sources-s#{n}"))
      assert html =~ ~s(id="page-sources-more")
      assert html =~ ~r/>\s*\+3\s*</
      # Hover says who is folded, and the count is the whole page's.
      assert html =~ ~s(title="Source 13, Source 14, Source 15")
      assert html =~ "15 sources on this page"

      # Twelve or fewer: no fold at all.
      twelve =
        render_component(&SourceBadge.stack/1,
          id: "page-sources",
          sources: Enum.take(sources, 12)
        )

      refute twelve =~ "page-sources-more"
    end

    test "draws nothing for a page with no sources" do
      assert render_component(&SourceBadge.stack/1, id: "page-sources", sources: []) == ""
    end
  end
end
