defmodule DevilsDictionary.Absorb.LinkerTest do
  @moduledoc """
  Each rung and each corroboration against a small hand-built graph, so the
  expected confidence is obvious by inspection rather than by re-deriving the
  ladder.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Linker
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.{Claims, Encyclopedia, Registry, Repo, Sources}
  alias DevilsDictionary.WordFixtures

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp lexeme!(ctx, lemma, attrs \\ []) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: lemma,
        part_of_speech: attrs[:pos] || "noun",
        metadata: attrs[:metadata] || %{}
      })

    Repo.insert!(%ScopeMember{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.object_id,
      reasons: ["wordnet_closure"]
    })

    lexeme
  end

  defp concept!(qid, attrs \\ []) do
    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: attrs[:kind] || :concept,
        preferred_label: attrs[:label] || qid,
        description: attrs[:description],
        metadata:
          (attrs[:metadata] || %{})
          |> put_some("wikipedia_title", attrs[:wikipedia_title])
          |> put_some("wordnet_ili", attrs[:wordnet_ili])
          |> put_some("taxon", attrs[:taxon])
      })

    {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", qid)

    if item = attrs[:taxon_item] do
      {:ok, _} = Claims.assert(entity.object_id, "taxon_item", item.object_id)
    end

    entity
  end

  defp person!(qid, label) do
    {:ok, person} = Registry.create_person(%{preferred_label: label, description: "a person"})
    {:ok, _} = Registry.add_external_id(person.object_id, "wikidata", qid)
    person
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp sense!(ctx, lexeme, source_slug, attrs) do
    record = WordFixtures.record!(ctx, source_slug, raw: %{})

    source_record_revision_id =
      if Keyword.has_key?(attrs, :source_record_revision_id) do
        attrs[:source_record_revision_id]
      else
        revision_id(record)
      end

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: ctx.sources[source_slug].id,
        external_key: "#{lexeme.lemma}##{System.unique_integer([:positive])}",
        gloss: attrs[:gloss],
        metadata: attrs[:metadata] || %{},
        source_record_revision_id: source_record_revision_id
      })

    sense
  end

  defp revision_id(record) do
    Repo.one!(
      from r in DevilsDictionary.Corpus.SourceRecordRevision,
        where: r.source_record_id == ^record.id,
        select: r.id
    )
  end

  defp source_record_id(sense) do
    Repo.one!(
      from sr in DevilsDictionary.Registry.SenseRevision,
        join: rr in DevilsDictionary.Corpus.SourceRecordRevision,
        on: rr.id == sr.source_record_revision_id,
        where: sr.sense_id == ^sense.object_id and sr.is_current,
        select: rr.source_record_id
    )
  end

  # A link is an assertion now: rungs 1-3 write `refers_to` from the *sense*,
  # rungs 4-5 write `lexeme_entity_candidate` from the *word*. So "the links of
  # this lexeme" means both, reached through its senses where they are
  # sense-backed.
  defp links(lexeme, method) do
    sense_ids =
      Repo.all(
        from s in DevilsDictionary.Registry.Sense,
          where: s.lexeme_id == ^lexeme.object_id,
          select: s.object_id
      )

    subjects = [lexeme.object_id | sense_ids]

    Repo.all(
      from r in AssertionRevision,
        where: r.subject_object_id in ^subjects and r.is_current,
        where: r.method == ^to_string(method),
        preload: [:predicate]
    )
  end

  defp link!(lexeme, method) do
    assert [link] = links(lexeme, method)
    link
  end

  defp qid_of(object_id), do: DevilsDictionary.Encyclopedia.qid(object_id)

  # An encyclopedia's prose about a thing: a content item and an `about` claim.
  defp article!(ctx, entity, body) do
    {:ok, content} =
      Registry.create_content(%{
        content_kind: :article,
        source_id: ctx.sources["wikipedia"].id,
        body: body,
        position: 0
      })

    {:ok, _} = Claims.assert(content.object_id, "about", entity.object_id)
    content
  end

  describe "the rungs" do
    test "wiktionary_qid is sense-precise at 0.95", ctx do
      cat = lexeme!(ctx, "cat")
      concept = concept!("Q146")
      sense = sense!(ctx, cat, "wiktionary", metadata: %{"wikidata" => ["Q146"]})

      assert %{rungs: %{wiktionary_qid: 1}} = Linker.run(ctx.animals)

      link = link!(cat, :wiktionary_qid)
      assert link.confidence == 0.95
      # Sense-precise: the subject is the meaning, and the predicate says so.
      assert link.subject_object_id == sense.object_id
      assert link.predicate.key == "refers_to"
      assert link.object_object_id == concept.object_id
      # Nobody has reviewed it, which is what `auto` always meant.
      assert Claims.review_state(link.id) == :needs_review
    end

    test "wiktionary QID evidence links a sense to a non-seeded person", ctx do
      person = person!("Q424242424", "Ada Example")
      name = lexeme!(ctx, "Ada Example", pos: "name")
      sense = sense!(ctx, name, "wiktionary", metadata: %{"wikidata" => ["Q424242424"]})

      Linker.run(ctx.animals)

      link = link!(name, :wiktionary_qid)
      assert link.subject_object_id == sense.object_id
      assert link.object_object_id == person.object_id
      assert link.predicate.key == "refers_to"
    end

    test "name-only heuristics neither create nor preserve person candidates", ctx do
      bierce = person!("Q424242425", "Ambrose Example")

      ursus =
        lexeme!(ctx, "Ursus",
          metadata: %{
            "wikipedia_disambiguation" => true,
            "wikipedia_title" => "Ambrose Example"
          }
        )

      {:ok, stale} =
        Claims.assert(ursus.object_id, "lexeme_entity_candidate", bierce.object_id, %{
          method: "disambiguation",
          confidence: 0.4
        })

      assert %{retired_unevidenced_people: 1} = Linker.run(ctx.animals)
      assert Claims.outgoing(ursus.object_id, predicate: "lexeme_entity_candidate") == []
      assert Claims.current_revision(stale.id).lifecycle_state == :withdrawn
    end

    test "wordnet_wikidata reads the string form at 0.90", ctx do
      cat = lexeme!(ctx, "cat")
      concept!("Q146")
      sense!(ctx, cat, "wordnet", metadata: %{"wikidata" => "Q146", "ili" => "i1"})

      Linker.run(ctx.animals)

      assert link!(cat, :wordnet_wikidata).confidence == 0.90
    end

    test "explicit evidence selection treats out-of-scope people and works alike", ctx do
      # These are the real catalog identities, not name-matched stand-ins.
      person = Encyclopedia.by_qid!("Q191050")
      work = Encyclopedia.by_qid!("Q1197843")

      {:ok, name} =
        Registry.create_lexeme(%{
          language_tag: "en",
          lemma: "Ambrose Bierce",
          part_of_speech: "noun",
          metadata: %{}
        })

      {:ok, title} =
        Registry.create_lexeme(%{
          language_tag: "en",
          lemma: "The Devil's Dictionary",
          part_of_speech: "noun",
          metadata: %{}
        })

      person_sense =
        sense!(ctx, name, "wordnet", metadata: %{"wikidata" => "Q191050", "ili" => "i94474"})

      work_sense =
        sense!(ctx, title, "wordnet", metadata: %{"wikidata" => "Q1197843", "ili" => "i94475"})

      # Scope membership, never entity kind, bounds an ordinary run.
      assert %{rungs: %{wordnet_wikidata: 0}} = Linker.run(ctx.animals)
      assert links(name, :wordnet_wikidata) == []
      assert links(title, :wordnet_wikidata) == []

      person_record_id = source_record_id(person_sense)
      person_run = Sources.start_run("link_selected")

      assert %{rungs: %{wordnet_wikidata: 1}} =
               Linker.run_selected(%{source_record_ids: [person_record_id]},
                 run_id: person_run.id
               )

      work_run = Sources.start_run("link_selected")

      assert %{rungs: %{wordnet_wikidata: 1}} =
               Linker.run_selected(%{entity_ids: [work.object_id]}, run_id: work_run.id)

      link = link!(name, :wordnet_wikidata)
      assert link.subject_object_id == person_sense.object_id
      assert link.object_object_id == person.object_id
      assert link.predicate.key == "refers_to"
      assert link.metadata["evidence"] == "sense_metadata_wikidata"
      assert link.metadata["wikidata_qid"] == "Q191050"
      assert is_integer(link.metadata["source_record_id"])

      work_link = link!(title, :wordnet_wikidata)
      assert work_link.subject_object_id == work_sense.object_id
      assert work_link.object_object_id == work.object_id
      assert work_link.predicate.key == "refers_to"

      output =
        Repo.one!(
          from o in "source_assertion_outputs",
            where: o.assertion_id == ^link.assertion_id,
            select: %{
              source_record_id: o.source_record_id,
              last_seen_run_id: o.last_seen_run_id
            }
        )

      assert output.source_record_id == link.metadata["source_record_id"]
      assert output.last_seen_run_id == person_run.id

      before = length(Claims.history(work_link.assertion_id))
      rerun = Sources.start_run("link_selected")
      Linker.run_selected(%{lexeme_ids: [title.object_id]}, run_id: rerun.id)

      assert length(Claims.history(work_link.assertion_id)) == before

      assert Repo.one!(
               from o in "source_assertion_outputs",
                 where: o.assertion_id == ^work_link.assertion_id,
                 select: o.last_seen_run_id
             ) == rerun.id
    end

    test "missing and oversized populations cannot become global crawls" do
      assert_raise ArgumentError, ~r/requires a scope/, fn -> Linker.run(nil) end
      assert_raise ArgumentError, ~r/at least one ID/, fn -> Linker.run_selected(%{}) end

      assert_raise ArgumentError, ~r/exceeds 500 IDs/, fn ->
        Linker.run_selected(%{entity_ids: Enum.to_list(1..501)})
      end
    end

    test "wordnet_wikidata reads the array form too", ctx do
      # 1,887 synsets carry more than one QID (`panther` is the flagship case).
      # Rung 2 read only the string shape, so 265 scope references never linked.
      panther = lexeme!(ctx, "panther")
      concept!("Q35255")
      concept!("Q109647288")

      sense!(ctx, panther, "wordnet", metadata: %{"wikidata" => ["Q35255", "Q109647288"]})

      Linker.run(ctx.animals)

      links = links(panther, :wordnet_wikidata)
      assert length(links) == 2
      assert Enum.all?(links, &(&1.confidence == 0.90))
    end

    test "wordnet_ili matches the concept's P5063 at 0.85", ctx do
      cat = lexeme!(ctx, "cat")
      concept!("Q146", wordnet_ili: "i46593")
      sense!(ctx, cat, "wordnet", metadata: %{"ili" => "i46593"})

      Linker.run(ctx.animals)

      assert link!(cat, :wordnet_ili).confidence == 0.85
    end

    test "identifier rungs retain senses without source-record provenance", ctx do
      entity = concept!("Q424242428", wordnet_ili: "i424242428")
      wiktionary_word = lexeme!(ctx, "provenance-free Wiktionary")
      wordnet_word = lexeme!(ctx, "provenance-free WordNet")

      sense!(ctx, wiktionary_word, "wiktionary",
        metadata: %{"wikidata" => ["Q424242428"]},
        source_record_revision_id: nil
      )

      sense!(ctx, wordnet_word, "wordnet",
        metadata: %{"wikidata" => "Q424242428", "ili" => "i424242428"},
        source_record_revision_id: nil
      )

      assert %{
               rungs: %{wiktionary_qid: 1, wordnet_wikidata: 1, wordnet_ili: 1}
             } = Linker.run(ctx.animals)

      for {word, method} <- [
            {wiktionary_word, :wiktionary_qid},
            {wordnet_word, :wordnet_wikidata},
            {wordnet_word, :wordnet_ili}
          ] do
        link = link!(word, method)
        assert link.object_object_id == entity.object_id
        assert link.metadata["source_record_id"] == nil
      end
    end

    test "title_match links a noun to its article at 0.70, with no source", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.70
      # We inferred this from a spelling, so it is a word-level candidate and
      # never sense equivalence: the subject is the lexeme, not a meaning.
      assert link.subject_object_id == cat.object_id
      assert link.predicate.key == "lexeme_entity_candidate"
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

      concept!("Q146", wikipedia_title: "Cat", taxon_item: felis)

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
      assert link.metadata["corroboration"] == "qid_agreement"

      # MVP-0 also wrote `status: :confirmed` here. #74 asks for that policy not
      # to be preserved blindly: two methods agreeing is evidence, not an
      # editorial decision, and nobody performed a review.
      assert Claims.review_state(link.id) == :needs_review
    end

    test "a gloss sharing content words with the article rises to 0.85", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept = concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", gloss: "A domesticated carnivorous mammal.")

      article!(ctx, concept, "The cat is a small domesticated carnivorous mammal.")

      Linker.run(ctx.animals)

      link = link!(cat, :title_match)
      assert link.confidence == 0.85
      assert link.metadata["corroboration"] == "gloss_overlap"
    end

    test "one shared word is not enough", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept = concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", gloss: "A domesticated pet.")

      article!(ctx, concept, "A tracked vehicle, domesticated by nobody.")

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

      WordFixtures.record!(ctx, "wikipedia",
        external_id: "seal",
        raw: %{
          "title" => "Seal",
          "_probe" => %{"lemma" => "seal", "lexemes" => [["en", "seal", "noun"]]},
          "_candidates" => [
            %{"title" => "Pinniped", "qid" => "Q7365"},
            %{"title" => "BYD Seal", "qid" => "Q114414285"}
          ]
        }
      )

      sense!(ctx, seal, "wiktionary",
        gloss: "A marine carnivorous mammal of the family Phocidae."
      )

      assert %{rungs: %{disambiguation: 2}} = Linker.run(ctx.animals)

      by_qid =
        seal
        |> links(:disambiguation)
        |> Map.new(&{qid_of(&1.object_object_id), &1.confidence})

      # Both sit below `Encyclopedia.asserted_floor/0`, which is what keeps a
      # possibility out of the populations A10 and L3 report on. Promotion
      # reorders the "may refer to" panel; it does not make a claim.
      assert by_qid["Q7365"] == 0.60
      assert by_qid["Q114414285"] == 0.40
      assert by_qid["Q7365"] < DevilsDictionary.Encyclopedia.asserted_floor()
    end
  end

  describe "re-running" do
    test "is a no-op, not a duplicate", ctx do
      cat = lexeme!(ctx, "cat", metadata: %{"wikipedia_title" => "Cat"})
      concept!("Q146", wikipedia_title: "Cat")
      sense!(ctx, cat, "wiktionary", metadata: %{"wikidata" => ["Q146"]})

      Linker.run(ctx.animals)
      before = Repo.aggregate(AssertionRevision, :count)

      # Not merely "no duplicate rows": no new *revision* either. A rerun that
      # finds the same evidence has nothing to say.
      Linker.run(ctx.animals)

      assert Repo.aggregate(AssertionRevision, :count) == before
    end

    test "heuristic inference stays inside the scope it was given", ctx do
      {:ok, outside} =
        Registry.create_lexeme(%{
          language_tag: "en",
          lemma: "hammer",
          part_of_speech: "noun",
          metadata: %{"wikipedia_title" => "Hammer"}
        })

      concept!("Q25294", wikipedia_title: "Hammer")

      assert %{rungs: %{title_match: 0}} = Linker.run(ctx.animals)
      assert links(outside, :title_match) == []
    end
  end
end
