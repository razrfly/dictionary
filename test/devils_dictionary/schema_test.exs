defmodule DevilsDictionary.SchemaTest do
  @moduledoc """
  The new schema's contract, asserted against the database rather than against
  changesets.

  #74: "Test direct SQL/bulk-write rejection of invalid targets, incompatible
  predicates and missing required records" and "Actual database integrity, not
  changeset-only guarantees." So every rejection here goes through `Repo.query!`
  or `insert_all`, deliberately bypassing every changeset — because the linker,
  the resolver and the scope builder are raw SQL, and a rule they can walk
  around is not a rule.

  The shapes were all proved first in `docs/spikes/2026-09-gate0/`, against the
  full 1.16 M-assertion corpus. These are the regression tests for them.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision}
  alias DevilsDictionary.Registry.{Entity, Lexeme, Object}

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    :ok
  end

  # A raw statement, outside every changeset -- the linker, resolver and scope
  # builder are all raw SQL, so a rule they can walk around is not a rule.
  defp raw(sql, params \\ []) do
    case Repo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, Exception.message(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Deferred constraint triggers fire at COMMIT, and the SQL sandbox wraps every
  # test in a transaction it never commits -- so without this they would never
  # run and these tests would pass vacuously. `SET CONSTRAINTS ALL IMMEDIATE`
  # forces the pending checks now, which is the same check at a time we can
  # observe.
  defp at_commit do
    case Repo.query("SET CONSTRAINTS ALL IMMEDIATE") do
      {:ok, _} -> :ok
      {:error, e} -> {:error, Exception.message(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  describe "the registry's exactly-one-subtype rule" do
    test "an object with no subtype is rejected at commit, and legal before it" do
      # Legal mid-transaction is not an oversight: the object row has to exist
      # before its subtype row can reference it, so the check cannot be immediate.
      assert :ok =
               raw("INSERT INTO objects (kind, inserted_at, updated_at)
                    VALUES ('lexeme', now(), now())")

      assert {:error, message} = at_commit()
      assert message =~ "has no lexeme row"
    end

    test "a well-formed object and subtype pass the same commit-time check" do
      {:ok, _} = Registry.create_lexeme(%{lemma: "cat", part_of_speech: "noun"})
      assert :ok = at_commit()
    end

    test "a subtype of the wrong kind is rejected immediately by the composite FK" do
      {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "x"})

      assert {:error, message} =
               raw(
                 """
                 INSERT INTO lexemes (object_id, language_tag, lemma, part_of_speech,
                                      lexical_key, slug, inserted_at, updated_at)
                 VALUES ($1, 'en', 'x', 'noun', 'en/x/noun', 'x', now(), now())
                 """,
                 [entity.object_id]
               )

      assert message =~ "lexemes_object_fkey"
    end

    test "two subtypes for one object is rejected" do
      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "cat", part_of_speech: "noun"})

      assert {:error, message} =
               raw(
                 "INSERT INTO entities (object_id, entity_kind, inserted_at, updated_at)
                  VALUES ($1, 'concept', now(), now())",
                 [lexeme.object_id]
               )

      assert message =~ "entities_object_fkey"
    end

    test "objects.kind is immutable" do
      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "cat", part_of_speech: "noun"})

      assert {:error, message} =
               raw("UPDATE objects SET kind = 'entity' WHERE id = $1", [lexeme.object_id])

      assert message =~ "objects.kind is immutable"
    end

    test "deleting a subtype cannot orphan its object — retire it instead" do
      # The gap the Gate 0 spike found: an AFTER INSERT trigger on `objects`
      # cannot see a subtype being deleted out from under it, and the object was
      # left typed `entity` with no entity row while an assertion still pointed
      # at it.
      {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "x"})

      assert :ok = raw("DELETE FROM entities WHERE object_id = $1", [entity.object_id])

      assert {:error, message} = at_commit()

      # `SET CONSTRAINTS ALL IMMEDIATE` fires every pending deferred check, and
      # the one queued by the earlier INSERT reports first. Both are the same
      # refusal: this object may not be left without a subtype.
      assert message =~ "would be left with no subtype row" or
               message =~ "has no entity row"
    end

    test "deleting the object itself cascades and is allowed" do
      {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "x"})

      assert :ok = raw("DELETE FROM objects WHERE id = $1", [entity.object_id])
      assert :ok = at_commit()
      refute Repo.get(Entity, entity.object_id)
    end

    test "a person subtype cannot attach to a concept entity" do
      {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "x"})

      assert {:error, message} =
               raw(
                 "INSERT INTO person_details (entity_id, inserted_at, updated_at)
                  VALUES ($1, now(), now())",
                 [entity.object_id]
               )

      assert message =~ "person_details_entity_fkey"
    end

    test "retiring is the supported way out, and it leaves the identity resolvable" do
      {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "x"})
      {:ok, _} = Registry.retire(entity.object_id, reason: "duplicate")

      assert %Object{lifecycle_state: :retired} = Registry.object(entity.object_id)
      assert Repo.get(Entity, entity.object_id)
      assert [%{event: %{operation: :retire, reason: "duplicate"}}] =
               Registry.identity_history(entity.object_id)
    end
  end

  describe "predicate endpoint compatibility" do
    setup do
      {:ok, bierce} = Registry.create_person(%{preferred_label: "Ambrose Bierce"})
      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "nepotism", part_of_speech: "noun"})
      {:ok, definition} = Registry.create_content(%{content_kind: :definition, body: "…"})
      {:ok, bierce: bierce, lexeme: lexeme, definition: definition}
    end

    test "the valid Bierce anchor commits", %{
      bierce: bierce,
      lexeme: lexeme,
      definition: definition
    } do
      assert {:ok, _} = Claims.assert(definition.object_id, "defines", lexeme.object_id)
      assert {:ok, _} = Claims.assert(definition.object_id, "authored_by", bierce.object_id)

      # The trigger filled the endpoint kinds; nothing set them by hand.
      [revision] = Claims.outgoing(definition.object_id, predicate: "defines")
      assert revision.subject_kind == "content"
      assert revision.subject_subkind == "definition"
      assert revision.object_kind == "lexeme"
      assert revision.object_subkind == "-"
    end

    test "`defines` pointing at a person is rejected", %{
      bierce: bierce,
      definition: definition
    } do
      assert {:error, changeset} =
               Claims.assert(definition.object_id, "defines", bierce.object_id)

      assert "does not allow these endpoint kinds" in errors_on(changeset).predicate_id
    end

    test "`refers_to` from a lexeme rather than a sense is rejected", %{lexeme: lexeme} do
      {:ok, concept} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "n"})

      assert {:error, _} = Claims.assert(lexeme.object_id, "refers_to", concept.object_id)
    end

    test "rejection holds on a BULK write, which is what insert_all and COPY do",
         %{bierce: bierce, lexeme: lexeme, definition: definition} do
      predicate = Claims.predicate!("defines")

      {:ok, %{rows: [[good_id], [bad_id]]}} =
        Repo.query(
          "INSERT INTO assertions (inserted_at, updated_at)
           VALUES (now(), now()), (now(), now()) RETURNING id"
        )

      # One good row and one bad row in a single statement. The whole statement
      # must be rejected, not filtered -- otherwise the good row lands and the
      # bad one vanishes silently.
      assert {:error, message} =
               raw(
                 """
                 INSERT INTO assertion_revisions
                   (assertion_id, revision_number, subject_object_id, predicate_id,
                    object_object_id, is_current, inserted_at, updated_at)
                 VALUES ($1, 1, $3, $5, $4, true, now(), now()),
                        ($2, 1, $3, $5, $6, true, now(), now())
                 """,
                 [
                   good_id,
                   bad_id,
                   definition.object_id,
                   lexeme.object_id,
                   predicate.id,
                   bierce.object_id
                 ]
               )

      assert message =~ "assertion_revisions_endpoints"
      assert Repo.aggregate(Assertion, :count) >= 2

      # Neither row landed. The statement was rejected, not filtered -- if
      # Postgres skipped the bad row the good one would be here.
      assert Repo.all(
               from r in AssertionRevision,
                 where: r.assertion_id in ^[good_id, bad_id],
                 select: count(r.id)
             ) == [0]
    end

    test "confidence outside [0,1] is rejected by the database, not only the changeset",
         %{lexeme: lexeme, definition: definition} do
      {:ok, assertion} = Claims.assert(definition.object_id, "defines", lexeme.object_id)
      revision = Claims.current_revision(assertion.id)

      assert {:error, message} =
               raw("UPDATE assertion_revisions SET confidence = 1.4 WHERE id = $1", [revision.id])

      assert message =~ "assertion_revisions_confidence"
    end
  end

  describe "exactly one current revision" do
    setup do
      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "bank", part_of_speech: "noun"})
      {:ok, definition} = Registry.create_content(%{content_kind: :definition, body: "…"})
      {:ok, assertion} = Claims.assert(definition.object_id, "defines", lexeme.object_id)
      {:ok, assertion: assertion, lexeme: lexeme, definition: definition}
    end

    test "a second current revision is rejected by the partial unique index", %{
      assertion: assertion
    } do
      revision = Claims.current_revision(assertion.id)

      assert {:error, message} =
               raw(
                 """
                 INSERT INTO assertion_revisions
                   (assertion_id, revision_number, subject_object_id, predicate_id,
                    object_object_id, is_current, inserted_at, updated_at)
                 SELECT assertion_id, 99, subject_object_id, predicate_id, object_object_id,
                        true, now(), now()
                   FROM assertion_revisions WHERE id = $1
                 """,
                 [revision.id]
               )

      assert message =~ "assertion_revisions_one_current_index"
    end

    test "clearing the flag is rejected at commit — at most one is not exactly one",
         %{assertion: assertion} do
      # The partial unique index proves at most one. This is the other half, and
      # #74 is explicit that they are not the same guarantee.
      assert :ok =
               raw("UPDATE assertion_revisions SET is_current = false WHERE assertion_id = $1", [
                 assertion.id
               ])

      assert {:error, message} = at_commit()
      assert message =~ "has 0 current revisions"
    end

    test "revising switches atomically and keeps exactly one current", %{assertion: assertion} do
      {:ok, second} = Claims.revise(assertion.id, %{rationale: "corrected"})

      assert second.revision_number == 2
      assert Claims.current_revision(assertion.id).id == second.id
      assert length(Claims.history(assertion.id)) == 2

      assert :ok = at_commit()

      assert [1] ==
               Repo.all(
                 from r in AssertionRevision,
                   where: r.assertion_id == ^assertion.id and r.is_current,
                   select: count(r.id)
               )
    end

    test "currentness and lifecycle are separate: the current revision can say withdrawn",
         %{assertion: assertion} do
      {:ok, withdrawn} = Claims.withdraw(assertion.id, reason: "source dropped it")

      current = Claims.current_revision(assertion.id)
      assert current.id == withdrawn.id
      assert current.lifecycle_state == :withdrawn
      # The history that shows the claim was once made is untouched.
      assert [%{lifecycle_state: :superseded}, %{lifecycle_state: :withdrawn}] =
               Claims.history(assertion.id)
    end
  end

  describe "votes and reviews are isolated per revision" do
    setup do
      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "egomaniac", part_of_speech: "noun"})
      {:ok, definition} = Registry.create_content(%{content_kind: :definition, body: "…"})
      {:ok, assertion} = Claims.assert(definition.object_id, "defines", lexeme.object_id)
      {:ok, actor} = actor()
      {:ok, assertion: assertion, actor: actor}
    end

    test "a vote does not carry forward onto a revision that says something else",
         %{assertion: assertion, actor: actor} do
      first = Claims.current_revision(assertion.id)
      {:ok, _} = Claims.vote(first.id, actor.id, 1)
      assert Claims.score(first.id) == 1

      {:ok, second} = Claims.revise(assertion.id, %{rationale: "changed"})

      assert Claims.score(second.id) == 0
      assert Claims.score(first.id) == 1
    end

    test "a review is append-only and its effective state is the latest decision",
         %{assertion: assertion, actor: actor} do
      revision = Claims.current_revision(assertion.id)
      assert Claims.review_state(revision.id) == :needs_review

      {:ok, _} = Claims.review(revision.id, :accepted, %{reviewer_actor_id: actor.id})
      assert Claims.review_state(revision.id) == :accepted

      {:ok, _} = Claims.review(revision.id, :disputed, %{reviewer_actor_id: actor.id})
      assert Claims.review_state(revision.id) == :disputed
      # Both survive: the decision changed, the record of the first did not.
      assert length(Claims.reviews(revision.id)) == 2
    end

    test "a review context from another revision is refused by the composite FK",
         %{assertion: assertion, actor: actor} do
      first = Claims.current_revision(assertion.id)
      {:ok, context} = Claims.open_review_context(first.id)
      {:ok, second} = Claims.revise(assertion.id, %{rationale: "changed"})

      assert {:error, changeset} =
               Claims.review(second.id, :accepted, %{
                 reviewer_actor_id: actor.id,
                 review_context_id: context.id
               })

      assert "belongs to a different assertion revision" in errors_on(changeset).review_context_id
    end

    test "a vote value other than +1/-1 is refused by the database", %{
      assertion: assertion,
      actor: actor
    } do
      revision = Claims.current_revision(assertion.id)

      assert {:error, message} =
               raw(
                 "INSERT INTO assertion_votes (assertion_revision_id, actor_id, value,
                                               inserted_at, updated_at)
                  VALUES ($1, $2, 5, now(), now())",
                 [revision.id, actor.id]
               )

      assert message =~ "assertion_votes_value"
    end
  end

  describe "external identifiers" do
    test "a verified id collides; a candidate does not" do
      {:ok, a} = Registry.create_entity(%{entity_kind: :person, preferred_label: "A"})
      {:ok, b} = Registry.create_entity(%{entity_kind: :person, preferred_label: "B"})

      {:ok, _} = Registry.add_external_id(a.object_id, "wikidata", "Q1")

      assert {:error, changeset} = Registry.add_external_id(b.object_id, "wikidata", "Q1")
      assert errors_on(changeset).namespace != []

      # An unresolved candidate is evidence, not a claim of identity, so several
      # may coexist without any of them silently becoming the answer.
      assert {:ok, _} =
               Registry.add_external_id(b.object_id, "wikidata", "Q1", status: :candidate)
    end

    test "identity does not depend on having one" do
      {:ok, local} = Registry.create_entity(%{entity_kind: :artifact, preferred_label: "a meme"})
      assert local.object_id

      {:ok, lexeme} = Registry.create_lexeme(%{lemma: "nepotism", part_of_speech: "noun"})
      {:ok, concept} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "n"})
      {:ok, assertion} = Claims.assert(local.object_id, "illustrates", concept.object_id)

      # Adding an external id later leaves the identity and its attachments alone.
      {:ok, _} = Registry.add_external_id(local.object_id, "wikidata", "Q999")

      assert Claims.current_revision(assertion.id).subject_object_id == local.object_id
      assert Registry.by_external_id("wikidata", "Q999") == local.object_id
      assert lexeme.object_id != local.object_id
    end
  end

  describe "lossless word identity" do
    test "C++, C+ and c are three identities, and the slug does not merge them" do
      for lemma <- ~w(C++ C+ c) do
        {:ok, _} = Registry.create_lexeme(%{lemma: lemma, part_of_speech: "noun"})
      end

      assert Repo.aggregate(Lexeme, :count) == 3

      # As a set: the claim is that three distinct keys exist, and neither the
      # database's collation nor Elixir's byte order is what this test is about.
      keys = Repo.all(from l in Lexeme, select: l.lexical_key) |> MapSet.new()
      assert keys == MapSet.new(["en/C+/noun", "en/C++/noun", "en/c/noun"])

      # The audit's reproduction: searching C++ landed on /define/c because the
      # slug was treated as identity. Slugs still collide -- they are cosmetic --
      # but nothing keys off them.
      assert {:ok, lexeme} = Registry.create_lexeme(%{lemma: "résumé", part_of_speech: "noun"})
      assert lexeme.lexical_key == "en/résumé/noun"
      assert Registry.lexeme_by_key("en", "résumé", "noun").object_id == lexeme.object_id
      refute Registry.lexeme_by_key("en", "resume", "noun")
    end

    test "the same lemma in two parts of speech is two identities" do
      {:ok, noun} = Registry.create_lexeme(%{lemma: "bank", part_of_speech: "noun"})
      {:ok, verb} = Registry.create_lexeme(%{lemma: "bank", part_of_speech: "verb"})

      assert noun.object_id != verb.object_id
      assert {:error, _} = Registry.create_lexeme(%{lemma: "bank", part_of_speech: "noun"})
    end
  end

  describe "actors" do
    test "a principal cannot be a human and a bot at once" do
      source = DevilsDictionary.Sources.get_source_by_slug!("bierce")

      assert {:error, changeset} =
               %DevilsDictionary.Sources.Actor{}
               |> DevilsDictionary.Sources.Actor.changeset(%{
                 actor_kind: :user,
                 bot_source_id: source.id
               })
               |> Repo.insert()

      assert errors_on(changeset) != %{}
    end

    test "unknown is a real answer, not a missing one" do
      assert {:ok, actor} =
               %DevilsDictionary.Sources.Actor{}
               |> DevilsDictionary.Sources.Actor.changeset(%{
                 actor_kind: :unknown,
                 label: "an unattributed 18th-century marginal note"
               })
               |> Repo.insert()

      assert actor.actor_kind == :unknown
      assert is_nil(actor.user_id) and is_nil(actor.entity_id)
    end
  end

  defp actor do
    %DevilsDictionary.Sources.Actor{}
    |> DevilsDictionary.Sources.Actor.changeset(%{actor_kind: :external, label: "curator A"})
    |> Repo.insert()
  end
end
