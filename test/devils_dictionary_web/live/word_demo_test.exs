defmodule DevilsDictionaryWeb.WordDemoTest do
  @moduledoc """
  `/define/:slug?demo=1` — fake-data mode on the page (#71 §2.8, W6, U3).

  `demo_inert_test.exs` is the other half: this file is what the mode does when
  it is on, that one is what it does when it is off, and the second is the one
  that matters.
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
    oyster = word!(ctx, "oyster", ~w(bierce johnson))
    entry!(ctx, oyster, "bierce", body: "A slimy, gobby shellfish.")
    entry!(ctx, oyster, "johnson", body: "A bivalve testaceous fish.")
    bed = word!(ctx, "oyster bed", ~w(wiktionary))
    relation!(ctx, oyster, :derived, bed)
    %{oyster: oyster, bed: bed}
  end

  describe "with ?demo=1" do
    test "the banner and one sample card per missing layer", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      assert html =~ ~s(id="demo-banner")
      assert html =~ ~s(id="card-sample-webster1913")
      assert html =~ ~s(id="card-sample-eb1911")
      assert html =~ ~s(id="card-sample-urbandictionary")
      assert html =~ ~s(id="demo-evidence")
      assert html =~ ~s(id="demo-tile-0")
    end

    test "no sample can be mistaken for a source: every one is badged and says so", ctx do
      oyster!(ctx)

      {:ok, live, html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      assert html =~ "SAMPLE DATA is on"
      assert html =~ "invented for layout"

      for id <- ~w(card-sample-webster1913 card-sample-eb1911 card-sample-urbandictionary) do
        card = live |> element("##{id}") |> render()
        assert card =~ "Sample — not real data"
        assert card =~ "border-dashed"
      end
    end

    test "the real cards are all still there, in their own order", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      assert html =~ ~s(id="card-bierce")
      assert html =~ ~s(id="card-johnson")
      assert index(html, "card-johnson") < index(html, "card-bierce")
    end

    test "the source line counts real sources only", ctx do
      oyster!(ctx)

      {:ok, plain, _} = live(ctx.conn, ~p"/define/oyster")
      {:ok, demo, _} = live(ctx.conn, ~p"/define/oyster?demo=1")

      # The banner says the samples are invented; the source line must not then
      # go and count them. The same count on both pages.
      assert render(element(plain, "#sources")) == render(element(demo, "#sources"))
    end

    test "a sample's ⓘ opens an invented drawer rather than the word's real links", ctx do
      oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      html = live |> element("#card-sample-eb1911-info") |> render_click()

      assert html =~ ~s(id="provenance")
      assert html =~ "SAMPLE ·"
      assert html =~ "SAMPLE/eb1911/1"
      assert html =~ "no such record exists"
      refute html =~ ~s(id="provenance-links")
    end

    test "a real card's ⓘ is unaffected by the mode", ctx do
      oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      html = live |> element("#card-johnson-info") |> render_click()

      assert html =~ ~s(id="provenance-records")
      refute html =~ "SAMPLE/"
    end
  end

  describe "the mode survives the walk" do
    test "a chip carries ?demo=1 to the next word", ctx do
      %{bed: bed} = oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      {:error, {:live_redirect, %{to: to}}} =
        live |> element(~s(#related-noun-family-#{bed.slug})) |> render_click()

      assert to == "/define/oyster-bed?demo=1&trail=oyster"

      {:ok, _live, html} = live(ctx.conn, to)
      assert html =~ ~s(id="demo-banner")
    end

    test "closing the drawer does not close the mode", ctx do
      oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster?demo=1")
      live |> element("#card-johnson-info") |> render_click()

      assert live |> element("#provenance-close") |> render() =~ "demo=1"
    end

    test "a trail entry keeps the mode too", ctx do
      oyster!(ctx)
      word!(ctx, "mollusk", ~w(wordnet))

      {:ok, live, _html} = live(ctx.conn, ~p"/define/mollusk?demo=1&trail=oyster")

      assert live |> element("#trail-oyster") |> render() =~ "demo=1"
    end
  end

  describe "what the mode must not touch" do
    test "a miss stays a miss — there is no layout to sample on a page with no word", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/define/zzzzz?demo=1")

      assert html =~ ~s(id="no-such-word")
      refute html =~ ~s(id="card-sample-webster1913")

      # The banner still shows: the reader asked for the mode and should be
      # told why they are not getting it.
      assert html =~ ~s(id="demo-banner")
    end

    test "the scorecard never sees a sample, because it never builds through the LiveView", ctx do
      oyster!(ctx)

      page =
        "oyster" |> DevilsDictionary.Lexicon.lookup() |> DevilsDictionary.Lexicon.WordPage.build()

      refute Enum.any?(page.cards, &String.starts_with?(&1.id, "card-sample"))
      assert DevilsDictionary.Health.cards_link_out().total > 0
    end
  end

  defp index(html, id), do: :binary.match(html, ~s(id="#{id}")) |> elem(0)
end
