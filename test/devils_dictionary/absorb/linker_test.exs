defmodule DevilsDictionary.Absorb.LinkerTest do
  @moduledoc """
  Each rung and each corroboration against a small hand-built graph, so the
  expected confidence is obvious by inspection rather than by re-deriving the
  ladder.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Linker
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp lexeme!(ctx, lemma, attrs \\ []) do
    lexeme =
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: lemma,
        pos: attrs[:pos] || "noun",
        slug: Lexeme.slug(lemma),
        metadata: attrs[:metadata] || %{}
      })

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: ["wordnet_closure"]
    })

    lexeme
  end

  defp concept!(qid, attrs \\ []) do
    Repo.insert!(struct(%Concept{qid: qid, kind: attrs[:kind] || :thing}, attrs))
  end

  defp sense!(ctx, lexeme, source_slug, attrs) do
    source = ctx.sources[source_slug]

    record =
      Repo.insert!(%SourceRecord{
        source_id: source.id,
        external_id: "#{lexeme.lemma}/#{System.unique_integer([:positive])}",
        raw: %{},
        fetched_at: DateTime.utc_now()
      })

    Repo.insert!(%Sense{
      lexeme_id: lexeme.id,
      source_id: source.id,
      source_record_id: record.id,
      external_id: "#{lexeme.lemma}##{System.unique_integer([:positive])}",
      gloss: attrs[:gloss],
      metadata: attrs[:metadata] || %{}
    })
  end

  defp links(lexeme, method) do
    Repo.all(from cl in ConceptLink, where: cl.lexeme_id == ^lexeme.id and cl.method == ^method)
  end

  defp link!(lexeme, method) do
    assert [link] = links(lexeme, method)
    link
  end

  describe "the rungs" do
    test "wiktionary_qid is sense-precise at 0.95", ctx do
      cat = lexeme!(ctx, "cat")
      concept = concept!("Q146")
      sense = sense!(ctx, cat, "wiktionary", metadata: %{"wikidata" => ["Q146"]})

      assert %{rungs: %{wiktionary_qid: 1}} = Linker.run(ctx.animals)

      link = link!(cat, :wiktionary_qid)
      assert link.confidence == 0.95
      assert link.sense_id == sense.id
      assert link.concept_id == concept.id
      assert link.status == :auto
    end

    test "wordnet_wikidata reads the string form at 0.90", ctx do
      cat = lexeme!(ctx, "cat")
      concept!("Q146")
      sense!(ctx, cat, "wordnet", metadata: %{"wikidata" => "Q146", "ili" => "i1"})

      Linker.run(ctx.animals)

      assert link!(cat, :wordnet_wikidata).confidence == 0.90
    end

    test "wordnet_wikidata reads the array form too", ctx do
      # 1,887 synsets carry more than one QID (`panther` is the flagship case).
      # Rung 2 read only the string shape, so 265 scope references never linked.
      panther = lexeme!(ctx, "panther")
      concept!("Q35255")
      concept!("Q109647288")

      sense!(ctx, panther, "wordnet", metadata: %{"wikidata" => ["Q35255", "Q109647288"]})

      Linker.run(ctx.animals)

      links = Repo.all(from l in ConceptLink, where: l.lexeme_id == ^panther.id)
      assert length(links) == 2
      assert Enum.all?(links, &(&1.method == :wordnet_wikidata and &1.confidence == 0.90))
    end

    test "wordnet_ili matches the concept's P5063 at 0.85", ctx do
      cat = lexeme!(ctx, "cat")
      concept!("Q146", wordnet_ili: "i46593")
      sense!(ctx, cat, "wordnet", metadata: %{"ili" => "i46593"})

      Linker.run(ctx.animals)

      assert link!(cat, :wordnet_ili).confidence == 0.85
    end

    test "title_match links a noun to its article at 0.70, with no source", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.70
      # Nobody asserted this; we inferred it from a title.
      assert is_nil(link.source_id)
      assert is_nil(link.sense_id)
    end

    test "title_match skips a verb and skips a disambiguation page", ctx do
      verb = lexeme!(ctx, "seal", pos: "verb", metadata: %{"wikipedia_title" => "Seal"})

      noun =
        lexeme!(ctx, "seal",
          metadata: %{"wikipedia_title" => "Seal", "wikipedia_disambiguation" => true}
        )

      concept!("Q257102", wikipedia_title: "Seal", metadata: %{"disambiguation" => true})

      assert %{rungs: %{title_match: 0}} = Linker.run(ctx.animals)
      assert links(verb, :title_match) == []
      assert links(noun, :title_match) == []
    end
  end

  describe "corroboration" do
    test "a taxon whose common name is the lemma rises to 0.90", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})

      felis =
        concept!("Q20980826",
          kind: :taxon,
          taxon: %{"scientific_name" => "Felis catus", "common_names" => ["cat"]}
        )

      concept!("Q146", wikipedia_title: "Cat", taxon_concept_id: felis.id)

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.90
      assert link.metadata["corroboration"] == "taxon_name"
    end

    test "a binomial that is its own taxon also rises", ctx do
      lemma = lexeme!(ctx, "Felis catus", metadata: %{"wikipedia_title" => "Felis catus"})

      concept!("Q20980826",
        kind: :taxon,
        wikipedia_title: "Felis catus",
        taxon: %{"scientific_name" => "Felis catus", "common_names" => []}
      )

      Linker.run(ctx.animals)

      assert link!(lemma, :title_match).confidence == 0.90
    end

    test "a QID rung agreeing confirms the title match", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wordnet", metadata: %{"wikidata" => "Q146"})

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.90
      assert link.status == :confirmed
      assert link.metadata["corroboration"] == "qid_agreement"
    end

    test "a gloss sharing content words with the article rises to 0.85", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept = concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", gloss: "A domesticated carnivorous mammal.")

      Repo.insert!(%Entry{
        source_id: ctx.sources["wikipedia"].id,
        concept_id: concept.id,
        body: "The cat is a small domesticated carnivorous mammal.",
        position: 0
      })

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.85
      assert link.metadata["corroboration"] == "gloss_overlap"
    end

    test "one shared word is not enough", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept = concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", gloss: "A domesticated pet.")

      Repo.insert!(%Entry{
        source_id: ctx.sources["wikipedia"].id,
        concept_id: concept.id,
        body: "A tracked vehicle, domesticated by nobody.",
        position: 0
      })

      Linker.run(ctx.animals)

      assert link!(cat, :title_match).confidence == 0.70
    end

    test "--strict-only leaves the ladder's own numbers alone", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wordnet", metadata: %{"wikidata" => "Q146"})

      assert %{corroboration: %{}} = Linker.run(ctx.animals, skip_corroboration: true)
      assert link!(cat, :title_match).confidence == 0.70
    end
  end

  describe "disambiguation" do
    test "candidates become 0.40 candidate links, promoted to 0.60 on a gloss match", ctx do
      seal = lexeme!(ctx, "seal", metadata: %{"wikipedia_disambiguation" => true})
      concept!("Q7365", wikipedia_title: "Pinniped", description: "Marine carnivorous mammal")
      concept!("Q114414285", wikipedia_title: "BYD Seal", description: "Battery electric sedan")

      Repo.insert!(%SourceRecord{
        source_id: ctx.sources["wikipedia"].id,
        external_id: "seal",
        raw: %{
          "title" => "Seal",
          "_probe" => %{"lemma" => "seal", "lexemes" => [["en", "seal", "noun"]]},
          "_candidates" => [
            %{"title" => "Pinniped", "qid" => "Q7365"},
            %{"title" => "BYD Seal", "qid" => "Q114414285"}
          ]
        },
        fetched_at: DateTime.utc_now()
      })

      sense!(ctx, seal, "wiktionary",
        gloss: "A marine carnivorous mammal of the family Phocidae."
      )

      assert %{rungs: %{disambiguation: 2}} = Linker.run(ctx.animals)

      by_qid =
        Repo.all(
          from cl in ConceptLink,
            join: c in Concept,
            on: c.id == cl.concept_id,
            where: cl.method == :disambiguation,
            select: {c.qid, cl.confidence, cl.status}
        )
        |> Map.new(fn {qid, confidence, status} -> {qid, {confidence, status}} end)

      assert {0.60, :candidate} = by_qid["Q7365"]
      assert {0.40, :candidate} = by_qid["Q114414285"]
    end
  end

  describe "re-running" do
    test "is a no-op, not a duplicate", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", metadata: %{"wikidata" => ["Q146"]})

      Linker.run(ctx.animals)
      before = Repo.aggregate(ConceptLink, :count)

      Linker.run(ctx.animals)
      assert Repo.aggregate(ConceptLink, :count) == before
    end

    test "and it stays inside the scope it was given", ctx do
      outside = Repo.insert!(%Lexeme{lang: "en", lemma: "hammer", pos: "noun", slug: "hammer"})
      Repo.update!(Ecto.Changeset.change(outside, metadata: %{"wikipedia_title" => "Hammer"}))
      concept!("Q25294", wikipedia_title: "Hammer")

      assert %{rungs: %{title_match: 0}} = Linker.run(ctx.animals)
      assert links(outside, :title_match) == []
    end
  end
end
