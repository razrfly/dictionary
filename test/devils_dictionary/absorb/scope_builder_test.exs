defmodule DevilsDictionary.Absorb.ScopeBuilderTest do
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.ScopeBuilder
  alias DevilsDictionary.Lexicon.{Scope, ScopeMember}
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Sources.Source

  setup do
    Claims.Catalog.seed!()
    :ok
  end

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
        lexeme = lexeme!(lemma)

        {:ok, sense} =
          Registry.create_sense(%{
            lexeme_id: lexeme.object_id,
            source_id: source.id,
            external_key: "#{group_key}##{lemma}",
            group_key: group_key,
            gloss: "a #{lemma}"
          })

        {group_key, {lexeme, sense}}
      end)

    # The absorb stores both directions; the closure walks the derived hyponym.
    # Sense to sense, which is what WordNet's graph actually is and what the
    # three declared endpoint pairs allow.
    for {group_key, {_lemma, parent}} <- @graph, parent != nil do
      {_, parent_sense} = senses[parent]
      {_child_lexeme, child_sense} = senses[group_key]

      {:ok, _} =
        Claims.assert(parent_sense.object_id, "hyponym", child_sense.object_id, %{
          source_id: source.id
        })

      {:ok, _} =
        Claims.assert(child_sense.object_id, "hypernym", parent_sense.object_id, %{
          source_id: source.id
        })
    end

    senses
  end

  defp scope!(rules) do
    Repo.insert!(%Scope{slug: "animals", name: "Animals", rules: rules})
  end

  defp members(scope) do
    Repo.all(
      from sl in ScopeMember,
        join: l in Lexeme,
        on: l.object_id == sl.lexeme_id,
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
      lexeme!("corvid", %{"wikt_categories" => ["en:Corvids", "en:Birds"]})
      lexeme!("hammer", %{"wikt_categories" => ["en:Tools"]})

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

      row = Repo.get_by!(ScopeMember, scope_id: scope.id, lexeme_id: cat.object_id)
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

  describe "wikidata_taxon" do
    setup do
      wikidata =
        Repo.insert!(%Source{
          slug: "wikidata",
          name: "Wikidata",
          tier: :middle,
          kind: :knowledge_graph,
          access: :api
        })

      animalia = concept!("Q729", "Animalia", [])
      felidae = concept!("Q25265", "Felidae", [])
      felis = concept!("Q20980826", "Felis catus", ["cat", "domestic cat"])

      parent!(wikidata, felidae, animalia)
      parent!(wikidata, felis, felidae)

      # Outside the tree: named the same way, but nothing links it to Animalia.
      concept!("Q25294", "Ferrum hammerensis", ["hammer"])

      %{}
    end

    test "matches lemmas by scientific name and by English common name" do
      for lemma <- ["cat", "Felis catus", "hammer"], do: lexeme!(lemma)

      scope = scope!(%{"wikidata_root" => "Q729"})
      ScopeBuilder.build(scope)

      # `hammer` is a common name too, but of a concept with no path to Animalia.
      assert members(scope) == ["cat", "Felis catus"]
    end

    test "the enwiki-sitelink requirement is applied, and the count without it reported" do
      lexeme!("cat")

      # The real Felis catus (Q20980826) has no article of its own — the article
      # is on Q146 *Cat* — so §3's rule as written matches nothing. That gap is
      # the finding, which is why both numbers are reported.
      felis = DevilsDictionary.Encyclopedia.by_qid!("Q20980826")

      felis
      |> Ecto.Changeset.change(metadata: Map.delete(felis.metadata, "wikipedia_title"))
      |> Repo.update!()

      scope = scope!(%{"wikidata_root" => "Q729"})
      %{rules: rules} = ScopeBuilder.build(scope)

      assert rules["wikidata_taxon"]["matched"] == 0
      assert rules["wikidata_taxon"]["matched_without_sitelink"] == 1
      assert members(scope) == []
    end

    test "skips itself loudly when no concepts have been absorbed" do
      # The root entity is what the rule looks for; without it the rule has
      # nothing to walk. Identities are retired rather than deleted, so the
      # external identifier is what goes.
      Repo.delete_all(DevilsDictionary.Registry.ExternalIdentifier)
      scope = scope!(%{"wikidata_root" => "Q729"})

      %{rules: rules} = ScopeBuilder.build(scope)

      # A skip, never a silent zero: a zero here would read as a measurement.
      assert rules["wikidata_taxon"]["status"] == "skipped"
      assert rules["wikidata_taxon"]["reason"] =~ "mix dd.absorb wikidata"
    end

    test "skips itself when the scope names no root" do
      scope = scope!(%{})

      %{rules: rules} = ScopeBuilder.build(scope)

      assert rules["wikidata_taxon"] == %{
               "status" => "skipped",
               "reason" => "no wikidata_root in scopes.rules"
             }
    end
  end

  defp concept!(qid, scientific_name, common_names) do
    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: :taxon,
        preferred_label: scientific_name,
        metadata: %{
          "wikipedia_title" => scientific_name,
          "taxon" => %{
            "scientific_name" => scientific_name,
            "common_names" => common_names
          }
        }
      })

    {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", qid)
    entity
  end

  defp parent!(source, child, parent) do
    {:ok, assertion} =
      Claims.assert(child.object_id, "parent_taxon", parent.object_id, %{
        source_id: source.id,
        metadata: %{"property" => "P171"}
      })

    assertion
  end

  defp lexeme!(lemma, metadata \\ %{}) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: lemma,
        part_of_speech: "noun",
        metadata: metadata
      })

    lexeme
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
