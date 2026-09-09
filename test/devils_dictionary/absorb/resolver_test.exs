defmodule DevilsDictionary.Absorb.ResolverTest do
  @moduledoc """
  The resolver is set-based SQL, so it is tested against the database with a
  handful of deliberately awkward lexemes rather than through a source module.

  What it resolves changed shape with the schema: an edge whose target word does
  not exist is a `pending_relations` row rather than an assertion with a null
  end, and resolving it *creates* the assertion rather than filling a column.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Claims.{AssertionRevision, PendingRelation}
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Sources.Source

  setup do
    # A relation needs its predicate registered: a predicate is a row now, and
    # the endpoint rules behind it are a foreign key.
    DevilsDictionary.Claims.Catalog.seed!()
    :ok
  end

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
    {:ok, lexeme} =
      Registry.create_lexeme(
        Map.merge(
          %{language_tag: "en", lemma: lemma, part_of_speech: pos},
          Map.new(attrs)
        )
      )

    lexeme
  end

  # An unresolved edge waits here with its evidence. `to_lexeme_id:` in the old
  # fixtures meant "already resolved", which now means an assertion instead.
  defp relation!(source, from, attrs) do
    case attrs[:to_lexeme] do
      nil ->
        Repo.insert!(%PendingRelation{
          source_id: source.id,
          subject_object_id: from.object_id,
          predicate_id: Claims.predicate!(to_string(attrs[:type] || :related)).id,
          to_lemma: attrs[:to_lemma],
          to_pos: attrs[:to_pos],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      target ->
        {:ok, assertion} =
          Claims.assert(from.object_id, to_string(attrs[:type] || :related), target.object_id, %{
            source_id: source.id
          })

        assertion
    end
  end

  # What the resolver produced: the target of the one current assertion on this
  # word, or nil when the edge is still pending.
  defp target_of(lexeme, type) do
    Repo.one(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: r.subject_object_id == ^lexeme.object_id and r.is_current,
        where: p.key == ^to_string(type),
        select: r.object_object_id
    )
  end

  defp canonical_of(lexeme), do: Repo.get!(Lexeme, lexeme.object_id).canonical_lexeme_id

  describe "resolve_targets/1" do
    test "points to_lemma at a lexeme and leaves to_lemma alone" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      feline = lexeme!("feline", "noun")

      relation!(source, cat, to_lemma: "feline", type: :hypernym)

      assert Resolver.resolve_targets(source.id) == 1

      # The pending row becomes an assertion pointing at the word.
      assert target_of(cat, :hypernym) == feline.object_id

      assert Repo.aggregate(from(p in PendingRelation, where: p.source_id == ^source.id), :count) ==
               0
    end

    test "prefers the part of speech the source stated" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      _noun = lexeme!("feline", "noun")
      adj = lexeme!("feline", "adj")

      relation!(source, cat, to_lemma: "feline", type: :related, to_pos: "adj")

      Resolver.resolve_targets(source.id)

      assert target_of(cat, :related) == adj.object_id
    end

    test "falls back to a part-of-speech priority when the source said nothing" do
      source = source!("wiktionary")
      cat = lexeme!("cat", "noun")
      _adv = lexeme!("feline", "adv")
      noun = lexeme!("feline", "noun")

      relation!(source, cat, to_lemma: "feline", type: :related)

      Resolver.resolve_targets(source.id)

      assert target_of(cat, :related) == noun.object_id
    end

    test "matches case-insensitively but prefers the exact casing" do
      source = source!("wiktionary")
      from = lexeme!("bird", "noun")
      _lower = lexeme!("turkey", "noun")
      upper = lexeme!("Turkey", "noun")

      relation!(source, from, to_lemma: "Turkey", type: :related)

      Resolver.resolve_targets(source.id)

      assert target_of(from, :related) == upper.object_id
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

      relation!(wordnet, cat, type: :hypernym, to_lexeme: wrong)

      assert Resolver.resolve_targets(wiktionary.id) == 0
      assert target_of(cat, :hypernym) == wrong.object_id
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
      assert canonical_of(variant) == oyster.object_id
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

      assert canonical_of(word) == spelling.object_id
    end

    test "never overwrites a canonical target that is already set" do
      source = source!("wiktionary")
      chosen = lexeme!("email", "noun")
      other = lexeme!("e-mail", "noun")
      variant = lexeme!("E-mail", "noun", canonical_lexeme_id: chosen.object_id)

      relation!(source, variant, to_lemma: "e-mail", type: :alt_of)
      Resolver.resolve_targets(source.id)
      Resolver.link_canonical()

      assert canonical_of(variant) == chosen.object_id
      refute canonical_of(variant) == other.object_id
    end

    test "refuses to close a two-lexeme cycle" do
      source = source!("wiktionary")
      a = lexeme!("colour", "noun")
      b = lexeme!("color", "noun", canonical_lexeme_id: nil)

      # b already points at a; a must not be made to point back at b.
      Repo.update!(Ecto.Changeset.change(b, canonical_lexeme_id: a.object_id))

      relation!(source, a, to_lemma: "color", type: :alt_of)
      Resolver.resolve_targets(source.id)
      Resolver.link_canonical()

      assert canonical_of(a) == nil
    end

    test "and refuses to close one formed inside a single batch" do
      # Both halves of a reciprocal pair are offered by the *same statement*, so
      # neither can see the other's write. MVP-0's per-row check missed exactly
      # this, which is how five reciprocal canonical pairs came to exist.
      source = source!("wiktionary")
      a = lexeme!("colour", "noun")
      b = lexeme!("color", "noun")

      relation!(source, a, to_lemma: "color", type: :alt_of)
      relation!(source, b, to_lemma: "colour", type: :alt_of)
      Resolver.resolve_targets(source.id)
      Resolver.link_canonical()

      # Exactly one arrow, never two.
      assert Enum.count([canonical_of(a), canonical_of(b)], &(&1 != nil)) == 1
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
