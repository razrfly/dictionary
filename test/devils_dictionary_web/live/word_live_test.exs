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

    test "a sense's chips render inside that sense, not at the foot of the card", ctx do
      %{oyster: oyster} = oyster!(ctx)
      colour = word!(ctx, "beige", ~w(wiktionary))
      mollusk = word!(ctx, "mollusk", ~w(wiktionary))

      shellfish = sense!(ctx, oyster, "wiktionary", gloss: "A marine bivalve.", position: 1)
      paint = sense!(ctx, oyster, "wiktionary", gloss: "A pale beige colour.", position: 2)

      relation!(ctx, oyster, :synonym, mollusk, from_sense: shellfish)
      relation!(ctx, oyster, :synonym, colour, from_sense: paint)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      shellfish_chips = ~s(id="card-wiktionary-group-0-sense-#{shellfish.id}-similar")
      paint_chips = ~s(id="card-wiktionary-group-0-sense-#{paint.id}-similar")

      assert html =~ shellfish_chips
      assert html =~ paint_chips

      # Each chip row sits inside its own sense: the colour's synonym comes
      # after the colour gloss, not pooled with the shellfish's.
      assert index(html, "card-wiktionary-group-0-sense-#{shellfish.id}") <
               index(html, "card-wiktionary-group-0-sense-#{paint.id}")

      assert index(html, "card-wiktionary-group-0-sense-#{shellfish.id}-similar") <
               index(html, "card-wiktionary-group-0-sense-#{paint.id}")
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

  describe "the thing (U1b)" do
    defp catwith_thing!(ctx) do
      cat = word!(ctx, "cat", ~w(wordnet))
      sense!(ctx, cat, "wordnet", group_key: "oewn-cat-n", gloss: "a feline mammal")

      animal =
        concept!("Q146", "cat",
          description: "a small domesticated carnivore",
          image_url: "https://upload.wikimedia.org/cat.jpg",
          image_attribution: "Cat grooming.jpg · Wikimedia Commons",
          wikipedia_title: "Cat"
        )

      link!(cat, animal, confidence: 0.95, method: :wiktionary_qid)

      felidae = concept!("Q25265", "Felidae", kind: :taxon)
      concept_relation!(ctx, animal, :parent_taxon, felidae)
      felid = word!(ctx, "felid", ~w(wordnet))
      link!(felid, felidae)

      kitten = concept!("Q147", "kitten")
      concept_relation!(ctx, kitten, :subclass_of, animal)
      kitten_word = word!(ctx, "kitten", ~w(wordnet))
      link!(kitten_word, kitten)

      %{cat: cat, animal: animal, felid: felid, kitten: kitten_word}
    end

    test "the panel names the thing, shows its picture and links to both sources", ctx do
      catwith_thing!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/cat")

      assert html =~ ~s(id="thing")
      assert html =~ ~s(id="concept-card")
      assert html =~ "a small domesticated carnivore"
      assert html =~ "Wikimedia Commons"
      assert html =~ ~s(id="concept-card-wikipedia")
      assert html =~ ~s(id="concept-card-wikidata")

      # Wikidata is a thing's source, never a badge on the word.
      refute html =~ ~s(id="card-wikidata")
    end

    test "the chain and the kinds are hops, with the trail on them", ctx do
      %{felid: felid, kitten: kitten} = catwith_thing!(ctx)

      {:ok, live, html} = live(ctx.conn, ~p"/define/cat")

      assert html =~ ~s(id="thing-chain")
      assert live |> element("#thing-chain-#{felid.slug}") |> render() =~ "trail=cat"

      {:error, {:live_redirect, %{to: to}}} =
        live |> element("#thing-kinds-#{kitten.slug}") |> render_click()

      assert to == "/define/kitten?trail=cat"
    end

    test "two asserted things are a plaque, not a silent winner", ctx do
      %{cat: cat} = catwith_thing!(ctx)
      utility = concept!("Q300918", "cat", description: "a Unix utility")
      link!(cat, utility, confidence: 0.95, method: :wiktionary_qid)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/cat")

      assert html =~ ~s(id="disagreement")
      assert html =~ ~s(id="disagreement-Q300918")
      assert html =~ "a Unix utility"
    end

    test "a word that names nothing has no panel", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      refute html =~ ~s(id="thing")
    end

    test "a bare row has no panel and does not crash reaching for one", ctx do
      word!(ctx, "abrocome", [], enriched_at: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/abrocome")

      assert html =~ ~s(id="bare-row")
      refute html =~ ~s(id="thing")
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
