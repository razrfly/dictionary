defmodule DevilsDictionaryWeb.HomeLiveTest do
  @moduledoc """
  `/` — the way in (#71 U2). Search, enter, *Surprise me*, the seed words and
  the stats line.

  Assertions target element ids and the URL the page patches to, because a word
  on a dictionary home page appears in half a dozen places and an assertion
  about text is an assertion about nothing in particular.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})
  end

  describe "the page" do
    test "renders the hero, the search box and the seed words", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/")

      assert html =~ "Every word. Every source. One page."
      assert html =~ ~s(id="search-q")
      assert html =~ ~s(id="surprise")
      assert html =~ ~s(id="seed-oyster")
      assert html =~ ~s(href="/define/joy")

      # The title is the default, so it does not read "wordhoard · wordhoard".
      assert html =~ ~s(Every word, every source · wordhoard</title>)

      # U0's two faces are still the page's faces.
      assert html =~ "Instrument+Serif"
      assert html =~ "family=Inter"
    end

    # #77 §1. It used to add a clause per scope — "25,385 animals enriched · 5
    # culture enriched · 809 emotions enriched" — naming internal populations in
    # public copy and presenting a five-row pilot as a product category. Three
    # whole-corpus numbers now, one of them the one that matters: how often a
    # reader who types a word finds anything.
    test "the stats line counts the index, what is defined, and the sources", ctx do
      word!(ctx, "oyster", ~w(wiktionary))
      word!(ctx, "quark", ~w(wordnet), scope: nil)
      word!(ctx, "abrocome", [], enriched_at: nil, scope: nil)

      {:ok, live, _html} = live(ctx.conn, ~p"/")
      render_async(live)

      # Read off the element and squashed, because the line wraps in the
      # template and the sentence is what is under test, not its indentation.
      stats = live |> element("#stats") |> render() |> squash()

      assert stats =~ "3 words indexed · 2 with at least one definition · 6 sources so far"

      refute stats =~ "animals enriched"
      refute stats =~ "Animals"
    end

    defp squash(html) do
      html |> String.replace(~r/<[^>]*>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end

  describe "search" do
    test "typing patches the query into the URL and lists what it found", ctx do
      word!(ctx, "oyster", ~w(wiktionary))
      word!(ctx, "oyster bed", ~w(wiktionary))
      word!(ctx, "quark", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/")

      html = live |> form("#search", %{"q" => "oyst"}) |> render_change()

      assert_patched(live, "/?q=oyst")
      assert html =~ ~s(id="result-oyster")
      assert html =~ ~s(id="result-oyster-bed")
      refute html =~ ~s(id="result-quark")
    end

    test "a pasted search URL reproduces the search", ctx do
      word!(ctx, "oyster", ~w(wiktionary))

      {:ok, _live, html} = live(ctx.conn, ~p"/?q=oyst")

      assert html =~ ~s(id="results")
      assert html =~ ~s(id="result-oyster")
    end

    test "one word, one row: a lemma with three parts of speech is not three results", ctx do
      word!(ctx, "oyster", ~w(wiktionary))
      word!(ctx, "oyster", ~w(wiktionary), pos: "verb")
      word!(ctx, "oyster", ~w(wiktionary), pos: "adj")

      {:ok, _live, html} = live(ctx.conn, ~p"/?q=oyster")

      assert length(String.split(html, ~s(id="result-oyster"))) == 2
    end

    test "a search that finds nothing says so", ctx do
      word!(ctx, "oyster", ~w(wiktionary))

      {:ok, _live, html} = live(ctx.conn, ~p"/?q=zzzznotaword")

      assert html =~ ~s(id="results-empty")
    end

    test "enter on a word goes to its page", ctx do
      word!(ctx, "oyster", ~w(wiktionary))

      {:ok, live, _html} = live(ctx.conn, ~p"/")

      live |> form("#search", %{"q" => "oyster"}) |> render_submit()

      assert_redirect(live, "/define/oyster")
    end

    test "enter on an inflected form goes to the word it belongs to", ctx do
      word!(ctx, "oyster", ~w(wiktionary), forms: [%{"form" => "oysters"}])

      {:ok, live, _html} = live(ctx.conn, ~p"/")

      live |> form("#search", %{"q" => "oysters"}) |> render_submit()

      assert_redirect(live, "/define/oyster")
    end

    test "enter on a miss stays on the page with what the trigram found", ctx do
      word!(ctx, "oyster", ~w(wiktionary))

      {:ok, live, _html} = live(ctx.conn, ~p"/")

      html = live |> form("#search", %{"q" => "oysster"}) |> render_submit()

      assert_patched(live, "/?q=oysster")
      assert html =~ ~s(id="result-oyster")
    end
  end

  describe "surprise me" do
    test "lands on an enriched word outside all test scopes", ctx do
      word!(ctx, "quark", ~w(wordnet), scope: nil)
      word!(ctx, "bareword", [], enriched_at: nil)
      word!(ctx, "oyster", [], enriched_at: nil)

      {:ok, live, _html} = live(ctx.conn, ~p"/")

      live |> element("#surprise") |> render_click()

      assert_redirect(live, "/define/quark")
    end

    test "an empty index leaves the reader where they are", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/")

      assert live |> element("#surprise") |> render_click() =~ ~s(id="search-q")
    end
  end
end
