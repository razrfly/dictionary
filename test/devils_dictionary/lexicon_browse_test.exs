defmodule DevilsDictionary.LexiconBrowseTest do
  @moduledoc """
  The scope browse read layer (row **U5**) and the trigram search behind it,
  against a small hand-built graph so every expected number is obvious.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Claims, Encyclopedia, Health, Lexicon, Registry, Repo}
  alias DevilsDictionary.Lexicon.ScopeMember

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp lexeme!(lemma, opts \\ []) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: lemma,
        part_of_speech: Keyword.get(opts, :pos, "noun"),
        source_ids: Keyword.get(opts, :source_ids, []),
        enriched_at: Keyword.get(opts, :enriched_at, DateTime.utc_now())
      })

    lexeme
  end

  defp scoped!(scope, lexeme, reasons \\ ["wordnet_closure"]) do
    Repo.insert!(%ScopeMember{
      scope_id: scope.id,
      lexeme_id: lexeme.object_id,
      reasons: reasons
    })

    lexeme
  end

  defp concept!(qid, label, attrs \\ []) do
    attrs = Map.new(attrs)

    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: :taxon,
        preferred_label: label,
        description: Map.get(attrs, :description),
        metadata:
          %{}
          |> maybe_put("image_url", Map.get(attrs, :image_url))
          |> maybe_put("wikipedia_title", Map.get(attrs, :wikipedia_title))
      })

    {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", qid)
    entity
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A word-level guess, which is what `title_match` always was. `status: :auto`
  # means nobody has reviewed it, so nothing is written for it; a decision is a
  # review row, which is what stops an importer rerun from overwriting one.
  defp link!(lexeme, entity, opts \\ []) do
    {:ok, assertion} =
      Claims.assert(lexeme.object_id, "lexeme_entity_candidate", entity.object_id, %{
        method: to_string(Keyword.get(opts, :method, :title_match)),
        confidence: Keyword.get(opts, :confidence, 0.9)
      })

    case Keyword.get(opts, :status, :auto) do
      :auto -> :ok
      decision -> Claims.review(Claims.current_revision(assertion.id).id, decision)
    end

    assertion
  end

  defp parent!(child, parent, source_id) do
    {:ok, assertion} =
      Claims.assert(child.object_id, "parent_taxon", parent.object_id, %{source_id: source_id})

    assertion
  end

  describe "browse/2 badges" do
    test "coverage comes from source_ids, and so agrees with Health.coverage/2", ctx do
      wordnet = ctx.sources["wordnet"].id
      wiktionary = ctx.sources["wiktionary"].id
      bierce = ctx.sources["bierce"].id

      scoped!(ctx.animals, lexeme!("cat", source_ids: [wordnet, wiktionary, bierce]))
      scoped!(ctx.animals, lexeme!("oyster", source_ids: [wordnet, wiktionary]))
      scoped!(ctx.animals, lexeme!("aardvark", source_ids: [wordnet]))

      %{rows: rows, total: 3} = Lexicon.browse("animals")

      assert Enum.map(rows, & &1.lemma) == ~w(aardvark cat oyster)

      # This is U5's actual requirement: what a badge says and what the
      # scorecard says are the same number, because both read the same array.
      for slug <- ~w(wordnet wiktionary bierce) do
        id = ctx.sources[slug].id
        badges = Enum.count(rows, &(id in &1.source_ids))

        assert badges == Health.coverage("animals", slug).covered,
               "badge count for #{slug} disagrees with Health.coverage/2"

        assert %{total: ^badges} = Lexicon.browse("animals", has: [slug])
      end
    end

    test "has and missing are complements", ctx do
      bierce = ctx.sources["bierce"].id
      scoped!(ctx.animals, lexeme!("cat", source_ids: [bierce]))
      scoped!(ctx.animals, lexeme!("aardvark", source_ids: []))

      assert %{total: 1, rows: [%{lemma: "cat"}]} = Lexicon.browse("animals", has: ["bierce"])

      assert %{total: 1, rows: [%{lemma: "aardvark"}]} =
               Lexicon.browse("animals", missing: ["bierce"])
    end

    test "sorting by coverage puts the best-attested word first", ctx do
      ids = Enum.map(~w(wordnet wiktionary bierce), &ctx.sources[&1].id)
      scoped!(ctx.animals, lexeme!("aardvark", source_ids: Enum.take(ids, 1)))
      scoped!(ctx.animals, lexeme!("cat", source_ids: ids))
      scoped!(ctx.animals, lexeme!("oyster", source_ids: Enum.take(ids, 2)))

      assert %{rows: rows} = Lexicon.browse("animals", sort: :coverage)
      assert Enum.map(rows, & &1.lemma) == ~w(cat oyster aardvark)
    end

    test "a row carries its scope reasons and its thing", ctx do
      cat = scoped!(ctx.animals, lexeme!("cat"), ["wordnet_closure", "wiktionary_category"])
      link!(cat, concept!("Q146", "cat", image_url: "https://example/cat.jpg"))

      assert %{rows: [row]} = Lexicon.browse("animals")
      assert row.reasons == ["wordnet_closure", "wiktionary_category"]
      assert row.concept.qid == "Q146"
      assert row.concept.image_url == "https://example/cat.jpg"
    end

    test "a candidate link is not a word's thing", ctx do
      cat = scoped!(ctx.animals, lexeme!("cat"))
      link!(cat, concept!("Q146", "cat"), status: :candidate, confidence: 0.4)

      assert %{rows: [row]} = Lexicon.browse("animals")
      assert row.concept == nil
    end
  end

  describe "browse/2 states" do
    test "bare is an index row nothing has enriched", ctx do
      scoped!(ctx.animals, lexeme!("cat"))
      scoped!(ctx.animals, lexeme!("aardvarks", enriched_at: nil))

      assert %{total: 1, rows: [%{lemma: "aardvarks"}]} = Lexicon.browse("animals", state: :bare)
      assert %{total: 1, rows: [%{lemma: "cat"}]} = Lexicon.browse("animals", state: :enriched)
    end

    test "disputed is exactly what Health.conflicts/3 counts", ctx do
      torpedo = scoped!(ctx.animals, lexeme!("torpedo"))
      link!(torpedo, concept!("Q1", "fish"), confidence: 0.9)
      link!(torpedo, concept!("Q2", "weapon"), confidence: 0.8, method: :wiktionary_qid)

      # One concept, and a second below the threshold: not a dispute.
      cat = scoped!(ctx.animals, lexeme!("cat"))
      link!(cat, concept!("Q146", "cat"), confidence: 0.9)
      link!(cat, concept!("Q3", "CAT scan"), confidence: 0.4, method: :disambiguation)

      assert %{total: 1, rows: [%{lemma: "torpedo"}]} =
               Lexicon.browse("animals", state: :disputed)

      assert Health.conflicts("animals").count == 1
    end
  end

  describe "browse/2 the taxon filter" do
    test "selecting a node filters to the words under it", ctx do
      animalia = concept!("Q729", "Animalia")
      felidae = concept!("Q25265", "Felidae")
      felis = concept!("Q123", "Felis catus")
      wikidata = ctx.sources["wikidata"].id
      parent!(felidae, animalia, wikidata)
      parent!(felis, felidae, wikidata)

      cat = scoped!(ctx.animals, lexeme!("cat"))
      link!(cat, felis)
      oyster = scoped!(ctx.animals, lexeme!("oyster"))
      link!(oyster, concept!("Q1", "Ostreidae"))

      assert %{total: 1, rows: [%{lemma: "cat"}]} = Lexicon.browse("animals", taxon: "Q25265")
      assert %{total: 1, rows: [%{lemma: "cat"}]} = Lexicon.browse("animals", taxon: "Q729")
      assert %{total: 1, rows: [%{lemma: "cat"}]} = Lexicon.browse("animals", taxon: "Q123")
    end

    test "taxon_children/3 counts a subtree once, however many ways in", ctx do
      animalia = concept!("Q729", "Animalia")
      chordata = concept!("Q2", "Chordata")
      felidae = concept!("Q3", "Felidae")
      wikidata = ctx.sources["wikidata"].id
      parent!(chordata, animalia, wikidata)
      parent!(felidae, chordata, wikidata)
      # A DAG, not a tree: Felidae is also filed directly under Animalia, which
      # is the shape that made the naive walk count descendants twice.
      parent!(felidae, animalia, wikidata)

      cat = scoped!(ctx.animals, lexeme!("cat"))
      link!(cat, felidae)

      children = Encyclopedia.taxon_children("Q729", "animals")
      by_label = Map.new(children, &{&1.label, &1})

      assert Map.keys(by_label) |> Enum.sort() == ["Chordata", "Felidae"]
      assert by_label["Chordata"].subtree == 2
      assert by_label["Chordata"].scope_lexemes == 1
      assert by_label["Chordata"].has_children?
      assert by_label["Felidae"].subtree == 1
      refute by_label["Felidae"].has_children?
    end
  end

  describe "search/2" do
    test "a prefix beats a fuzzy match, and the shorter lemma wins", ctx do
      for lemma <- ["oyster", "oyster bed", "oystercatcher", "cat"] do
        scoped!(ctx.animals, lexeme!(lemma))
      end

      assert [%{lemma: "oyster"} | rest] = Lexicon.search("oyst")
      assert "oyster bed" in Enum.map(rest, & &1.lemma)
      refute "cat" in Enum.map(rest, & &1.lemma)
    end

    test "a misspelling still finds the word", ctx do
      scoped!(ctx.animals, lexeme!("oyster"))
      assert [%{lemma: "oyster"}] = Lexicon.search("oysster")
    end

    test "scope narrows the search, and blank finds nothing", ctx do
      scoped!(ctx.animals, lexeme!("oyster"))
      lexeme!("oysterman")

      assert length(Lexicon.search("oyster")) == 2
      assert [%{lemma: "oyster"}] = Lexicon.search("oyster", scope: "animals")
      assert Lexicon.search("  ") == []
      assert Lexicon.search(nil) == []
    end

    test "a lemma's own wildcards are not wildcards", ctx do
      scoped!(ctx.animals, lexeme!("100%"))
      scoped!(ctx.animals, lexeme!("cat"))

      # Without escaping, "100%" as a prefix pattern would match everything.
      assert [%{lemma: "100%"}] = Lexicon.search("100%")
    end
  end

  describe "random_lexemes/1 and random_word/0" do
    test "an unfiltered draw returns rows from the index, bare ones included", _ctx do
      for i <- 1..20, do: lexeme!("word#{i}", enriched_at: nil)

      drawn = Lexicon.random_lexemes(sample: 5)

      assert length(drawn) == 5
      assert Enum.all?(drawn, &(&1.slug =~ "word"))
      assert Enum.uniq_by(drawn, & &1.id) == drawn
    end

    test "an empty index draws nothing rather than raising", _ctx do
      assert Lexicon.random_lexemes(sample: 5) == []
      assert Lexicon.random_word() == nil
    end

    test "surprise me only ever lands on an enriched word inside a scope", ctx do
      # A bare row, an enriched word outside every scope, a bare word inside
      # one, and the only word that is both: *Surprise me* must find that one
      # every time, because the other three are pages with nothing on them.
      lexeme!("bareword", enriched_at: nil)
      lexeme!("quark")
      scoped!(ctx.animals, lexeme!("abrocome", enriched_at: nil))
      scoped!(ctx.animals, lexeme!("oyster"))

      for _ <- 1..20, do: assert(%{slug: "oyster"} = Lexicon.random_word())
    end

    test "a scope filter keeps the draw inside that scope", ctx do
      scoped!(ctx.animals, lexeme!("oyster"))
      lexeme!("quark")

      assert [%{slug: "oyster"}] =
               Lexicon.random_lexemes(sample: 1, scope: "animals", enriched: true)
    end
  end
end
