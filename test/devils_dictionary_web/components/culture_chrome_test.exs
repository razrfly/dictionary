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

  alias DevilsDictionary.Discovery.ContentTypes
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

  describe "a browser provider draws through its content-type row (#144 Phase 3)" do
    defp browser(extra \\ %{}) do
      Map.merge(
        %{
          provider: "giphy",
          provider_name: "GIPHY",
          content_type: :gif,
          hook: "GiphyShelf",
          term: "war",
          language: "en",
          api_key: "test-key",
          note: "Search matches, not reviewed interpretations."
        },
        extra
      )
    end

    defp render_browser(browsers),
      do: render_component(&Culture.section/1, states: %{}, browsers: browsers)

    test "the hook's DOM contract is intact, which is what its JavaScript reads" do
      # `giphy_shelf.mjs` queries exactly these. The component that held them
      # was deleted in Phase 3 and the markup moved into `Culture`; the hook
      # and its own tests were not touched, so this is the seam that has to
      # keep holding.
      html = render_browser([browser()])

      assert html =~ ~s(phx-hook="GiphyShelf")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ ~s(data-query="war")
      assert html =~ ~s(data-language="en")
      assert html =~ ~s(data-api-key="test-key")
      assert html =~ "data-status"
      assert html =~ "data-results"
      assert html =~ "data-more"

      # And the row's presentation, which the hook reads to build its cards:
      # the `:gif` row clamps a title to one line, and the hook must not
      # carry its own number.
      assert html =~ ~s(data-title-clamp="#{ContentTypes.title_clamp(:gif)}")
      assert html =~ ~s(data-column="#{ContentTypes.column(:gif)}")
    end

    test "the heading comes from the content-type row, not from the provider" do
      html = render_browser([browser()])

      assert html =~ ContentTypes.fetch!(:gif).heading
      # The provider is in the id: two browser providers on one content type
      # are two headings, and two ids alike is what LiveView refuses.
      assert html =~ ~s(id="culture-filter-gif-giphy")
      assert html =~ ~s(id="culture-browser-giphy-)
    end

    test "a licence that requires a mark gets one, in the shape every mark has" do
      # A licence obligation travelling in the provider's own config, in the
      # one shape (#144 followups): the same map a server provider returns
      # from `attribution_mark/0`, read by the same `Culture.mark/1` and drawn
      # by the same component into the same byline column. The renderer
      # honours it without knowing whose it is.
      marked =
        render_browser([
          browser(%{
            attribution_mark: %{
              light: "/images/giphy-powered-by.png",
              dark: nil,
              alt: "Powered by GIPHY",
              href: "https://giphy.com/",
              width: 80,
              placement: :shelf
            }
          })
        ])

      assert marked =~ ~s(id="culture-mark-giphy")
      assert marked =~ ~s(aria-label="Powered by GIPHY")
      assert marked =~ ~s(href="https://giphy.com/")
      assert marked =~ ~s(src="/images/giphy-powered-by.png")
      assert marked =~ ~s(width="80")

      # A shelf's byline names the source whether or not a licence adds a
      # mark to it, which is what the server shelf does.
      assert marked =~ ~s(id="culture-provider-giphy")

      plain = render_browser([browser()])
      refute plain =~ "giphy-powered-by.png"
      refute plain =~ "culture-mark-"
      assert plain =~ ~s(id="culture-provider-giphy")
      assert plain =~ "GIPHY"
    end

    test "a mark the shelf cannot read whole is no mark, and never a broken image" do
      # `Culture.mark/1`'s rule, reached through the browser shelf: a hotlink
      # is not an asset this app ships, and a shelf mark with nowhere to link
      # is not the mark a licence described.
      for broken <- [
            %{
              light: "//cdn.example.test/mark.png",
              alt: "A",
              href: "https://a.test/",
              width: 80,
              placement: :shelf
            },
            %{light: "/images/mark.png", alt: "A", href: nil, width: 80, placement: :shelf},
            %{light: "/images/mark.png", alt: "A", href: "https://a.test/", width: 80}
          ] do
        html = render_browser([browser(%{attribution_mark: broken})])

        refute html =~ "culture-mark-"
        refute html =~ "<img"
      end
    end

    test "two browser providers are two shelves, and neither is named in the component" do
      html =
        render_browser([
          browser(),
          browser(%{provider: "tenor", provider_name: "Tenor", hook: "TenorShelf", api_key: nil})
        ])

      assert html =~ ~s(phx-hook="GiphyShelf")
      assert html =~ ~s(phx-hook="TenorShelf")
      assert html =~ ~s(id="culture-browser-tenor-)
    end

    test "the block appears for a browser provider even with no server shelf at all" do
      html = render_browser([browser()])

      assert html =~ ~s(id="in-culture")
    end
  end

  describe "the shelf says how old it is (#144 Phase 2)" do
    defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    defp fetched(slug, name, type, items, hours, refresh_hours) do
      {slug,
       state(slug, name, type, items, %{
         fetched_at: hours_ago(hours),
         refresh_after: hours_ago(refresh_hours),
         refresh_due: refresh_hours > 0
       })}
    end

    test "a live shelf names when it was fetched and when it goes again" do
      html =
        render([fetched("texts", "PoetryDB", :text, [text_item(1)], 72, -24 * 21)])

      assert html =~ ~s(id="culture-freshness-text")
      assert html =~ "Fetched 3 days ago"
      assert html =~ "refreshes on your next visit after"
    end

    test "a shelf past its refresh clock says the visit drawing it is the one" do
      # `Discovery.request/3` is called by the same connected render that is
      # drawing this, so a shelf past `refresh_after` is already being asked
      # again — promising a date that has gone would be the page lying about
      # its own machinery.
      html = render([fetched("texts", "PoetryDB", :text, [text_item(1)], 40 * 24, 1)])

      assert html =~ "refreshing on this visit"
      refute html =~ "refreshes on your next visit"
    end

    test "a shelf is as old as the stalest source on it" do
      html =
        render([
          fetched("aa_search", "AA stock", :image, [image_item("aa_search", 1)], 1, -24),
          fetched("bb_search", "BB stock", :image, [image_item("bb_search", 1)], 72, -24 * 7)
        ])

      assert html =~ "Fetched 3 days ago"
      refute html =~ "Fetched 1 hour ago"
    end

    test "a corpus says held since, because it never refreshes by design" do
      html =
        render([
          {"catalog",
           state("catalog", "Saved catalog", :artwork, [depicting_item("catalog", 1)], %{
             archetype: :corpus,
             held_since: "2026-09-17T19:58:39Z"
           })}
        ])

      assert html =~ ~s(id="culture-freshness-artwork")
      assert html =~ "Held since 17 Sep 2026."
      refute html =~ "Fetched"
      refute html =~ "refresh"
    end

    test "a shelf with both says both, live first" do
      html =
        render([
          fetched("commons", "Commons", :artwork, [depicting_item("commons", 1)], 2, -24),
          {"catalog",
           state("catalog", "Saved catalog", :artwork, [depicting_item("catalog", 9)], %{
             archetype: :corpus,
             held_since: "2026-09-17T19:58:39Z"
           })}
        ])

      assert html =~ "Fetched 2 hours ago"
      assert html =~ "catalog held since 17 Sep 2026."
    end

    test "a shelf that has fetched nothing says nothing about its age" do
      html = render([{"texts", state("texts", "PoetryDB", :text, [text_item(1)])}])

      assert html =~ ~s(id="culture-shelf-text")
      refute html =~ ~s(id="culture-freshness-text")
    end
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

      assert html =~ ~r/id="culture-provider-aa_search">\s*AA stock\s*<\/span>/
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
    # Anchored on the badge paragraph's own class list rather than on
    # `tabular-nums` alone: the chips above the rail count their shelves in
    # tabular figures too (#131 Phase 2), and the first `tabular-nums` on the
    # page is now one of them.
    defp badge_line(html) do
      [_before, rest | _] =
        String.split(html, ~s(class="text-base tabular-nums text-mist-500 sm:text-sm"))

      [line | _] = String.split(rest, "</p>")

      ~r{<span[^>]*>[^<]*</span>}
      |> Regex.scan(line)
      |> Enum.map(fn [match] -> match end)
    end
  end
end
