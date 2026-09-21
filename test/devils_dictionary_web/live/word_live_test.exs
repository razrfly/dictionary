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

  alias DevilsDictionary.{Claims, Fixtures, Registry}
  alias DevilsDictionary.Lexicon.WordPage

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

    bivalve_sense =
      sense!(ctx, bivalve, "wordnet", group_key: "oewn-bivalve-n", gloss: "a shellfish")

    # Sense to sense: WordNet's edges run between meanings, and the chain walks
    # `group_key` to `group_key` through them.
    relation!(ctx, oyster, :hypernym, bivalve,
      source: "wordnet",
      from_sense: sense,
      to_sense: bivalve_sense
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
      assert html =~ ~s(id="related")

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

      shellfish_chips = ~s(id="card-wiktionary-group-0-sense-#{shellfish.object_id}-similar")
      paint_chips = ~s(id="card-wiktionary-group-0-sense-#{paint.object_id}-similar")

      assert html =~ shellfish_chips
      assert html =~ paint_chips

      # Each chip row sits inside its own sense: the colour's synonym comes
      # after the colour gloss, not pooled with the shellfish's.
      assert index(html, "card-wiktionary-group-0-sense-#{shellfish.object_id}") <
               index(html, "card-wiktionary-group-0-sense-#{paint.object_id}")

      assert index(html, "card-wiktionary-group-0-sense-#{shellfish.object_id}-similar") <
               index(html, "card-wiktionary-group-0-sense-#{paint.object_id}")
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
      assert html =~ "no definition or sense content has been absorbed"
      assert html =~ "https://en.wiktionary.org/wiki/abrocome"
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

    test "a headword that is also somebody's form says so", ctx do
      word!(ctx, "spat", ~w(wiktionary), enriched_at: nil)
      word!(ctx, "spit", ~w(wiktionary), forms: [%{"form" => "spat", "tags" => ["past"]}])

      {:ok, _live, html} = live(ctx.conn, ~p"/define/spat")

      assert html =~ ~s(id="also-a-form-of")
      assert html =~ ~s(href="/define/spit")
    end
  end

  describe "the sparse states (U2)" do
    test "a word the index does not hold offers the nearest words it does", ctx do
      word!(ctx, "oyster", ~w(wiktionary))
      word!(ctx, "oysterer", ~w(wiktionary))

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oysster")

      assert html =~ ~s(id="no-such-word")
      assert html =~ ~s(id="did-you-mean")
      assert html =~ ~s(id="suggestion-oyster")
    end

    test "a miss with nothing near it is still a page", ctx do
      word!(ctx, "oyster", ~w(wiktionary))

      {:ok, _live, html} = live(ctx.conn, ~p"/define/zzzznotaword")

      assert html =~ ~s(id="no-such-word")
      refute html =~ ~s(id="did-you-mean")
    end

    # #77 §1 removed the scope half of this line. A population is an operational
    # selection with an internal name; naming one in a reader's copy leaks it,
    # and the names linked the word page at what is now an ops surface. What is
    # left is the half a reader can act on.
    test "a word a population holds says nothing about the population", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      refute html =~ ~s(id="scopes")
      refute html =~ ~s(id="scope-animals")
      refute html =~ ~s(href="/s/animals")
      refute html =~ "Animals"
      refute html =~ "not in"
    end

    test "a thinly-sourced word says why it is thin, and names the one source", ctx do
      quark = word!(ctx, "quark", ~w(wordnet), scope: nil)
      sense!(ctx, quark, "wordnet", group_key: "oewn-quark-n", gloss: "an elementary particle")

      {:ok, _live, html} = live(ctx.conn, ~p"/define/quark")

      assert html =~ ~s(id="sources")
      assert html =~ ~s(id="one-source")
      assert html =~ "One source so far"
      assert html =~ "Open English WordNet"
      refute html =~ "Animals"
    end

    test "a word several sources define is counted, not listed", ctx do
      cat = word!(ctx, "cat", ~w(wordnet bierce), scope: nil)
      sense!(ctx, cat, "wordnet", group_key: "oewn-cat-n", gloss: "a feline")
      entry!(ctx, cat, "bierce", headword: "CAT", pos: "n", body: "A soft automaton.", year: 1911)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/cat")

      assert html =~ ~s(id="sources")
      assert html =~ "Defined here by 2 sources"
      refute html =~ ~s(id="one-source")
    end

    test "a bare row has no source line to print and does not invent one", ctx do
      word!(ctx, "abrocome", [], enriched_at: nil, scope: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/abrocome")

      assert html =~ ~s(id="bare-row")
      refute html =~ ~s(id="sources")
    end
  end

  describe "the provenance drawer (U3)" do
    test "every card carries an ⓘ, and it opens the record the card cites", ctx do
      oyster!(ctx)

      {:ok, live, html} = live(ctx.conn, ~p"/define/oyster")

      for card <- ~w(card-bierce card-johnson card-wiktionary card-wordnet) do
        assert html =~ ~s(id="#{card}-info")
      end

      html = live |> element("#card-wiktionary-info") |> render_click()

      assert html =~ ~s(id="provenance")
      assert html =~ ~s(id="provenance-records")
      assert html =~ "materialized"
      assert html =~ ~s(id="provenance-raw")
      assert_patched(live, "/define/oyster?provenance=card%3Acard-wiktionary")
    end

    test "the drawer shows the record's own id, url and the source's license", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))

      record =
        record!(ctx, "wiktionary",
          external_id: "oyster/noun",
          url: "https://kaikki.org/oyster",
          raw: %{"word" => "oyster"}
        )

      sense!(ctx, oyster, "wiktionary", gloss: "A mollusk.", record: record)

      {:ok, _live, html} =
        live(ctx.conn, ~p"/define/oyster?provenance=card:card-wiktionary")

      assert html =~ "oyster/noun"
      assert html =~ "https://kaikki.org/oyster"
      assert html =~ "CC BY-SA 4.0"
      assert html =~ "&quot;word&quot;: &quot;oyster&quot;"
    end

    test "a pasted drawer URL opens the drawer, and closing it keeps the walk", ctx do
      oyster!(ctx)

      {:ok, live, html} =
        live(ctx.conn, ~p"/define/oyster?trail=cat&provenance=card:card-bierce")

      assert html =~ ~s(id="provenance")
      assert html =~ ~s(id="trail")

      html = live |> element("#provenance-close") |> render_click()

      refute html =~ ~s(id="provenance-panel")
      assert_patched(live, "/define/oyster?trail=cat")
    end

    test "the thing panel opens its own drawer, keyed by the concept", ctx do
      %{oyster: oyster} = oyster!(ctx)
      concept = concept!("Q107411", "oyster", description: "a bivalve")
      link!(oyster, concept, confidence: 0.95, method: :title_match)

      {:ok, live, html} = live(ctx.conn, ~p"/define/oyster")

      assert html =~ ~s(id="thing-info")

      html = live |> element("#thing-info") |> render_click()

      assert html =~ ~s(id="provenance")
      assert html =~ ~s(id="provenance-link-Q107411-title_match")
      assert html =~ "title_match"
    end

    test "opening the drawer does not rebuild the page it is already on", ctx do
      oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      # The page is ten queries; the drawer is the records it cites plus their
      # raw. If the count comes back near ten, the `handle_params/3` guard has
      # gone and every ⓘ click is a page rebuild (#71 U2).
      queries = count_queries(fn -> live |> element("#card-bierce-info") |> render_click() end)

      assert queries <= 5
    end

    test "a provenance parameter naming nothing on the page opens nothing", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster?provenance=card:card-nonsense")

      assert html =~ ~s(id="headword")
      refute html =~ ~s(id="provenance-panel")
    end
  end

  describe "the thing (U1b)" do
    test "an evidenced sense-to-person link reaches the canonical person page", ctx do
      name = word!(ctx, "Ada Example", ~w(wordnet), scope: nil, pos: "noun")
      sense = sense!(ctx, name, "wordnet", gloss: "a named writer")
      {:ok, person} = Registry.create_person(%{preferred_label: "Ada Example"})
      {:ok, _} = Registry.add_external_id(person.object_id, "wikidata", "Q424242424")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", person.object_id, %{
          source_id: ctx.sources["wordnet"].id,
          origin_key: "wordnet_wikidata|#{sense.object_id}|#{person.object_id}",
          method: "wordnet_wikidata",
          confidence: 0.9,
          metadata: %{"wikidata_qid" => "Q424242424"}
        })

      {:ok, live, _html} = live(ctx.conn, ~p"/words/#{name.object_id}/#{name.slug}")

      assert has_element?(
               live,
               "#concept-card-entity[href='/entities/#{person.object_id}/ada-example']"
             )

      {:error, {:live_redirect, %{to: path}}} =
        live |> element("#concept-card-entity") |> render_click()

      assert path == "/entities/#{person.object_id}/ada-example"
    end

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
             |> element(~s(#related-family-#{bed.slug}))
             |> render() =~ "trail=oyster"
    end

    test "clicking a chip lands on the target with the trail in the URL", ctx do
      %{bed: bed} = oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      {:error, {:live_redirect, %{to: to}}} =
        live |> element(~s(#related-family-#{bed.slug})) |> render_click()

      assert to == "/define/oyster-bed?trail=oyster"

      {:ok, _live, html} = live(ctx.conn, to)
      assert html =~ ~s(id="trail")
      assert html =~ ~s(id="trail-oyster")
    end

    # #71 §9 asks that every group in §7's map be clickable, and until U3 one
    # of the ten was: *family*. The struct-level tests in `word_page_test.exs`
    # prove the mapping; these prove the rendered chip is a link with the right
    # id and the right href, which is a different claim and the one a reader
    # depends on. The ids are the contract — `#related-<group>-<slug>` since
    # #133 R4 merged the per-lexeme blocks into one.
    test "every relation kind in §7's map renders a chip that can be clicked", ctx do
      oyster = word!(ctx, "oyster", ~w(bierce johnson wiktionary wordnet))

      # One target per group, so a click can only have come from that group.
      targets =
        Map.new(
          [
            {:synonym, "huitre"},
            {:antonym, "clam"},
            {:hypernym, "bivalve"},
            {:hyponym, "bluepoint"},
            {:meronym, "oyster shell"},
            {:holonym, "ostreidae"},
            {:derived, "oyster bed"},
            {:alt_of, "oistre"},
            {:see_also, "pearl"},
            {:other, "spat"}
          ],
          fn {type, lemma} -> {type, word!(ctx, lemma, ~w(wiktionary))} end
        )

      for {type, target} <- targets do
        # `see_also` becomes "<author> says see" only from a 👑 source; from an
        # institution it folds into *related*, which `:other` already covers.
        source = if type == :see_also, do: "johnson", else: "wiktionary"
        relation!(ctx, oyster, type, target, source: source)
      end

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      groups = [
        {"similar", :synonym},
        {"opposite", :antonym},
        {"broader", :hypernym},
        {"narrower", :hyponym},
        {"parts", :meronym},
        {"part-of", :holonym},
        {"family", :derived},
        {"variants", :alt_of},
        {"says-see-johnson", :see_also},
        {"related", :other}
      ]

      # All ten present, in §7's order — "every group in §7's map that the word
      # has, in that order".
      positions = for {group, _type} <- groups, do: index(html, "related-#{group}")
      assert positions == Enum.sort(positions)

      # A fresh mount per group: the click is a `live_redirect`, so the first
      # one takes the LiveView with it.
      for {group, type} <- groups do
        target = targets[type]

        assert html =~ ~s(id="related-#{group}-#{target.slug}"),
               "#{group} has no chip for #{target.lemma}"

        {:ok, live, _} = live(ctx.conn, ~p"/define/oyster")

        {:error, {:live_redirect, %{to: to}}} =
          live |> element("#related-#{group}-#{target.slug}") |> render_click()

        assert to == "/define/#{target.slug}?trail=oyster",
               "clicking the #{group} chip went to #{to}"

        # And the target is a page, not a dead end — the promise in §1.
        {:ok, _live, landed} = live(ctx.conn, to)
        assert landed =~ ~s(id="headword")
        assert landed =~ ~s(id="trail-oyster")
      end
    end

    test "a sense-scoped chip is clickable too, and it is a different id path", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))
      mollusk = word!(ctx, "mollusk", ~w(wiktionary))
      sense = sense!(ctx, oyster, "wiktionary", gloss: "A marine bivalve.")

      relation!(ctx, oyster, :synonym, mollusk, from_sense: sense)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      id = "#card-wiktionary-group-0-sense-#{sense.object_id}-similar-#{mollusk.slug}"

      {:error, {:live_redirect, %{to: to}}} = live |> element(id) |> render_click()
      assert to == "/define/mollusk?trail=oyster"
    end

    test "a chain step is a hop of its own", ctx do
      %{bivalve: bivalve} = oyster!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")

      {:error, {:live_redirect, %{to: to}}} =
        live
        |> element(~s(#card-wordnet-group-0-chain a), bivalve.lemma)
        |> render_click()

      assert to == "/define/#{bivalve.slug}?trail=oyster"
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

  describe "the related block (#133 R4)" do
    # Two lexemes of the same spelling, each with its own lexeme-scoped edges.
    # Before R4 this page carried a `Related words · noun` block and a
    # `Related words · verb` block; `set` carried five, two of them calling
    # themselves `#related-adj`.
    defp two_lexemes!(ctx) do
      noun = word!(ctx, "set", ~w(wiktionary))
      verb = word!(ctx, "set", ~w(wiktionary), pos: "verb")
      name = word!(ctx, "Set", ~w(wiktionary), pos: "name")

      sense!(ctx, noun, "wiktionary", gloss: "A collection of things.")

      relation!(ctx, noun, :synonym, word!(ctx, "collection", ~w(wiktionary)))
      relation!(ctx, noun, :derived, word!(ctx, "subset", ~w(wiktionary)))
      relation!(ctx, verb, :synonym, word!(ctx, "place", ~w(wiktionary), pos: "verb"))
      relation!(ctx, verb, :derived, word!(ctx, "setting", ~w(wiktionary), pos: "verb"))
      relation!(ctx, name, :derived, word!(ctx, "Setian", ~w(wiktionary)))
      # The `LoVe` rule: a case-only variant of the headword is a spelling, not
      # a word to walk to.
      relation!(ctx, name, :derived, word!(ctx, "SET", ~w(wiktionary), pos: "name"))

      %{noun: noun}
    end

    test "every lexeme's rows land in one block, one heading, one id per group", ctx do
      two_lexemes!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/set")

      # One section, one heading, and no `· verb` beside it.
      assert length(ids(html, ~r/^related$/)) == 1
      assert length(String.split(html, "Related words")) == 2
      assert length(ids(html, ~r/^related-similar$/)) == 1
      assert length(ids(html, ~r/^related-family$/)) == 1

      # Both lexemes' edges are in those two rows, not in two blocks.
      assert html =~ ~s(id="related-similar-collection")
      assert html =~ ~s(id="related-similar-place")
      assert html =~ ~s(id="related-family-subset")
      assert html =~ ~s(id="related-family-setting")
    end

    test "every id on a multi-lexeme page is unique", ctx do
      two_lexemes!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/set")

      all = ids(html, ~r/./)
      assert all -- Enum.uniq(all) == [], "duplicate ids: #{inspect(all -- Enum.uniq(all))}"
    end

    test "a name lexeme's rows fold into `names`, last, minus the case variants", ctx do
      two_lexemes!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/set")

      assert html =~ ~s(id="related-names-setian")
      # `SET` is `set` in another case — a spelling of the same identity.
      refute html =~ ~s(id="related-names-set")
      # And a name's derivations are never the verb's family.
      refute html =~ ~s(id="related-family-setian")
      assert index(html, "related-family") < index(html, "related-names")
    end

    test "a chip names its part of speech only where the group holds more than one", ctx do
      two_lexemes!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/define/set")

      # `similar` holds a noun and a verb, so both chips say which.
      assert live |> element("#related-similar-collection") |> render() =~ "(n)"
      assert live |> element("#related-similar-place") |> render() =~ "(v)"
      # `names` holds one noun, so it says nothing.
      refute live |> element("#related-names-setian") |> render() =~ "(n)"
    end

    test "a group past the scroll cap opens into a box rather than a wall", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))

      for i <- 1..(WordPage.scroll_cap() + 1) do
        relation!(ctx, oyster, :derived, word!(ctx, "derived#{i}", ~w(wiktionary)))
      end

      {:ok, live, _html} = live(ctx.conn, ~p"/define/oyster")
      row = live |> element("#related-family") |> render()

      assert row =~ "overflow-y-auto"
      assert row =~ "max-h-64"
      # Every one of the rest is still a link, so the box is tab-reachable.
      assert row =~ ~s(id="related-family-derived49")
    end

    test "a thin block says where the sense-level chips are, and links to them", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))
      sense = sense!(ctx, oyster, "wiktionary", gloss: "A marine bivalve.")

      relation!(ctx, oyster, :derived, word!(ctx, "oyster bed", ~w(wiktionary)))
      relation!(ctx, oyster, :synonym, word!(ctx, "mollusk", ~w(wiktionary)), from_sense: sense)

      {:ok, live, html} = live(ctx.conn, ~p"/define/oyster")

      assert html =~ "Sense-by-sense relations are in each definition"

      assert live |> element("#related-senses") |> render() =~ ~s(href="#card-wiktionary")
    end

    test "a block with two groups or more says nothing of the kind", ctx do
      oyster!(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster")

      refute html =~ "Sense-by-sense relations are in each definition"
    end
  end

  # Every id the page rendered whose value matches `pattern`, duplicates kept —
  # a duplicate id is what #133 R4 is fixing and what LiveView patches wrongly.
  defp ids(html, pattern) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[id]")
    |> Enum.map(&(&1 |> Floki.attribute("id") |> hd()))
    |> Enum.filter(&Regex.match?(pattern, &1))
  end

  defp index(html, id), do: :binary.match(html, ~s(id="#{id}")) |> elem(0)
  # Counts the repo queries one interaction runs. Cheaper than a benchmark and
  # exact: a rebuilt page and a patched one differ by an order of magnitude.
  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:devils_dictionary, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {ref, :query}) end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    drain(ref, 0)
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
