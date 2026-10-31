defmodule DevilsDictionaryWeb.WordReferenceLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import DevilsDictionary.OpeningFixtures
  alias DevilsDictionary.Fixtures

  setup ctx do
    ctx = Map.merge(ctx, Fixtures.seed_catalog!())
    Map.merge(ctx, love!(ctx))
  end

  test "curated article is clean and preserves exact choice and dictionary navigation", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?opening=fixture")
    assert has_element?(view, "#reference-article")
    refute has_element?(view, "#reference-record")
    refute has_element?(view, "#in-culture")
    refute has_element?(view, "#card-bierce")
    assert has_element?(view, "#opening-lead-text", "temporary insanity")
    assert has_element?(view, "#opening-lead-entry[href*='view=records'][href$='#card-bierce']")
    assert has_element?(view, "#opening-lead-credits")
    assert has_element?(view, "#opening-about")

    assert has_element?(
             view,
             "#opening-lead-meaning a[href*='view=records'][href$='#card-bierce']"
           )

    refute has_element?(view, "#opening-lead-meaning a[phx-click]")
    assert has_element?(view, "#opening-fixture", "not published")
    assert has_element?(view, "#entry-curated[aria-current='page']")
    assert has_element?(view, "#rail-card-bierce[href*='view=records'][href$='#card-bierce']")
    refute has_element?(view, "#entry-layout-switch")
  end

  test "source records retain every original card, source text, subject and related record once",
       ctx do
    {:ok, old, _} = live(ctx.conn, "/on/love?layout=current")
    {:ok, records, _} = live(ctx.conn, "/on/love?view=records")
    assert has_element?(records, "#source-record-view")
    refute has_element?(records, "#opening")

    for id <-
          ~w(headword word-rail word-stats card-bierce card-johnson card-wordnet card-wiktionary subjects thing related page-sources) do
      if has_element?(old, "##{id}") do
        assert has_element?(records, "##{id}")
        doc = records |> render() |> LazyHTML.from_fragment()
        assert Enum.count(LazyHTML.query(doc, "##{id}")) == 1
      end
    end

    for id <- ~w(card-bierce card-johnson card-wordnet card-wiktionary) do
      old_text = old |> element("##{id}") |> render() |> text()
      record_text = records |> element("##{id}") |> render() |> text()
      assert old_text == record_text
    end

    refute has_element?(records, "#reference-record details[name='sources']")
    assert has_element?(records, "#record-search")
    assert has_element?(records, "#record-type option[value='news']")
    assert has_element?(records, "#record-source option[value='bierce']")
    assert has_element?(records, "#record-query")
    assert has_element?(records, "#record-clear")
    assert has_element?(records, "#entry-records[aria-current='page']")
  end

  test "switching and provenance preserve exact page identity, trail and filters", ctx do
    {:ok, view, _} = live(ctx.conn, "/words/#{ctx.love.object_id}/love?trail=war&opening=fixture")
    view |> element("#entry-records") |> render_click()
    assert has_element?(view, "#source-record-view")
    assert has_element?(view, "#entry-curated[href*='trail=war']")
    assert has_element?(view, "#entry-curated[href^='/words/#{ctx.love.object_id}/love']")

    render_patch(
      view,
      "/words/#{ctx.love.object_id}/love?view=records&trail=war&q=Milton&type=quote&source=wiktionary"
    )

    assert has_element?(view, "#record-query[value='Milton']")

    assert has_element?(
             view,
             "#entry-records[href*='q=Milton'][href*='type=quote'][href*='source=wiktionary']"
           )

    view |> element("#entry-records") |> render_click()
    assert has_element?(view, "#record-query[value='Milton']")
    assert has_element?(view, "#record-search input[name='trail'][value='war']")
    assert has_element?(view, "#card-bierce-info[href*='view=records'][href*='q=Milton']")
    view |> element("#card-bierce-info") |> render_click()
    assert has_element?(view, "#provenance")
    assert has_element?(view, "#provenance-close[href*='view=records'][href*='q=Milton']")
    view |> element("#provenance-close") |> render_click()
    refute has_element?(view, "#provenance")
    assert has_element?(view, "#source-record-view")
    view |> element("#entry-curated") |> render_click()
    assert has_element?(view, "#reference-article")
    refute has_element?(view, "#record-inventory")
  end

  test "bare, unavailable and malformed filter values leave source records readable", ctx do
    DevilsDictionary.WordFixtures.word!(ctx, "sparse", [], scope: nil)
    {:ok, sparse, _} = live(ctx.conn, "/on/sparse?view=records")
    assert has_element?(sparse, "#source-record-view")
    assert has_element?(sparse, "#record-search")
    refute has_element?(sparse, "#opening")
    {:ok, malformed, _} = live(ctx.conn, "/on/love?view=records&q[a]=bad&type[a]=bad")
    assert has_element?(malformed, "#record-query[value='']")
    assert has_element?(malformed, "#reference-record #card-bierce")
    refute has_element?(malformed, "#opening-fixture")
  end

  test "a shared source filter is retained before that provider's asynchronous rows arrive",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?view=records&source=not-yet-loaded")
    assert has_element?(view, "#record-source option[value='not-yet-loaded'][selected]")
    assert has_element?(view, "#card-bierce")
    assert has_element?(view, "#record-clear[href='?view=records']")
  end

  test "canonical slug correction retains view and filter parameters", ctx do
    query = "view=records&source=bierce&q=insanity&trail=war"

    assert {:error, {:live_redirect, %{to: target}}} =
             live(ctx.conn, "/words/#{ctx.love.object_id}/old-name?" <> query)

    assert URI.parse(target).path == "/words/#{ctx.love.object_id}/love"
    assert URI.decode_query(URI.parse(target).query) == URI.decode_query(query)
  end

  test "inert filters on the curated article do not change its source navigation", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?q=Milton&type=quote&source=wiktionary")
    assert has_element?(view, "#entry-records[href='/on/love?view=records']")
    refute has_element?(view, "#record-query")
  end

  test "unknown view stays on the curated article", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?view=unrecognised")
    assert has_element?(view, "#reference-article")
    refute has_element?(view, "#record-inventory")
  end

  defp text(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
end
