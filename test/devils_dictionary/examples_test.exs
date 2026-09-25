defmodule DevilsDictionary.ExamplesTest do
  @moduledoc """
  The instance layer of a word's examples (#181 build 1): what
  `Examples.for_page/3` reads, how it folds edges into things, and the two
  contracts its section rests on — a layer is data (C2) and signals never
  cross (C3).
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Claims, Examples, Fixtures, Lexicon, Repo}
  alias DevilsDictionary.Examples.Rank
  alias DevilsDictionary.Lexicon.WordPage

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp page(word), do: word |> Lexicon.lookup() |> WordPage.build()

  # A WordNet sense of `lemma` in synset `synset`.
  defp wn_sense!(ctx, lemma, synset, gloss \\ nil) do
    lexeme = word!(ctx, lemma, ~w(wordnet))

    sense =
      sense!(ctx, lexeme, "wordnet", group_key: synset, gloss: gloss || "#{lemma} (#{synset})")

    {lexeme, sense}
  end

  # WordNet's instance edge: the named thing's sense → the class's sense.
  defp instance!(ctx, {lexeme, sense}, {_class, class_sense}) do
    relation!(ctx, lexeme, :instance_of, nil,
      source: "wordnet",
      from_sense: sense,
      to_sense: class_sense
    )
  end

  defp labels(examples), do: Enum.map(examples.items, & &1.subject.label)

  describe "WordNet's instances" do
    setup ctx do
      Map.put(
        ctx,
        :dictator,
        wn_sense!(ctx, "dictator", "oewn-dictator-n", "a ruler unconstrained by law")
      )
    end

    test "a synset's name leads its description: Holocaust, not final solution", ctx do
      genocide = wn_sense!(ctx, "genocide", "oewn-genocide-n", "systematic killing of a group")

      for lemma <- ["final solution", "Holocaust"] do
        instance!(ctx, wn_sense!(ctx, lemma, "oewn-holocaust-n"), genocide)
      end

      [holocaust] = page("genocide").examples.items
      assert holocaust.subject.label == "Holocaust"
      assert holocaust.subject.aliases == ["final solution"]
    end

    test "one chip per synset, labelled by its fullest member", ctx do
      # WordNet files every member of Hitler's synset under dictator.
      for lemma <- ["Hitler", "Adolf Hitler", "Der Fuhrer"] do
        instance!(ctx, wn_sense!(ctx, lemma, "oewn-hitler-n"), ctx.dictator)
      end

      instance!(ctx, wn_sense!(ctx, "Tojo", "oewn-tojo-n"), ctx.dictator)

      examples = page("dictator").examples

      assert labels(examples) == ["Adolf Hitler", "Tojo"]
      assert examples.totals == %{instance: 2, exemplar: 0}

      [hitler, _tojo] = examples.items
      assert hitler.subject.slug == "adolf-hitler"
      assert Enum.sort(hitler.subject.aliases) == ["Der Fuhrer", "Hitler"]
      assert hitler.layer == :instance
      assert hitler.claim == nil
      assert hitler.target.gloss == "a ruler unconstrained by law"
      assert [%{slug: "wordnet", kind: :sense, assertion_ids: [_, _, _]}] = hitler.sources

      assert hitler.reason ==
               "Open English WordNet 2025 names it under “a ruler unconstrained by law”."
    end

    test "the edges never become the word's related chips", ctx do
      instance!(ctx, wn_sense!(ctx, "Tojo", "oewn-tojo-n"), ctx.dictator)

      page = page("dictator")

      assert page.related == nil

      assert Enum.all?(page.cards, fn card ->
               Enum.all?(card.groups, fn group ->
                 Enum.all?(group.senses, &(&1.relations == %{}))
               end)
             end)
    end

    test "the named thing's own page keeps the edge as its relation", ctx do
      instance!(ctx, wn_sense!(ctx, "Tojo", "oewn-tojo-n"), ctx.dictator)

      page = page("tojo")

      assert page.examples.items == []

      assert [%{relations: %{related: %{shown: [%{lemma: "dictator"}]}}}] =
               Enum.flat_map(page.cards, fn card -> Enum.flat_map(card.groups, & &1.senses) end)
    end

    test "a rejected instance is gone for every reader of the page", ctx do
      assertion = instance!(ctx, wn_sense!(ctx, "Judas", "oewn-judas-n"), ctx.dictator)
      {:ok, _} = Claims.review(Claims.current_revision(assertion.id).id, :rejected)

      {dictator, _sense} = ctx.dictator

      # The record reads as the public reads it, whoever is looking: a
      # reviewer finds the rejected edge on `/connections/:id`, not as a chip.
      assert Examples.for_page([dictator.object_id]).items == []
      assert Examples.for_page([dictator.object_id], :internal).items == []
    end

    test "standalone, it reads what the page read", ctx do
      instance!(ctx, wn_sense!(ctx, "Tojo", "oewn-tojo-n"), ctx.dictator)
      {dictator, _sense} = ctx.dictator

      assert Examples.for_page([dictator.object_id]) == page("dictator").examples
    end
  end

  describe "corroboration" do
    setup ctx do
      war = word!(ctx, "war", ~w(wordnet wiktionary))
      wordnet_war = sense!(ctx, war, "wordnet", group_key: "oewn-war-n", gloss: "armed conflict")
      wiktionary_war = sense!(ctx, war, "wiktionary", gloss: "organised violence")
      q198 = concept!("Q198", "war")
      link!(war, q198, sense: wiktionary_war)

      Map.merge(ctx, %{war: {war, wordnet_war}, q198: q198})
    end

    test "WordNet and Wikidata naming one thing make one chip with both sources", ctx do
      {_lexeme, sense} = korean = wn_sense!(ctx, "Korean War", "oewn-korean-war-n")
      q8663 = concept!("Q8663", "Korean War")
      link!(elem(korean, 0), q8663, sense: sense, method: :wordnet_ili)

      instance!(ctx, korean, ctx.war)
      concept_relation!(ctx, q8663, :instance_of, ctx.q198)

      # And one each, alone.
      instance!(ctx, wn_sense!(ctx, "Boer War", "oewn-boer-war-n"), ctx.war)
      concept_relation!(ctx, concept!("Q1", "Pig War"), :instance_of, ctx.q198)

      examples = page("war").examples

      assert labels(examples) == ["Korean War", "Boer War", "Pig War"]

      [korean_war, boer, pig] = examples.items
      assert korean_war.id == "inst:e#{q8663.object_id}"
      assert korean_war.signals.source_count == 2
      assert Enum.map(korean_war.sources, & &1.slug) == ["wikidata", "wordnet"]
      assert korean_war.subject.kind == :lexeme

      assert korean_war.reason ==
               "Wikidata files it as an instance of war; Open English WordNet 2025 names it under “armed conflict”."

      assert boer.signals.source_count == 1
      # No word refers to it, so the chip is the thing's own page.
      assert pig.subject == %{pig.subject | kind: :entity, slug: nil, label: "Pig War"}
      assert pig.target.kind == :entity

      assert [
               %{slug: "wikidata", kind: :entity, count: 2, words: 1, classes: ["war"]},
               %{slug: "wordnet", kind: :sense, count: 2, words: 2}
             ] = examples.sources
    end

    # `entities.preferred_label` is nullable; the materializer writes what the
    # source gave. A nil label reached `Rank` and raised, taking the whole
    # page with it (CodeRabbit on #183).
    test "an instance without a label is named by its QID, or left out", ctx do
      unlabeled = concept!("Q42", "placeholder")
      nameless = concept!(nil, "placeholder")

      for thing <- [unlabeled, nameless] do
        concept_relation!(ctx, thing, :instance_of, ctx.q198)
      end

      Repo.update_all(
        from(e in DevilsDictionary.Registry.Entity,
          where: e.object_id in ^[unlabeled.object_id, nameless.object_id]
        ),
        set: [preferred_label: nil]
      )

      examples = page("war").examples

      assert labels(examples) == ["Q42"]
      assert [%{subject: %{kind: :entity, slug: nil}}] = examples.items
    end

    test "a synset naming two things does not merge on either", ctx do
      {lexeme, sense} = gulf = wn_sense!(ctx, "Gulf War", "oewn-gulf-war-n")
      q1 = concept!("Q10", "Gulf War")
      link!(lexeme, q1, sense: sense, method: :wordnet_ili)
      link!(lexeme, concept!("Q11", "Iran–Iraq War"), sense: sense, method: :wordnet_ili)

      instance!(ctx, gulf, ctx.war)
      concept_relation!(ctx, q1, :instance_of, ctx.q198)

      assert page("war").examples.items |> Enum.map(& &1.signals.source_count) == [1, 1]
    end
  end

  test "a word nothing names has no examples", ctx do
    word!(ctx, "logomachy", ~w(wordnet))

    assert %{items: [], totals: %{instance: 0, exemplar: 0}, sources: []} =
             page("logomachy").examples
  end

  describe "Rank.order/1" do
    defp item(id, label, signals, layer \\ :instance) do
      %{
        id: id,
        layer: layer,
        subject: %{label: label},
        signals:
          Map.merge(
            %{source_count: 1, best_tier: :middle, human_up: 0, human_down: 0, evidence_count: 0},
            signals
          )
      }
    end

    test "instances by source count, then tier, then label" do
      items = [
        item("a", "Zulu War", %{}),
        item("b", "Boer War", %{}),
        item("c", "Korean War", %{source_count: 2}),
        item("d", "Aachen", %{best_tier: :plebs}),
        item("e", "Crimean War", %{best_tier: :aristocracy})
      ]

      assert Enum.map(Rank.order(items), & &1.id) == ~w(c e b a d)
    end

    # C3: a vote is an exemplar's signal. On an instance it is not read.
    test "a fabricated vote on an instance does not reorder it" do
      plain = [item("a", "Boer War", %{}), item("b", "Crimean War", %{})]

      voted = [
        item("a", "Boer War", %{}),
        item("b", "Crimean War", %{human_up: 500, featured_at: ~U[2026-09-01 00:00:00Z]})
      ]

      assert Enum.map(Rank.order(voted), & &1.id) == Enum.map(Rank.order(plain), & &1.id)
    end

    test "exemplars come first, featured, then by net votes" do
      items = [
        item("i", "Boer War", %{source_count: 9}),
        item("x1", "Bezos", %{human_up: 1}, :exemplar),
        item("x2", "Franco", %{human_up: 5}, :exemplar),
        item("x3", "Tojo", %{featured_at: ~U[2026-09-01 00:00:00Z]}, :exemplar)
      ]

      assert Enum.map(Rank.order(items), & &1.id) == ~w(x3 x2 x1 i)
    end

    test "an item without a layer is refused" do
      assert_raise FunctionClauseError, fn ->
        Rank.order([%{id: "?", subject: %{label: "?"}, signals: %{}}])
      end
    end
  end

  describe "check/1 (C2)" do
    test "an instance is sourced and carries no claim" do
      instance = %{layer: :instance, claim: nil, sources: [%{slug: "wordnet"}], reason: "…."}

      assert Examples.check(instance) == :ok
      assert {:error, _} = Examples.check(%{instance | claim: %{rationale: "because"}})
      assert {:error, _} = Examples.check(%{instance | sources: []})
    end

    test "an exemplar has a rationale" do
      assert Examples.check(%{layer: :exemplar, claim: %{rationale: "Ruled Spain"}}) == :ok
      assert {:error, _} = Examples.check(%{layer: :exemplar, claim: %{rationale: ""}})
      assert {:error, _} = Examples.check(%{layer: :exemplar, claim: nil})
    end

    test "an item without a layer is neither" do
      assert Examples.check(%{claim: nil, sources: [%{}]}) == {:error, :no_layer}
    end
  end
end
