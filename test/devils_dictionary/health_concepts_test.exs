defmodule DevilsDictionary.HealthConceptsTest do
  @moduledoc """
  The S2 scorecard rows — A6, A7, A10 and L1–L4 — each against a small
  hand-built graph, so the expected number is obvious by inspection rather than
  by re-deriving it from the same query under test.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.{Fixtures, Health, Repo}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp scoped!(ctx, lemma, attrs \\ []) do
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: lemma,
        pos: "noun",
        slug: Lexeme.slug(lemma),
        metadata: attrs[:metadata] || %{},
        source_ids: attrs[:source_ids] || []
      })

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: ["wordnet_closure"]
    })

    lexeme
  end

  defp concept!(qid, attrs \\ []),
    do: Repo.insert!(struct(%Concept{qid: qid, kind: attrs[:kind] || :thing}, attrs))

  defp link!(lexeme, concept, attrs) do
    Repo.insert!(%ConceptLink{
      lexeme_id: lexeme.id,
      concept_id: concept.id,
      method: attrs[:method] || :title_match,
      confidence: attrs[:confidence],
      status: attrs[:status] || :auto,
      metadata: attrs[:metadata] || %{}
    })
  end

  defp entry!(ctx, concept, body \\ "A thing.") do
    Repo.insert!(%Entry{
      source_id: ctx.sources["wikipedia"].id,
      concept_id: concept.id,
      body: body,
      position: 0
    })
  end

  defp parent!(ctx, child, parent) do
    Repo.insert!(%ConceptRelation{
      source_id: ctx.sources["wikidata"].id,
      from_concept_id: child.id,
      to_concept_id: parent.id,
      type: :parent_taxon,
      property: "P171"
    })
  end

  describe "concept_coverage/1 (A6)" do
    test "a QID named by a link with no concepts row is a dangling reference", ctx do
      cat = scoped!(ctx, "cat")
      concept = concept!("Q146")
      link!(cat, concept, confidence: 0.9)

      assert %{referenced_qids: 1, dangling: 0, pct: 100.0} = Health.concept_coverage("animals")
    end

    test "reports the Wiktionary/Wikidata union the amended row asks for", ctx do
      wiktionary = ctx.sources["wiktionary"].id

      # Covered by Wiktionary only.
      scoped!(ctx, "cat", source_ids: [wiktionary])
      # Covered by Wikidata only — a binomial, which is exactly the set A5 can
      # never reach because Wiktionary files it as Translingual.
      binomial = scoped!(ctx, "Felis catus")
      link!(binomial, concept!("Q20980826"), confidence: 0.9)
      # Covered by neither.
      scoped!(ctx, "soup-fin")

      coverage = Health.concept_coverage("animals")

      assert coverage.scope_total == 3
      assert coverage.wiktionary == 1
      assert coverage.wikidata_linked == 1
      assert coverage.union == 2
      assert coverage.union_pct == 66.7
    end
  end

  describe "wikipedia_coverage/0 (A7)" do
    test "counts concepts with an article that have no entry", ctx do
      with_entry = concept!("Q146", wikipedia_title: "Cat")
      entry!(ctx, with_entry)
      concept!("Q144", wikipedia_title: "Dog")
      # No article at all, so not part of the denominator.
      concept!("Q20980826", kind: :taxon)

      assert %{with_sitelink: 2, with_entry: 1, answered: 1, missing: 1, pct: 50.0} =
               Health.wikipedia_coverage()
    end

    test "a disambiguation page counts as answered without an entry", ctx do
      concept!("Q257102", wikipedia_title: "Seal")

      # The concept pass asked and got "Seal may refer to…", which is not an
      # article about a seal — so no entry, and the row must not read that as a
      # concept we never looked at.
      Repo.insert!(%DevilsDictionary.Sources.SourceRecord{
        source_id: ctx.sources["wikipedia"].id,
        external_id: "concept:Q257102",
        raw: %{},
        fetched_at: DateTime.utc_now()
      })

      assert %{with_sitelink: 1, with_entry: 0, answered: 1, pct: 100.0} =
               Health.wikipedia_coverage()
    end
  end

  describe "images/1 (A10)" do
    test "measured over the concepts the scope's words actually link to", ctx do
      cat = scoped!(ctx, "cat")
      dog = scoped!(ctx, "dog")

      with_image = concept!("Q146", image_url: "https://example.test/cat.jpg")
      without = concept!("Q144")
      link!(cat, with_image, confidence: 0.9)
      link!(dog, without, confidence: 0.9)
      entry!(ctx, with_image)
      entry!(ctx, without)

      # A disambiguation candidate with an entry and no picture. *Cherry Bomb
      # (album)* having none says nothing about whether *cat* does, so it stays
      # out of the numerator and the denominator.
      candidate = concept!("Q114414285")
      entry!(ctx, candidate)
      link!(cat, candidate, method: :disambiguation, confidence: 0.4, status: :candidate)

      images = Health.images("animals")

      assert images.asserted == 2
      assert images.asserted_with_image == 1
      assert images.pct == 50.0

      # The wider figures are still reported, and the candidate drags them down.
      assert images.with_entry == 3
      assert images.entry_pct == 33.3
    end
  end

  describe "links/2 (L1)" do
    test "reports the rate twice: strict ladder, and after corroboration", ctx do
      qid_linked = scoped!(ctx, "cat")
      title_only = scoped!(ctx, "aardvark")
      corroborated = scoped!(ctx, "oyster")
      scoped!(ctx, "soup-fin")

      link!(qid_linked, concept!("Q146"), method: :wordnet_wikidata, confidence: 0.9)
      link!(title_only, concept!("Q46212"), method: :title_match, confidence: 0.7)

      link!(corroborated, concept!("Q5375540"),
        method: :title_match,
        confidence: 0.9,
        metadata: %{"corroboration" => "taxon_name"}
      )

      links = Health.links("animals", 0.8)

      assert links.scope_total == 4
      # Both the QID rung and the corroborated title match clear the bar.
      assert links.linked == 2
      assert links.pct == 50.0
      # Strict counts only what the ladder's own confidences reach.
      assert links.strict_linked == 1
      assert links.strict_pct == 25.0
      assert links.any_linked == 3
      assert links.corroboration == %{"taxon_name" => 1}
    end
  end

  describe "conflicts/3 (L2)" do
    test "one lexeme with two confident concepts is surfaced, not resolved", ctx do
      cat = scoped!(ctx, "cat")
      link!(cat, concept!("Q146"), confidence: 0.9)
      link!(cat, concept!("Q1319482"), confidence: 0.85)

      # A single confident link is no conflict.
      dog = scoped!(ctx, "dog")
      link!(dog, concept!("Q144"), confidence: 0.9)

      assert %{count: 1, sample: [%{lemma: "cat", concepts: 2}]} = Health.conflicts("animals")
    end

    test "a low-confidence second candidate is not a conflict", ctx do
      cat = scoped!(ctx, "cat")
      link!(cat, concept!("Q146"), confidence: 0.9)
      link!(cat, concept!("Q1319482"), method: :disambiguation, confidence: 0.4)

      assert %{count: 0} = Health.conflicts("animals")
    end
  end

  describe "taxonomy/2 (L3)" do
    test "walks parent_taxon, and reaches through the everyday concept's taxon item", ctx do
      animalia = concept!("Q729", kind: :taxon)
      felis = concept!("Q20980826", kind: :taxon)
      parent!(ctx, felis, animalia)

      # `cat` links to the everyday concept, which reaches Animalia only via
      # `taxon_concept_id` — the case §3's rule keeps getting wrong.
      cat = scoped!(ctx, "cat")
      link!(cat, concept!("Q146", taxon_concept_id: felis.id), confidence: 0.9)

      # A concept with no taxonomy at all.
      hammer = scoped!(ctx, "hammer")
      link!(hammer, concept!("Q25294"), confidence: 0.9)

      assert %{linked_concepts: 2, reaching_root: 1, pct: 50.0} = Health.taxonomy("animals")
    end

    test "a disambiguation candidate is not a link we assert", ctx do
      animalia = concept!("Q729", kind: :taxon)
      felis = concept!("Q20980826", kind: :taxon)
      parent!(ctx, felis, animalia)

      seal = scoped!(ctx, "seal")
      link!(seal, felis, confidence: 0.9)
      # A scope carries ~19,000 candidates and none of them was ever going to be
      # a taxon; counting them drags L3 down for no reason.
      link!(seal, concept!("Q114414285"),
        method: :disambiguation,
        confidence: 0.4,
        status: :candidate
      )

      taxonomy = Health.taxonomy("animals")

      assert taxonomy.linked_concepts == 1
      assert taxonomy.pct == 100.0
      assert taxonomy.with_candidates == 2
      assert taxonomy.with_candidates_pct == 50.0
    end
  end

  describe "disambiguation/1 (L4)" do
    test "every hit must have stored candidates", ctx do
      seal = scoped!(ctx, "seal", metadata: %{"wikipedia_disambiguation" => true})
      link!(seal, concept!("Q7365"), method: :disambiguation, confidence: 0.6, status: :candidate)

      link!(seal, concept!("Q114414285"),
        method: :disambiguation,
        confidence: 0.4,
        status: :candidate
      )

      # A hit whose candidates were never stored is the failure this row exists
      # to catch.
      scoped!(ctx, "crane", metadata: %{"wikipedia_disambiguation" => true})

      assert %{hits: 2, with_candidates: 1, pct: 50.0, candidates: 2, promoted: 1} =
               Health.disambiguation("animals")
    end

    test "counts lemmas, so a verb does not read as a hit with no candidates", ctx do
      seal = scoped!(ctx, "seal", metadata: %{"wikipedia_disambiguation" => true})

      # The probe flags every lexeme of the lemma, but the candidate rung links
      # nouns only. Counting lexemes would score this lemma 1 of 2.
      verb =
        Repo.insert!(%Lexeme{
          lang: "en",
          lemma: "seal",
          pos: "verb",
          slug: "seal",
          metadata: %{"wikipedia_disambiguation" => true}
        })

      Repo.insert!(%ScopeLexeme{
        scope_id: ctx.animals.id,
        lexeme_id: verb.id,
        reasons: ["wordnet_closure"]
      })

      link!(seal, concept!("Q7365"), method: :disambiguation, confidence: 0.4, status: :candidate)

      assert %{hits: 1, with_candidates: 1, pct: 100.0} = Health.disambiguation("animals")
    end

    test "a lemma with no nominal lexeme is explained, not counted as a shortfall", ctx do
      # A thing is not an adjective, so `formic` can never carry a candidate.
      # Eleven Animals lemmas are like this; L4 says so rather than reading 99%.
      adjective =
        Repo.insert!(%Lexeme{
          lang: "en",
          lemma: "formic",
          pos: "adj",
          slug: "formic",
          metadata: %{"wikipedia_disambiguation" => true}
        })

      Repo.insert!(%ScopeLexeme{
        scope_id: ctx.animals.id,
        lexeme_id: adjective.id,
        reasons: ["wiktionary_category"]
      })

      seal = scoped!(ctx, "seal", metadata: %{"wikipedia_disambiguation" => true})
      link!(seal, concept!("Q7365"), method: :disambiguation, confidence: 0.4, status: :candidate)

      health = Health.disambiguation("animals")

      assert health.hits == 2
      assert health.with_candidates == 1
      assert health.non_nominal == 1
      assert health.nominal_pct == 100.0
    end
  end
end
