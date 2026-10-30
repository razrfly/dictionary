defmodule DevilsDictionaryWeb.WordReferenceLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import DevilsDictionary.OpeningFixtures
  alias DevilsDictionary.Fixtures

  setup ctx do
    ctx = Map.merge(ctx, Fixtures.seed_catalog!())
    Map.merge(ctx, love!(ctx))
  end

  test "reference view keeps every source card, concept, subject and related record once", ctx do
    {:ok, current, _} = live(ctx.conn, "/on/love?opening=fixture&layout=current")
    {:ok, reference, _} = live(ctx.conn, "/on/love?opening=fixture&layout=reference")
    assert has_element?(reference, "#reference-article")

    for id <-
          ~w(headword word-rail word-stats card-bierce card-johnson card-wordnet card-wiktionary subjects thing related page-sources) do
      if has_element?(current, "##{id}") do
        assert has_element?(reference, "##{id}")
        html = reference |> render() |> LazyHTML.from_fragment()
        assert Enum.count(LazyHTML.query(html, "##{id}")) == 1
      end
    end

    assert has_element?(reference, "#reference-record #card-bierce")
    assert has_element?(reference, "#reference-record #card-wordnet")
    assert has_element?(reference, "#opening-lead-text", "temporary insanity")
    assert has_element?(reference, "#opening-highlight-1-title", "Cupid and Psyche")
    assert has_element?(reference, "#opening-lead-credits")
    assert has_element?(reference, "#opening-about")
    assert has_element?(reference, "#opening-fixture", "not published")
  end

  test "the reference drawer opens and closes without losing the presentation or data", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?layout=reference")
    assert has_element?(view, "#card-bierce-info")
    view |> element("#card-bierce-info") |> render_click()
    assert has_element?(view, "#provenance")
    assert has_element?(view, "#reference-article #card-wordnet")
    assert has_element?(view, "#provenance-close")
    view |> element("#provenance-close") |> render_click()
    refute has_element?(view, "#provenance")
    assert has_element?(view, "#reference-article")
  end

  test "reference article is the default without comparison controls and preserves trail", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?trail=war")
    assert has_element?(view, "#reference-article")
    refute has_element?(view, "#entry-layout-switch")
    assert has_element?(view, "#definitions-any-love-false-reference")
    assert has_element?(view, "#card-bierce-info[href*='trail=war']")
    view |> element("#card-bierce-info") |> render_click()
    assert has_element?(view, "#provenance")
    view |> element("#provenance-close") |> render_click()
    refute has_element?(view, "#provenance")
    assert has_element?(view, "#reference-article")

    render_patch(view, "/on/love?trail=war&layout=current")
    refute has_element?(view, "#reference-article")
    assert has_element?(view, "#definitions-any-love-false")
    assert has_element?(view, "#card-bierce-info[href*='layout=current']")
    view |> element("#card-bierce-info") |> render_click()
    view |> element("#provenance-close") |> render_click()
    refute has_element?(view, "#reference-article")

    render_patch(view, "/on/love?trail=war")
    assert has_element?(view, "#reference-article")
    assert has_element?(view, "#definitions-any-love-false-reference")
  end

  test "unknown presentation values cannot change the reader or hide source content", ctx do
    {:ok, view, _} = live(ctx.conn, "/on/love?layout=unrecognised")
    assert has_element?(view, "#reference-article")
    assert has_element?(view, "#card-bierce")
    refute has_element?(view, "#opening")
  end
end
