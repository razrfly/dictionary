defmodule DevilsDictionary.Absorb.ScopeBuilderTest do
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.ScopeBuilder
  alias DevilsDictionary.Lexicon.{Lexeme, LexicalRelation, Scope, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  # A five-synset slice shaped like WordNet's: animal -> mammal -> {cat, dog},
  # plus rock hanging off nothing, so the closure has something to exclude.
  @graph %{
    "oewn-animal-n" => {"animal", nil},
    "oewn-mammal-n" => {"mammal", "oewn-animal-n"},
    "oewn-cat-n" => {"cat", "oewn-mammal-n"},
    "oewn-dog-n" => {"dog", "oewn-mammal-n"},
    "oewn-rock-n" => {"rock", nil}
  }

  defp wordnet! do
    Repo.insert!(%Source{
      slug: "wordnet",
      name: "Open English WordNet",
      tier: :middle,
      kind: :lexical_db,
      access: :dump
    })
  end

  defp build_graph(source) do
    senses =
      Map.new(@graph, fn {group_key, {lemma, _parent}} ->
        lexeme =
          Repo.insert!(%Lexeme{lang: "en", lemma: lemma, pos: "noun", slug: lemma})

        sense =
          Repo.insert!(%Sense{
            lexeme_id: lexeme.id,
            source_id: source.id,
            external_id: "#{group_key}##{lemma}",
            group_key: group_key,
            gloss: "a #{lemma}"
          })

        {group_key, {lexeme, sense}}
      end)

    # The absorb stores both directions; the closure walks the derived :hyponym.
    for {group_key, {_lemma, parent}} <- @graph, parent != nil do
      {_, parent_sense} = senses[parent]
      {child_lexeme, child_sense} = senses[group_key]
      {parent_lexeme, _} = senses[parent]

      Repo.insert!(%LexicalRelation{
        source_id: source.id,
        from_lexeme_id: parent_lexeme.id,
        from_sense_id: parent_sense.id,
        to_lemma: child_lexeme.lemma,
        to_group_key: group_key,
        type: :hyponym
      })

      Repo.insert!(%LexicalRelation{
        source_id: source.id,
        from_lexeme_id: child_lexeme.id,
        from_sense_id: child_sense.id,
        to_lemma: parent_lexeme.lemma,
        to_group_key: parent,
        type: :hypernym
      })
    end

    senses
  end

  defp scope!(rules) do
    Repo.insert!(%Scope{slug: "animals", name: "Animals", rules: rules})
  end

  defp members(scope) do
    Repo.all(
      from sl in ScopeLexeme,
        join: l in Lexeme,
        on: l.id == sl.lexeme_id,
        where: sl.scope_id == ^scope.id,
        select: l.lemma,
        order_by: l.lemma
    )
  end

  describe "wordnet_closure" do
    test "walks the derived hyponym edges down from the root" do
      source = wordnet!()
      build_graph(source)
      scope = scope!(%{"wordnet_roots" => ["oewn-animal-n"]})

      result = ScopeBuilder.build(scope)

      assert members(scope) == ~w(animal cat dog mammal)
      refute "rock" in members(scope)
      assert result.rules["wordnet_closure"]["status"] == "ok"
    end

    test "records the reason on every row" do
      source = wordnet!()
      build_graph(source)
      scope = scope!(%{"wordnet_roots" => ["oewn-animal-n"]})

      result = ScopeBuilder.build(scope)

      assert result.without_reason == 0
      assert result.reasons["wordnet_closure"] == 4
    end

    test "skips rather than silently matching nothing when no root is pinned" do
      wordnet!()
      scope = scope!(%{})

      result = ScopeBuilder.build(scope)

      assert result.rules["wordnet_closure"]["status"] == "skipped"
      assert result.total == 0
    end
  end

  describe "wiktionary_category" do
    test "matches the categories the index pass wrote onto the lexeme" do
      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: "corvid",
        pos: "noun",
        slug: "corvid",
        metadata: %{"wikt_categories" => ["en:Corvids", "en:Birds"]}
      })

      Repo.insert!(%Lexeme{
        lang: "en",
        lemma: "hammer",
        pos: "noun",
        slug: "hammer",
        metadata: %{"wikt_categories" => ["en:Tools"]}
      })

      scope = scope!(%{"wiktionary_categories" => ["en:Birds"]})

      ScopeBuilder.build(scope)

      assert members(scope) == ["corvid"]
    end

    test "skips when no category list has been pinned" do
      scope = scope!(%{"wiktionary_categories" => []})

      result = ScopeBuilder.build(scope)

      assert result.rules["wiktionary_category"]["status"] == "skipped"
      assert result.rules["wiktionary_category"]["reason"] =~ "dd.scope.categories"
    end
  end

  describe "wikidata_taxon" do
    test "reports itself skipped rather than contributing a silent zero" do
      scope = scope!(%{})

      result = ScopeBuilder.build(scope)

      assert result.rules["wikidata_taxon"] == %{
               "status" => "skipped",
               "reason" => "lands in S2: no concepts absorbed yet"
             }
    end
  end

  describe "reasons" do
    test "a lemma matching two rules keeps both" do
      source = wordnet!()
      senses = build_graph(source)
      {cat, _} = senses["oewn-cat-n"]

      Repo.update!(Ecto.Changeset.change(cat, metadata: %{"wikt_categories" => ["en:Felids"]}))

      scope =
        scope!(%{
          "wordnet_roots" => ["oewn-animal-n"],
          "wiktionary_categories" => ["en:Felids"]
        })

      ScopeBuilder.build(scope)

      row = Repo.get_by!(ScopeLexeme, scope_id: scope.id, lexeme_id: cat.id)
      assert Enum.sort(row.reasons) == ["wiktionary_category", "wordnet_closure"]
    end

    test "--reset clears reasons a rule no longer produces" do
      source = wordnet!()
      build_graph(source)
      scope = scope!(%{"wordnet_roots" => ["oewn-animal-n"]})

      ScopeBuilder.build(scope)
      assert length(members(scope)) == 4

      narrowed = Repo.get!(Scope, scope.id) |> Ecto.Changeset.change(rules: %{}) |> Repo.update!()
      ScopeBuilder.build(narrowed, reset: true)

      assert members(narrowed) == []
    end
  end

  test "scope stats record what each rule did" do
    source = wordnet!()
    build_graph(source)
    scope = scope!(%{"wordnet_roots" => ["oewn-animal-n"]})

    ScopeBuilder.build(scope)
    stats = Repo.get!(Scope, scope.id).stats

    assert stats["total"] == 4
    assert stats["built_at"]
    assert stats["wordnet_closure"]["matched"] == 4
  end
end
