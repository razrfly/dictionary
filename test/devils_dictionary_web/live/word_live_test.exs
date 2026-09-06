defmodule DevilsDictionaryWeb.WordLiveTest do
  @moduledoc """
  `/define/:slug` — scorecard rows **U1** (the page exists), **U2** (the
  flagship words), **U6** (every card links out) and the hop itself.

  Assertions target element ids rather than words, because a word appears all
  over a dictionary page and an assertion about text is an assertion about
  nothing in particular.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})
  end

  defp oyster!(ctx) do
    oyster =
      word!(ctx, "oyster", ~w(bierce johnson wiktionary wordnet), forms: [%{"form" => "oysters"}])

    bivalve = word!(ctx, "bivalve", ~w(wordnet))
    bed = word!(ctx, "oyster bed", ~w(wiktionary))

    entry!(ctx, oyster, "bierce", body: "A slimy, gobby shellfish.")
    entry!(ctx, oyster, "johnson", body: "A bivalve testaceous fish.")
    sense!(ctx, oyster, "wiktionary", gloss: "Any marine bivalve mollusk.")
    sense = sense!(ctx, oyster, "wordnet", group_key: "oewn-oyster-n", gloss: "marine mollusks")
    sense!(ctx, bivalve, "wordnet", group_key: "oewn-bivalve-n", gloss: "a shellfish")

    relation!(ctx, oyster, :hypernym, bivalve,
      source: "wordnet",
      from_sense: sense,
      to_group_key: "oewn-bivalve-n"
    )

    relation!(ctx, oyster, :derived, bed)
    %{oyster: oyster, bivalve: bivalve, bed: bed}
  end

  describe "the page" do
    test "renders the headword, a card per source in tier order, and the related block", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      assert html =~ ~s(id="headword")
      assert html =~ ~s(id="card-bierce")
      assert html =~ ~s(id="card-johnson")
      assert html =~ ~s(id="card-wiktionary")
      assert html =~ ~s(id="card-wordnet")
      assert html =~ ~s(id="related-noun")

      # Tier before year: both 👑 cards come before the institutions.
      assert index(html, "card-johnson") < index(html, "card-wiktionary")
      assert index(html, "card-bierce") < index(html, "card-wiktionary")
    end

    test "every card carries a link out (U6)", ctx do
      oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      for card <- ~w(card-bierce card-johnson) do
        assert live |> element("##{card}-out") |> render() =~ "↗"
      end
    end

    test "a chain renders under the sense it belongs to", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      assert html =~ ~s(id="card-wordnet-group-0-chain")
      assert html =~ "bivalve"
    end

    test "no chip carries phx-value-value, the binding LiveView silently overwrites", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      refute html =~ "phx-value-value"
    end

    test "a bare index row renders its headword and says so", ctx do
      word!(ctx, "abrocome", [], enriched_at: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/abrocome")

      assert html =~ ~s(id="headword")
      assert html =~ ~s(id="bare-row")
      assert html =~ "nothing absorbed yet"
    end

    test "a word that does not exist is a page, not a crash", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/define/zzzznotaword")

      assert html =~ ~s(id="no-such-word")
      assert html =~ "No such word"
    end

    test "a form lands on its word and says where it came from", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oysters")

      assert html =~ ~s(id="redirected-from")
      assert html =~ "oysters"
      assert html =~ ~s(id="card-bierce")
    end
  end

  describe "the hop" do
    test "a chip carries the word being left in its trail", ctx do
      %{bed: bed} = oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      assert live
             |> element(~s(#related-noun-family-#{bed.slug}))
             |> render() =~ "trail=oyster"
    end

    test "clicking a chip lands on the target with the trail in the URL", ctx do
      %{bed: bed} = oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      {:error, {:live_redirect, %{to: to}}} =
        live |> element(~s(#related-noun-family-#{bed.slug})) |> render_click()

      assert to == "/define/oyster-bed?trail=oyster"

      {:ok, _live, html} = live(ctx.conn, to)
      assert html =~ ~s(id="trail")
      assert html =~ ~s(id="trail-oyster")
    end

    test "a trail entry links back to itself with the walk truncated there", ctx do
      oyster!(ctx)
      word!(ctx, "mollusk", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/define/mollusk?trail=oyster,bivalve")

      # The first entry truncates to nothing before it; the second keeps the first.
      assert live |> element("#trail-oyster") |> render() =~ ~s(href="/define/oyster")
      assert live |> element("#trail-bivalve") |> render() =~ "trail=oyster"
    end

    test "a trail is slugs only — anything else in the URL is dropped", ctx do
      oyster!(ctx)

      {:ok, live, html} =
        live(ctx.conn, ~p"/define/oyster?trail=#{"<script>alert(1)</script>,bivalve"}")

      assert html =~ ~s(id="trail-bivalve")
      refute html =~ ~s(id="trail-<script>)
      assert live |> element("#trail") |> render() =~ "bivalve"
      refute live |> element("#trail") |> render() =~ "alert(1)"
    end
  end

  defp index(html, id), do: :binary.match(html, ~s(id="#{id}")) |> elem(0)
end
