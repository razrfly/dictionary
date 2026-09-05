defmodule DevilsDictionary.Absorb.ResolverTest do
  @moduledoc """
  The resolver is set-based SQL, so it is tested against the database with a
  handful of deliberately awkward lexemes rather than through a source module.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Lexicon.{Lexeme, LexicalRelation}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  defp source!(slug) do
    Repo.insert!(%Source{
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      name: slug,
      tier: :middle,
      kind: :dictionary,
      access: :dump
    })
  end

  defp lexeme!(lemma, pos, attrs \\ []) do
    Repo.insert!(
      struct(
        %Lexeme{lang: "en", lemma: lemma, pos: pos, slug: Lexeme.slug(lemma)},
        attrs
      )
    )
  end

  defp relation!(source, from, attrs) do
    Repo.insert!(
      struct(
        %LexicalRelation{
          source_id: source.id,
          from_lexeme_id: from.id,
          to_lemma: attrs[:to_lemma],
          type: attrs[:type] || :related
        },
        Keyword.drop(attrs, [:to_lemma, :type])
      )
    )
  end

  describe "resolve_targets/1" do
    test "points to_lemma at a lexeme and leaves to_lemma alone" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      feline = lexeme!("feline", "noun")

      relation = relation!(source, cat, to_lemma: "feline", type: :hypernym)

      assert Resolver.resolve_targets(source.id) == 1

      reloaded = Repo.get!(LexicalRelation, relation.id)
      assert reloaded.to_lexeme_id == feline.id
      assert reloaded.to_lemma == "feline"
    end

    test "prefers the part of speech the source stated" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      _noun = lexeme!("feline", "noun")
      adj = lexeme!("feline", "adj")

      relation = relation!(source, cat, to_lemma: "feline", type: :related, to_pos: "adj")

      Resolver.resolve_targets(source.id)

      assert Repo.get!(LexicalRelation, relation.id).to_lexeme_id == adj.id
    end

    test "falls back to a part-of-speech priority when the source said nothing" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      _adv = lexeme!("feline", "adv")
      noun = lexeme!("feline", "noun")

      relation = relation!(source, cat, to_lemma: "feline", type: :related)

      Resolver.resolve_targets(source.id)

      assert Repo.get!(LexicalRelation, relation.id).to_lexeme_id == noun.id
    end

    test "matches case-insensitively but prefers the exact casing" do
      source = source!("wiktionary")
      from = lexeme!("bird", "noun")
      _lower = lexeme!("turkey", "noun")
      upper = lexeme!("Turkey", "noun")

      relation = relation!(source, from, to_lemma: "Turkey", type: :related)

      Resolver.resolve_targets(source.id)

      assert Repo.get!(LexicalRelation, relation.id).to_lexeme_id == upper.id
    end

    test "leaves an unknown target unresolved, and says so" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      relation!(source, cat, to_lemma: "wamplebug", type: :hyponym)

      assert Resolver.resolve_targets(source.id) == 0
      assert Resolver.unresolved_lemmas(source.id) == [{"wamplebug", 1}]
      assert %{"hyponym" => %{total: 1, resolved: 0, unresolved: 1}} = Resolver.by_type(source.id)
    end

    test "does not touch rows another source already resolved" do
      wordnet = source!("wordnet")
      wiktionary = source!("wiktionary")

      cat = lexeme!("cat", "noun")
      wrong = lexeme!("feline", "adj")
      _right = lexeme!("feline", "noun")

      already =
        relation!(wordnet, cat, to_lemma: "feline", type: :hypernym, to_lexeme_id: wrong.id)

      assert Resolver.resolve_targets(wiktionary.id) == 0
      assert Repo.get!(LexicalRelation, already.id).to_lexeme_id == wrong.id
    end
  end

  describe "link_canonical/0" do
    test "an alt_of edge makes the target canonical" do
      source = source!("wiktionary")
      variant = lexeme!("oistre", "noun")
      oyster = lexeme!("oyster", "noun")

      relation!(source, variant, to_lemma: "oyster", type: :alt_of)
      Resolver.resolve_targets(source.id)

      assert Resolver.link_canonical() == 1
      assert Repo.get!(Lexeme, variant.id).canonical_lexeme_id == oyster.id
    end

    test "alt_of wins over form_of when a word has both" do
      source = source!("wiktionary")
      word = lexeme!("gray", "noun")
      _form_target = lexeme!("grays", "noun")
      spelling = lexeme!("grey", "noun")

      relation!(source, word, to_lemma: "grays", type: :form_of)
      relation!(source, word, to_lemma: "grey", type: :alt_of)
      Resolver.resolve_targets(source.id)

      Resolver.link_canonical()

      assert Repo.get!(Lexeme, word.id).canonical_lexeme_id == spelling.id
    end

    test "never overwrites a canonical target that is already set" do
      source = source!("wiktionary")
      chosen = lexeme!("email", "noun")
      other = lexeme!("e-mail", "noun")
      variant = lexeme!("E-mail", "noun", canonical_lexeme_id: chosen.id)

      relation!(source, variant, to_lemma: "e-mail", type: :alt_of)
      Resolver.resolve_targets(source.id)
      Resolver.link_canonical()

      assert Repo.get!(Lexeme, variant.id).canonical_lexeme_id == chosen.id
      refute Repo.get!(Lexeme, variant.id).canonical_lexeme_id == other.id
    end

    test "refuses to close a two-lexeme cycle" do
      source = source!("wiktionary")
      a = lexeme!("colour", "noun")
      b = lexeme!("color", "noun", canonical_lexeme_id: nil)

      # b already points at a; a must not be made to point back at b.
      Repo.update!(Ecto.Changeset.change(b, canonical_lexeme_id: a.id))

      relation!(source, a, to_lemma: "color", type: :alt_of)
      Resolver.resolve_targets(source.id)
      Resolver.link_canonical()

      assert Repo.get!(Lexeme, a.id).canonical_lexeme_id == nil
    end
  end

  describe "run/1" do
    test "reports both halves and is idempotent" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      lexeme!("feline", "noun")
      variant = lexeme!("catt", "noun")
      relation!(source, cat, to_lemma: "feline", type: :hypernym)
      relation!(source, variant, to_lemma: "cat", type: :alt_of)

      first = Resolver.run(source_id: source.id)
      assert first.resolved == 2
      assert first.canonical == 1

      second = Resolver.run(source_id: source.id)
      assert second.resolved == 0
      assert second.canonical == 0
      assert second.by_type == first.by_type
    end
  end
end
