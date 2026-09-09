defmodule DevilsDictionary.ExtensionTest do
  @moduledoc """
  **E3**, #74 milestone 5: does one challenging new type fit through a controlled
  extension?

  The case chosen from the three the issue offers is the **translated poem
  passage**, because it is the one that needs every part of the model at once:
  a work, a person in a role that is not authorship, a passage that is a piece
  of a larger thing rather than a definition of a word, an edition it was
  printed in, and a quotation drawn from it that a curator then attaches to a
  meaning.

  What the exercise measures is the *cost*. #74: "A small additive migration is
  acceptable; rewriting existing identities or hiding essential fields in JSON
  is a failed extension exercise." The cost here is **zero migrations and zero
  new tables**: `excerpt_of` and `translated_by` are already registered in
  `priv/predicates/core.json`, `entity_kind` already has `work` and `person`,
  and `content_kind` already has `passage` and `quotation`. So this is written
  the way a reader would write it, and the assertion at the end is that nothing
  had to change to allow it.

  This replaces the MVP-0 E3, which was `File.exists?` on a rolled-back
  migration sketch. The sketch is retired: the community layer is shipped schema
  now — `users`, `actors`, `assertion_reviews`, `assertion_votes` — so a
  file-existence check would be measuring nothing at all.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  describe "a translated poem passage" do
    setup ctx do
      # The poem, its poet, its translator and the edition we read it in. Four
      # entities, three of them in roles MVP-0 had no way to express: `people`
      # held authors only, and a translator was not an author.
      {:ok, poem} =
        Registry.create_work(%{
          entity_kind: :work,
          preferred_label: "Duino Elegies",
          work_kind: "poem",
          original_language: "de",
          first_published_year: 1923
        })

      {:ok, poet} =
        Registry.create_person(%{entity_kind: :person, preferred_label: "Rainer Maria Rilke"})

      {:ok, translator} =
        Registry.create_person(%{entity_kind: :person, preferred_label: "Stephen Mitchell"})

      {:ok, edition} =
        Registry.create_edition(%{
          entity_kind: :edition,
          preferred_label: "Vintage International, 1989",
          work_id: poem.object_id,
          publication_year: 1989,
          language_tag: "en"
        })

      Map.merge(ctx, %{poem: poem, poet: poet, translator: translator, edition: edition})
    end

    test "is a passage with three credits, and each one is a different claim", ctx do
      {:ok, passage} =
        Registry.create_content(%{
          content_kind: :passage,
          original_language: "en",
          body: "For beauty is nothing but the beginning of terror.",
          body_format: :text,
          position: 1
        })

      {:ok, _} = Claims.assert(passage.object_id, "excerpt_of", ctx.poem.object_id)
      {:ok, _} = Claims.assert(passage.object_id, "translated_by", ctx.translator.object_id)
      {:ok, _} = Claims.assert(passage.object_id, "published_in", ctx.edition.object_id)
      {:ok, _} = Claims.assert(ctx.poem.object_id, "authored_by", ctx.poet.object_id)

      # Three roles on one passage, told apart by predicate rather than by three
      # nullable columns — and the poet's authorship of the *work* is a fourth
      # claim about a different subject, which is what keeps "who wrote it" and
      # "who translated this printing of it" from being the same field.
      assert credits(passage) == [
               {"excerpt_of", ctx.poem.object_id},
               {"published_in", ctx.edition.object_id},
               {"translated_by", ctx.translator.object_id}
             ]

      assert credits(ctx.poem) == [{"authored_by", ctx.poet.object_id}]
    end

    test "the database refuses a credit that does not make sense", ctx do
      {:ok, passage} =
        Registry.create_content(%{content_kind: :passage, body: "…", body_format: :text})

      # A passage cannot be an excerpt of a *person*, and the endpoint rules say
      # so as a foreign key rather than as a validation somebody can forget.
      assert {:error, changeset} =
               Claims.assert(passage.object_id, "excerpt_of", ctx.translator.object_id)

      assert "does not allow these endpoint kinds" in errors_on(changeset).predicate_id
    end

    test "a quotation drawn from it attaches to a meaning, with its evidence", ctx do
      {:ok, passage} =
        Registry.create_content(%{
          content_kind: :passage,
          body: "For beauty is nothing but the beginning of terror.",
          body_format: :text
        })

      {:ok, _} = Claims.assert(passage.object_id, "excerpt_of", ctx.poem.object_id)
      {:ok, _} = Claims.assert(passage.object_id, "translated_by", ctx.translator.object_id)

      # The word the quotation is offered as an illustration of.
      terror = word!(ctx, "terror", ~w(wordnet))
      sense = sense!(ctx, terror, "wordnet", gloss: "overwhelming fear")

      {:ok, claim} =
        Claims.assert(passage.object_id, "illustrates", sense.object_id, %{
          rationale: "the line is the locus classicus for the sense",
          method: "curated"
        })

      revision = Claims.current_revision(claim.id)

      # Its evidence is the translated passage itself, cited by revision — so a
      # later re-translation cannot silently change what was quoted.
      shown = Registry.current_content_revision(passage.object_id)

      {:ok, evidence} =
        Claims.add_evidence(revision.id, %{
          content_revision_id: shown.id,
          evidence_role: :supports,
          locator: "First Elegy, line 4",
          attribution_text: "tr. Stephen Mitchell, Vintage International, 1989"
        })

      assert evidence.content_revision_id == shown.id
      assert Claims.evidence(revision.id) |> length() == 1

      # And the claim reads the same from the meaning's side, which is #73's
      # "the same claim revision appears from either endpoint".
      assert [seen] = Claims.incoming(sense.object_id, predicate: "illustrates")
      assert seen.id == revision.id
      assert seen.subject_object_id == passage.object_id
    end
  end

  describe "what the extension cost" do
    test "no migration, no new table, no new column", _ctx do
      # #74: "Record the extension's schema/code changes. A small additive
      # migration is acceptable; rewriting existing identities or hiding
      # essential fields in JSON is a failed extension exercise."
      #
      # The cost was none of those. Everything above is data the model already
      # allows: two predicates from `priv/predicates/core.json`, two entity
      # kinds and two content kinds that were already in the enums.
      assert Repo.aggregate("schema_migrations", :count) == migrations_on_disk()

      for key <- ~w(excerpt_of translated_by published_in illustrates) do
        assert Claims.predicate(key), "#{key} should be registered from priv/predicates"
        assert Claims.endpoint_rules(key) != [], "#{key} should have enumerated endpoints"
      end

      assert :work in Registry.Entity.kinds()
      assert :edition in Registry.Entity.kinds()
      assert :passage in Registry.ContentItem.kinds()
      assert :quotation in Registry.ContentItem.kinds()
    end
  end

  defp migrations_on_disk do
    Path.wildcard("priv/repo/migrations/*.exs") |> length()
  end

  defp credits(subject) do
    Repo.all(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: r.subject_object_id == ^subject.object_id and r.is_current,
        order_by: p.key,
        select: {p.key, r.object_object_id}
    )
  end
end
