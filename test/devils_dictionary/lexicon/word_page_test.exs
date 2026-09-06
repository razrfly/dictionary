defmodule DevilsDictionary.Lexicon.WordPageTest do
  @moduledoc """
  The data contract behind `/define/:slug` (#71 §7 and §8a). Every assertion
  here is about the struct, not about HTML: if the query module decides it, it
  is tested here, and the template is only tested for showing it.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp page(word, opts \\ []), do: word |> Lexicon.lookup() |> WordPage.build(opts)

  describe "cards" do
    test "are ordered by tier, then by the year the source speaks from", ctx do
      oyster = word!(ctx, "oyster", ~w(bierce johnson wiktionary))
      entry!(ctx, oyster, "bierce", body: "A slimy, gobby shellfish.")
      entry!(ctx, oyster, "johnson", body: "A bivalve testaceous fish.")
      sense!(ctx, oyster, "wiktionary", gloss: "Any marine bivalve mollusk.")

      cards = page("oyster").cards

      assert Enum.map(cards, & &1.source.slug) == ~w(johnson bierce wiktionary)
      assert Enum.map(cards, & &1.tier) == [:aristocracy, :aristocracy, :middle]
      assert Enum.map(cards, & &1.year) == [1755, 1911, 2026]
    end

    test "a source with one card is named by its slug, several by their part of speech", ctx do
      noun = word!(ctx, "oyster", ~w(bierce wiktionary))
      verb = word!(ctx, "oyster", ~w(wiktionary), pos: "verb")
      entry!(ctx, noun, "bierce", body: "A slimy, gobby shellfish.")
      sense!(ctx, noun, "wiktionary", gloss: "A mollusk.")
      sense!(ctx, verb, "wiktionary", gloss: "To fish for oysters.")

      ids = page("oyster").cards |> Enum.map(& &1.id)

      assert "card-bierce" in ids
      assert "card-wiktionary-noun" in ids
      assert "card-wiktionary-verb" in ids
      assert ids == Enum.uniq(ids)
    end

    test "several capitalisations of one word share a card rather than a duplicate id", ctx do
      cat = word!(ctx, "cat", ~w(wordnet))
      acronym = word!(ctx, "CAT", ~w(wordnet), slug: "cat")
      sense!(ctx, cat, "wordnet", group_key: "oewn-1-n", gloss: "a feline")
      sense!(ctx, acronym, "wordnet", group_key: "oewn-2-n", gloss: "a scan")

      cards = page("cat").cards

      assert [%{id: "card-wordnet", groups: groups}] = cards
      assert length(groups) == 2
    end

    test "a dead author's markdown becomes html, and it is built here not in the template", ctx do
      oyster = word!(ctx, "oyster", ~w(johnson))

      entry!(ctx, oyster, "johnson",
        body: "A bivalve testaceous fish.\n\n> the world's mine oyster. Shakesp.",
        body_format: :markdown
      )

      assert [%{entries: [entry]}] = page("oyster").cards
      assert entry.body_html =~ "<p>A bivalve testaceous fish.</p>"
      assert entry.body_html =~ "<blockquote>"
    end

    test "an empty card is not built at all", ctx do
      word!(ctx, "oyster", ~w(wiktionary))
      assert page("oyster").cards == []
    end
  end

  describe "the placement rule (#71 §8a.3)" do
    setup ctx do
      cat = word!(ctx, "cat", ~w(wordnet wiktionary))
      feline = word!(ctx, "feline", ~w(wordnet))
      vehicle = word!(ctx, "tracked vehicle", ~w(wordnet))
      kitty = word!(ctx, "kitty", ~w(wiktionary))

      animal =
        sense!(ctx, cat, "wordnet",
          group_key: "oewn-animal-n",
          gloss: "a feline mammal",
          position: 0
        )

      tank =
        sense!(ctx, cat, "wordnet",
          group_key: "oewn-vehicle-n",
          gloss: "a tracked vehicle",
          position: 1
        )

      relation!(ctx, cat, :hypernym, feline,
        source: "wordnet",
        from_sense: animal,
        to_group_key: "g1"
      )

      relation!(ctx, cat, :hypernym, vehicle,
        source: "wordnet",
        from_sense: tank,
        to_group_key: "g2"
      )

      relation!(ctx, cat, :derived, kitty, source: "wiktionary")

      Map.merge(ctx, %{cat: cat})
    end

    test "a sense-scoped edge renders under its own sense and nowhere else", ctx do
      page = page("cat")
      [card] = Enum.filter(page.cards, &(&1.source.slug == "wordnet"))
      [animal_group, vehicle_group] = card.groups

      assert chips(sense_of(animal_group).relations, :broader) == ["feline"]
      assert chips(sense_of(vehicle_group).relations, :broader) == ["tracked vehicle"]

      # The whole point: the animal sense never lists the vehicle's parent.
      refute "tracked vehicle" in chips(sense_of(animal_group).relations, :broader)
      _ = ctx
    end

    test "a source with no synsets keeps each sense's chips under that sense", ctx do
      # The U1a audit's remaining half of the rule. Wiktionary senses share the
      # nil group key, so grouping the chips one level up put *cat*'s slang
      # synonyms beside its feline ones.
      cat = ctx.cat
      kitty = word!(ctx, "kitty2", ~w(wiktionary))
      bloke = word!(ctx, "bloke", ~w(wiktionary))

      feline = sense!(ctx, cat, "wiktionary", gloss: "a small feline", position: 0)
      slang = sense!(ctx, cat, "wiktionary", gloss: "a man", position: 1)

      relation!(ctx, cat, :synonym, kitty, from_sense: feline)
      relation!(ctx, cat, :synonym, bloke, from_sense: slang)

      [card] = Enum.filter(page("cat").cards, &(&1.source.slug == "wiktionary"))
      [group] = card.groups
      [first, second] = group.senses

      assert chips(first.relations, :similar) == ["kitty2"]
      assert chips(second.relations, :similar) == ["bloke"]
    end

    test "an edge with no sense renders in the page-level block for its part of speech", ctx do
      [related] = page("cat").related

      assert related.pos == "noun"
      assert chips(related.groups, :family) == ["kitty"]
      refute Map.has_key?(related.groups, :broader)
      _ = ctx
    end
  end

  describe "groups (#71 §7's map)" do
    test "each relation type lands in its named group", ctx do
      joy = word!(ctx, "joy", ~w(wiktionary))

      for {type, lemma} <- [
            {:synonym, "delight"},
            {:antonym, "grief"},
            {:hypernym, "emotion"},
            {:hyponym, "elation"},
            {:meronym, "smile"},
            {:holonym, "mood"},
            {:derived, "joyful"},
            {:alt_of, "ioy"}
          ] do
        relation!(ctx, joy, type, word!(ctx, lemma, ~w(wiktionary)))
      end

      [related] = page("joy").related

      assert chips(related.groups, :similar) == ["delight"]
      assert chips(related.groups, :opposite) == ["grief"]
      assert chips(related.groups, :broader) == ["emotion"]
      assert chips(related.groups, :narrower) == ["elation"]
      assert chips(related.groups, :parts) == ["smile"]
      assert chips(related.groups, :part_of) == ["mood"]
      assert chips(related.groups, :family) == ["joyful"]
      assert chips(related.groups, :variants) == ["ioy"]
    end

    test "see_also becomes one group per author, and WordNet's folds into related", ctx do
      oyster = word!(ctx, "oyster", ~w(johnson wordnet))
      clam = word!(ctx, "clam", ~w(wiktionary))
      mussel = word!(ctx, "mussel", ~w(wiktionary))

      relation!(ctx, oyster, :see_also, clam, source: "johnson")
      relation!(ctx, oyster, :see_also, mussel, source: "wordnet")

      [related] = page("oyster").related
      {{:says_see, source}, chips} = Enum.find(related.groups, &match?({{:says_see, _}, _}, &1))

      assert source.slug == "johnson"
      assert Enum.map(chips.shown, & &1.lemma) == ["clam"]
      assert chips(related.groups, :related) == ["mussel"]
    end

    test "a chip never points at an unresolved target", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))
      relation!(ctx, oyster, :derived, nil, to_lemma: "oysterhood")

      assert page("oyster").related == []
    end

    test "chips are capped, enriched first, and carry their overflow", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))

      for i <- 1..15 do
        target = word!(ctx, "derived#{i}", ~w(wiktionary), enriched_at: nil)
        relation!(ctx, oyster, :derived, target)
      end

      bold = word!(ctx, "oyster bed", ~w(wiktionary))
      relation!(ctx, oyster, :derived, bold)

      [related] = page("oyster").related
      family = related.groups[:family]

      assert length(family.shown) == WordPage.chip_cap()
      assert family.total == 16
      assert length(family.rest) == 4
      assert hd(family.shown).lemma == "oyster bed"
      assert hd(family.shown).enriched?
      assert related.counts[:family] == 16
    end
  end

  describe "the chain" do
    test "walks synset to synset and stops at the cap", ctx do
      oyster = word!(ctx, "oyster", ~w(wordnet))
      sense = sense!(ctx, oyster, "wordnet", group_key: "oewn-oyster-n", gloss: "a mollusk")

      # bivalve → mollusk → invertebrate, each synset reached from the last.
      chain = ~w(bivalve mollusk invertebrate)

      Enum.reduce(Enum.with_index(chain), {oyster, sense}, fn {lemma, i}, {from, from_sense} ->
        target = word!(ctx, lemma, ~w(wordnet))
        key = "oewn-#{lemma}-n"

        relation!(ctx, from, :hypernym, target,
          source: "wordnet",
          from_sense: from_sense,
          to_group_key: key
        )

        {target, sense!(ctx, target, "wordnet", group_key: key, gloss: "level #{i}")}
      end)

      [card] = Enum.filter(page("oyster").cards, &(&1.source.slug == "wordnet"))
      [group] = card.groups

      assert Enum.map(group.chain, & &1.lemma) == chain
    end

    test "the chain replaces the broader chips it would otherwise repeat", ctx do
      oyster = word!(ctx, "oyster", ~w(wordnet))
      bivalve = word!(ctx, "bivalve", ~w(wordnet))
      sense = sense!(ctx, oyster, "wordnet", group_key: "oewn-oyster-n", gloss: "a mollusk")
      sense!(ctx, bivalve, "wordnet", group_key: "oewn-bivalve-n", gloss: "a shellfish")

      relation!(ctx, oyster, :hypernym, bivalve,
        source: "wordnet",
        from_sense: sense,
        to_group_key: "oewn-bivalve-n"
      )

      [card] = Enum.filter(page("oyster").cards, &(&1.source.slug == "wordnet"))
      [group] = card.groups

      assert Enum.map(group.chain, & &1.lemma) == ["bivalve"]
      refute Map.has_key?(sense_of(group).relations, :broader)
    end
  end

  describe "the thing (#71 §2.4)" do
    setup ctx do
      cat = word!(ctx, "cat", ~w(wordnet))
      animal = concept!("Q146", "cat", description: "a small carnivore", image_url: "i.jpg")
      link!(cat, animal, confidence: 0.95, method: :wiktionary_qid)

      felidae = concept!("Q25265", "Felidae", kind: :taxon)
      carnivora = concept!("Q25306", "Carnivora", kind: :taxon)
      concept_relation!(ctx, animal, :parent_taxon, felidae)
      concept_relation!(ctx, felidae, :parent_taxon, carnivora)

      Map.merge(ctx, %{cat: cat, animal: animal, felidae: felidae, carnivora: carnivora})
    end

    test "the concept card is what the linker asserted, not what it guessed", ctx do
      thing = page("cat").thing

      assert thing.concept.qid == "Q146"
      assert thing.concept.description == "a small carnivore"
      assert thing.wikipedia_url =~ "wikipedia.org"
      assert thing.wikidata_url == "https://www.wikidata.org/wiki/Q146"
      _ = ctx
    end

    test "the chain climbs, one parent per step, and carries the word where there is one", ctx do
      felid = word!(ctx, "felid", ~w(wordnet))
      link!(felid, ctx.felidae)

      chain = page("cat").thing.chain

      assert Enum.map(chain, & &1.label) == ["Felidae", "Carnivora"]
      assert Enum.map(chain, & &1.slug) == ["felid", nil]
    end

    test "an instance climbs to its class, but only at the first step", ctx do
      larry = word!(ctx, "larry", ~w(wordnet))
      individual = concept!("Q1", "Larry")
      link!(larry, individual)
      concept_relation!(ctx, individual, :instance_of, ctx.animal)

      # Carnivora is an instance of something too — a taxonomic rank. Following
      # `instance_of` above the first step is how *Larry* ends up under
      # *abstract entity*.
      rank = concept!("Q2", "taxonomic rank")
      concept_relation!(ctx, ctx.carnivora, :instance_of, rank)

      assert Enum.map(page("larry").thing.chain, & &1.label) == [
               "cat",
               "Felidae",
               "Carnivora"
             ]
    end

    test "kinds and examples are only the children that have a word", ctx do
      kitten = concept!("Q147", "kitten")
      wordless = concept!("Q2", "American Bobtail")
      tiddles = concept!("Q3", "Tiddles")

      concept_relation!(ctx, kitten, :subclass_of, ctx.animal)
      concept_relation!(ctx, wordless, :subclass_of, ctx.animal)
      concept_relation!(ctx, tiddles, :instance_of, ctx.animal)

      link!(word!(ctx, "kitten", ~w(wordnet)), kitten)
      link!(word!(ctx, "tiddles", ~w(wordnet)), tiddles)

      thing = page("cat").thing

      assert Enum.map(thing.kinds.shown, & &1.lemma) == ["kitten"]
      assert thing.kinds.total == 1
      assert Enum.map(thing.examples.shown, & &1.lemma) == ["tiddles"]
    end

    test "kinds are capped, and the count beside them is the whole number", ctx do
      for i <- 1..15 do
        kind = concept!("Q1#{i}", "kind #{i}")
        concept_relation!(ctx, kind, :subclass_of, ctx.animal)
        link!(word!(ctx, "kind#{i}", ~w(wordnet)), kind)
      end

      thing = page("cat").thing

      assert length(thing.kinds.shown) == WordPage.chip_cap()
      assert thing.kinds.total == 15
    end

    test "two asserted concepts are a disagreement, and neither one wins", ctx do
      utility = concept!("Q300918", "cat", description: "a Unix utility")
      link!(ctx.cat, utility, confidence: 0.95, method: :wiktionary_qid)

      thing = page("cat").thing

      assert Enum.map(thing.disagreement, & &1.qid) == ["Q146", "Q300918"]
      assert thing.concept.qid == "Q146"
    end

    test "a candidate is a possibility, not a claim: it is never the disagreement", ctx do
      maybe = concept!("Q4", "CAT scan")
      link!(ctx.cat, maybe, confidence: 0.4, method: :disambiguation, status: :candidate)

      thing = page("cat").thing

      assert Enum.map(thing.may_refer_to, & &1.label) == ["CAT scan"]
      assert thing.disagreement == []
    end

    test "a word that names nothing has no panel at all", ctx do
      word!(ctx, "oyster", ~w(wordnet))
      assert page("oyster").thing == nil
      _ = ctx
    end

    test "a word with only candidates still gets its may-refer-to", ctx do
      seal = word!(ctx, "seal", ~w(wordnet))
      link!(seal, concept!("Q5", "Phocidae"), confidence: 0.4, status: :candidate)

      thing = page("seal").thing

      assert thing.concept == nil
      assert Enum.map(thing.may_refer_to, & &1.label) == ["Phocidae"]
    end

    test "a bare row and a miss never reach the thing side", ctx do
      word!(ctx, "abrocome", [], enriched_at: nil)

      assert page("abrocome").thing == nil
      assert page("zzzznotaword").thing == nil
      _ = ctx
    end
  end

  describe "links out (U6)" do
    test "the row's own url wins", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))
      sense!(ctx, oyster, "wiktionary", url: "https://en.wiktionary.org/wiki/oyster")

      assert [card] = page("oyster").cards
      assert card.url == "https://en.wiktionary.org/wiki/oyster"
    end

    test "a row with no url of its own falls back to the source's template", ctx do
      oyster = word!(ctx, "oyster", ~w(wiktionary))
      sense!(ctx, oyster, "wiktionary", url: nil)

      assert [card] = page("oyster").cards
      assert card.url == "https://en.wiktionary.org/wiki/oyster#English"
    end
  end

  describe "the headword" do
    test "holds every part of speech, deduplicated sound and one etymology per text", ctx do
      noun =
        word!(ctx, "oyster", ~w(wiktionary),
          etymology: "From Middle English oystre.",
          forms: [%{"form" => "oysters"}],
          pronunciations: [%{"ipa" => "/ˈɔɪstə/"}, %{"ipa" => "/ˈɔɪstə/"}, %{"audio" => "x.ogg"}]
        )

      word!(ctx, "oyster", ~w(wiktionary), pos: "verb", etymology: "From Middle English oystre.")
      sense!(ctx, noun, "wiktionary", gloss: "A mollusk.")

      headword = page("oyster").headword

      assert Enum.map(headword.lexemes, & &1.pos) == ~w(noun verb)
      assert Enum.map(headword.pronunciations, & &1.ipa) == ["/ˈɔɪstə/"]
      assert headword.forms == ["oysters"]
      assert [%{text: "From Middle English oystre.", parts: ~w(noun verb)}] = headword.etymologies
    end

    test "a form redirects to the word it belongs to and says where it came from", ctx do
      word!(ctx, "oyster", ~w(wiktionary), forms: [%{"form" => "oysters"}])

      headword = page("oysters").headword

      assert headword.lemma == "oyster"
      assert headword.via == :form
      assert headword.matched == "oysters"
    end
  end

  describe "the sparse cases" do
    test "a bare index row is a page with a headword and no cards", ctx do
      word!(ctx, "abrocome", [], enriched_at: nil, forms: [%{"form" => "abrocomes"}])

      page = page("abrocome")

      assert page.headword.lemma == "abrocome"
      assert page.headword.forms == ["abrocomes"]
      assert page.cards == []
      assert page.related == []
    end

    test "a word nobody has ever written down is a page, not a raise", _ctx do
      page = page("zzzznotaword")

      assert page.headword.lexemes == []
      assert page.headword.via == :none
      assert page.cards == []
    end
  end

  describe "the trail" do
    test "resolves slugs to lemmas, deduplicates and keeps the most recent", ctx do
      word!(ctx, "living thing", ~w(wordnet))
      word!(ctx, "oyster", ~w(wordnet))

      trail = page("oyster", trail: ["living-thing", "living-thing"]).trail

      assert trail == [%{slug: "living-thing", lemma: "living thing"}]
    end

    test "a slug with no lexeme still renders as itself rather than vanishing", ctx do
      word!(ctx, "oyster", ~w(wordnet))

      assert page("oyster", trail: ["ghost"]).trail == [%{slug: "ghost", lemma: "ghost"}]
    end
  end

  # Chips hang off the sense, never off the group: that is the placement rule.
  defp sense_of(group), do: hd(group.senses)

  defp chips(groups, key) do
    case Map.get(groups, key) do
      nil -> []
      chips -> Enum.map(chips.shown, & &1.lemma)
    end
  end
end
