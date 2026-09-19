defmodule DevilsDictionaryWeb.CultureChromeTest do
  @moduledoc """
  The shelf's chrome, rendered on its own (#126 Phase 1).

  The multi-source check runs two real stubs through the pipeline and asserts
  what reaches the rail. These are the readings it cannot reach without a
  provider that returns thirty-six items and a page that has two shelves of
  different evidence: a shelf nothing identified is demoted and capped (D1),
  a shelf has one About and one *Load more* however many sources are on it
  (D3), the byline is names (D4), and a card with no year prints no year (D5).

  The states here are hand-built maps of the shape `Discovery.state/2` returns
  — which is the same shape a transient item and a catalog item have, and the
  reason the renderer can be asked this question at all.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias DevilsDictionaryWeb.Culture

  defp image_item(slug, index) do
    %{
      external_namespace: slug,
      external_id: "#{slug}-#{index}",
      preview_metadata: %{
        "title" => "#{slug} photograph #{index}",
        "thumbnail_url" => "https://#{slug}.invalid/thumb/#{index}.jpg",
        "image_url" => "https://#{slug}.invalid/full/#{index}.jpg",
        "source_url" => "https://#{slug}.invalid/photos/#{index}",
        "attribution" => "Photographer #{index}, CC BY 4.0, via #{slug}",
        "creator" => "Photographer #{index}",
        "license" => "CC BY 4.0"
      },
      # Nothing at all: a provider that named no reason, which on the `:image`
      # row is the labelled search M6 admits.
      match_details: %{}
    }
  end

  defp depicting_item(slug, index) do
    slug
    |> image_item(index)
    |> Map.put(:match_details, %{
      "depicts" => [%{"qid" => "Q198", "relation" => "exact", "entity_label" => "war"}]
    })
  end

  defp text_item(index) do
    %{
      external_namespace: "stub_text",
      external_id: "text-#{index}",
      preview_metadata: %{
        "title" => "A poem #{index}",
        "source_url" => "https://texts.invalid/#{index}"
      },
      match_details: %{
        "query" => "war",
        "lines" => [%{"text" => "the dogs of war", "number" => 12}]
      }
    }
  end

  defp state(slug, name, type, items, extra \\ %{}) do
    Map.merge(
      %{
        status: :ready,
        items: items,
        provider: slug,
        provider_name: name,
        provider_detail: nil,
        content_types: [type],
        mapping_id: 1,
        tier: :middle,
        term: "war",
        relevance: "term",
        page: 0
      },
      extra
    )
  end

  defp render(states), do: render_component(&Culture.section/1, states: Map.new(states))

  defp ids(html, prefix) do
    ~r/id="(#{prefix}[^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_match, id] -> id end)
  end

  defp count(html, prefix), do: html |> ids(prefix) |> length()

  defp searches(slug, name, count, extra \\ %{}) do
    {slug, state(slug, name, :image, Enum.map(1..count, &image_item(slug, &1)), extra)}
  end

  describe "D1 — a search-only shelf is demoted, not hidden" do
    setup do
      html =
        render([
          searches("aa_search", "AA stock", 18),
          searches("bb_search", "BB stock", 18),
          {"texts", state("texts", "Open Library", :text, [text_item(1)])}
        ])

      %{html: html}
    end

    test "it still shows, and every card still says it is a search", %{html: html} do
      assert html =~ ~s(id="culture-shelf-image")
      assert html =~ "AA stock"

      assert html =~
               "Search result for “war”, ranked by the provider and not matched on an identifier."
    end

    test "it renders after the shelf that attested something", %{html: html} do
      {text_at, _} = :binary.match(html, ~s(id="culture-shelf-text"))
      {image_at, _} = :binary.match(html, ~s(id="culture-shelf-image"))

      assert text_at < image_at
    end

    test "it takes one page of twelve across its sources in turn", %{html: html} do
      shown = ids(html, "culture-result-")
      images = Enum.filter(shown, &String.contains?(&1, "_search-"))

      assert length(images) == 12

      # Six from each, alternating: the interleave's turns, cut at the page
      # rather than at one source's share of it.
      assert Enum.map(images, &String.slice(&1, 15, 2)) ==
               ~w(aa bb aa bb aa bb aa bb aa bb aa bb)
    end

    test "the About note lists what is on the rail and not what was delivered", %{html: html} do
      # Twelve lines across the two sections, not thirty-six.
      assert Regex.scan(~r/photograph \d+:/, html) |> length() == 12
    end

    test "Load more goes on: a loaded page raises the cap by twelve" do
      html =
        render([
          searches("aa_search", "AA stock", 18, %{page: 1}),
          searches("bb_search", "BB stock", 18, %{page: 1}),
          {"texts", state("texts", "Open Library", :text, [text_item(1)])}
        ])

      assert html |> ids("culture-result-") |> Enum.count(&String.contains?(&1, "_search-")) == 24
    end
  end

  describe "D1 — a shelf with an identity on it is unchanged" do
    setup do
      identity =
        {"cc", state("cc", "Commons", :image, Enum.map(1..18, &depicting_item("cc", &1)))}

      html =
        render([
          identity,
          searches("aa_search", "AA stock", 18),
          {"texts", state("texts", "Open Library", :text, [text_item(1)])}
        ])

      %{html: html}
    end

    test "it keeps the content-type table's position", %{html: html} do
      {image_at, _} = :binary.match(html, ~s(id="culture-shelf-image"))
      {text_at, _} = :binary.match(html, ~s(id="culture-shelf-text"))

      assert image_at < text_at
    end

    test "and it is not capped", %{html: html} do
      images =
        html
        |> ids("culture-result-")
        |> Enum.filter(&(String.contains?(&1, "_search-") or String.contains?(&1, "cc-")))

      assert length(images) == 36
    end
  end

  describe "D3 — one About and one Load more per shelf" do
    setup do
      html =
        render([
          searches("aa_search", "AA stock", 4, %{next_cursor: "2"}),
          searches("bb_search", "BB stock", 4, %{next_cursor: "2"}),
          {"cc",
           state("cc", "Commons", :image, Enum.map(1..4, &depicting_item("cc", &1)), %{
             tier: :aristocracy,
             next_cursor: nil
           })}
        ])

      %{html: html}
    end

    test "one disclosure for the shelf, with a section per contributing source", %{html: html} do
      assert ids(html, "culture-about-") == [
               "culture-about-image",
               "culture-about-image-cc",
               "culture-about-image-aa_search",
               "culture-about-image-bb_search"
             ]

      assert html =~ "Matches for “war” · About these results"
    end

    test "the sections are in tier-then-slug order, which is the rail's order", %{html: html} do
      sections = ids(html, "culture-about-image-")

      assert sections == ~w(culture-about-image-cc culture-about-image-aa_search
               culture-about-image-bb_search)
    end

    test "one Load more, naming every source that has another page", %{html: html} do
      assert count(html, "culture-more-") == 1
      assert html =~ ~s(id="culture-more-image")
      assert html =~ ~s(phx-value-providers="aa_search,bb_search")
      refute html =~ ~s(phx-value-provider=)
    end

    test "and no Load more at all when nothing can advance" do
      html = render([searches("aa_search", "AA stock", 4)])

      assert count(html, "culture-more-") == 0
    end
  end

  describe "D4 — the byline is names" do
    test "the header carries the name and the qualifier moves into the About" do
      html =
        render([
          searches("aa_search", "AA stock", 2, %{provider_detail: "search: a licence"})
        ])

      assert html =~ ~s(id="culture-provider-aa_search">AA stock</span>)
      assert html =~ "AA stock · search: a licence"
    end
  end

  describe "D5 — a card shows a year only when it has one" do
    test "no year is no line, not “Year unknown”" do
      html = render([searches("aa_search", "AA stock", 1)])

      refute html =~ "Year unknown"

      # The badge alone, and no separator in front of it.
      assert badge_line(html) == ["<span>Image</span>"]
    end

    test "a year is printed with the badge beside it" do
      dated =
        {"aa_search",
         state("aa_search", "AA stock", :image, [
           update_in(image_item("aa_search", 1).preview_metadata, &Map.put(&1, "year", "1916"))
         ])}

      html = render([dated])

      refute html =~ "Year unknown"

      assert badge_line(html) == [
               "<span>1916</span>",
               ~s(<span aria-hidden="true">·</span>),
               "<span>Image</span>"
             ]
    end

    # The spans of the one `tabular-nums` paragraph on the card, in order.
    defp badge_line(html) do
      [_before, rest | _] = String.split(html, "tabular-nums")
      [line | _] = String.split(rest, "</p>")

      ~r{<span[^>]*>[^<]*</span>}
      |> Regex.scan(line)
      |> Enum.map(fn [match] -> match end)
    end
  end
end
