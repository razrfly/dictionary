defmodule DevilsDictionary.Issue84Checkpoint1Test do
  @moduledoc """
  Permanent regressions for issue #84 checkpoint 1.

  The first seven cases are the formerly separate #73 audit reproductions. The
  surrounding cases pin the policy edges that must not be weakened to make the
  five failures disappear.
  """

  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.{Connection, Contributions}
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Sources.{Actor, ReconciliationCase}
  alias DevilsDictionary.{Claims, Registry, Repo}

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    :ok
  end

  defp person(label), do: Registry.create_person(%{preferred_label: label})

  defp actor(label) do
    Repo.insert!(%Actor{actor_kind: :external, label: label})
  end

  defp accepted_with_context(claim) do
    revision = Claims.current_revision(claim.id)

    {:ok, context} =
      Claims.open_review_context(revision.id, Claims.current_context_items(revision))

    {:ok, _} = Claims.review(revision.id, :accepted, %{review_context_id: context.id})
    revision
  end

  describe "the former seven-case audit" do
    test "rejected biography relationship is hidden from person page" do
      {:ok, p} = person("Audit person")
      {:ok, article} = Registry.create_content(%{content_kind: :article, body: "Audit biography"})
      {:ok, claim} = Claims.assert(article.object_id, "about", p.object_id)
      {:ok, _} = Claims.review(Claims.current_revision(claim.id).id, :rejected)
      assert Claims.incoming(p.object_id, predicate: "about") == []
      assert EntityPage.build(p.object_id).biography == []
    end

    test "merged identity resolves on public person builder" do
      {:ok, old} = person("Old identity")
      {:ok, survivor} = person("Surviving identity")
      {:ok, _} = Registry.merge([old.object_id], survivor.object_id, reason: "Audit merge")
      assert {:merged, survivor.object_id} == Registry.resolve(old.object_id)
      assert EntityPage.build(old.object_id).entity.object_id == survivor.object_id
    end

    test "splitting a claim context opens reconciliation" do
      {:ok, context} = person("Context identity")
      {:ok, first} = person("First identity")
      {:ok, second} = person("Second identity")
      {:ok, work} = Registry.create_work(%{preferred_label: "Audit work"})

      {:ok, claim} =
        Claims.assert(work.object_id, "authored_by", first.object_id, %{
          context_object_id: context.object_id
        })

      {:ok, _} =
        Registry.split(context.object_id, [first.object_id, second.object_id],
          reason: "Audit split"
        )

      assert Repo.exists?(from c in ReconciliationCase, where: c.assertion_id == ^claim.id)
    end

    test "withdrawn content is not displayed in biography" do
      {:ok, p} = person("Audit withdrawn")

      {:ok, article} =
        Registry.create_content(%{
          content_kind: :article,
          body: "Withdrawn text",
          lifecycle_state: :withdrawn
        })

      {:ok, _} = Claims.assert(article.object_id, "about", p.object_id)

      {:ok, _} =
        Registry.add_content_revision(article.object_id, %{
          body: "Withdrawn text",
          lifecycle_state: :withdrawn
        })

      assert EntityPage.build(p.object_id).biography == []
    end

    test "merged input page does not continue presenting a separate identity" do
      {:ok, old} = person("Old display identity")
      {:ok, survivor} = person("Survivor display identity")
      {:ok, _} = Registry.merge([old.object_id], survivor.object_id, reason: "Audit merge")
      assert EntityPage.build(old.object_id).entity.object_id == survivor.object_id
    end

    test "rejected defines relationship is hidden from authored definition summary" do
      {:ok, p} = person("Audit author")

      {:ok, word} =
        Registry.create_lexeme(%{
          language_tag: "en",
          lemma: "auditword",
          part_of_speech: "noun"
        })

      {:ok, definition} =
        Registry.create_content(%{content_kind: :definition, body: "Audit definition"})

      {:ok, _} = Claims.assert(definition.object_id, "authored_by", p.object_id)
      {:ok, claim} = Claims.assert(definition.object_id, "defines", word.object_id)
      {:ok, _} = Claims.review(Claims.current_revision(claim.id).id, :rejected)
      assert Claims.outgoing(definition.object_id, predicate: "defines") == []
      assert hd(EntityPage.build(p.object_id).definitions).defines == nil
    end

    test "changed endpoint text does not display an old review as current acceptance" do
      {:ok, p} = person("Audit reviewed author")

      {:ok, article} =
        Registry.create_content(%{content_kind: :article, body: "Original biography"})

      {:ok, claim} = Claims.assert(article.object_id, "about", p.object_id)
      accepted_with_context(claim)

      {:ok, _} =
        Registry.add_content_revision(article.object_id, %{body: "Materially changed biography"})

      page = Connection.build(claim.id)
      assert page.subject.detail == "Materially changed biography"
      assert page.review == :changed_since_review
    end
  end

  describe "one public visibility policy" do
    test "pending and disputed remain visible and distinct; rejected and withdrawn do not count" do
      {:ok, subject} =
        Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Example"})

      {:ok, object} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "Meaning"})
      {:ok, pending} = Claims.assert(subject.object_id, "illustrates", object.object_id)
      revision = Claims.current_revision(pending.id)

      assert Claims.count_outgoing(subject.object_id) == 1
      assert Connection.build(pending.id).review == :needs_review

      {:ok, review_context} =
        Claims.open_review_context(revision.id, Claims.current_context_items(revision))

      {:ok, _} =
        Claims.review(revision.id, :disputed, %{review_context_id: review_context.id})

      assert Claims.count_outgoing(subject.object_id) == 1
      assert Connection.build(pending.id).review == :disputed

      {:ok, _} = Claims.review(revision.id, :rejected)
      assert Claims.count_outgoing(subject.object_id) == 0
      assert Connection.build(pending.id) == nil
      assert Claims.count_outgoing(subject.object_id, visibility: :internal) == 1

      {:ok, _} = Claims.withdraw(pending.id, reason: "claimant withdrew it")
      assert Claims.count_outgoing(subject.object_id) == 0
    end

    test "rights restrictions redact bodies and excerpts but retain identity metadata" do
      {:ok, p} = person("Rights subject")

      {:ok, article} =
        Registry.create_content(%{
          content_kind: :article,
          headword: "Restricted biography",
          body: "This body must not be shown.",
          canonical_url: "https://example.test/source",
          rights_metadata: %{"display" => "metadata_only"}
        })

      {:ok, _} = Claims.assert(article.object_id, "about", p.object_id)
      [view] = EntityPage.build(p.object_id).biography

      assert view.headword == "Restricted biography"
      assert view.url == "https://example.test/source"
      assert view.body == nil
      assert view.display_restricted?

      endpoint = Connection.endpoint(article.object_id)
      assert endpoint.label == "Restricted biography"
      assert endpoint.detail == "Text withheld by rights metadata"
    end
  end

  describe "safe identity changes" do
    test "merge chains resolve canonically and aggregate historical relationships" do
      {:ok, first} = person("First alias")
      {:ok, middle} = person("Middle identity")
      {:ok, final} = person("Final identity")
      {:ok, work} = Registry.create_work(%{preferred_label: "Old attachment"})
      {:ok, claim} = Claims.assert(work.object_id, "authored_by", first.object_id)
      {:ok, _} = Registry.add_external_id(first.object_id, "example", "person-1")

      {:ok, first_merge} =
        Registry.merge([first.object_id], middle.object_id, reason: "duplicate")

      {:ok, _} = Registry.merge([middle.object_id], final.object_id, reason: "same identity")

      assert first_merge.actor_id
      assert Registry.resolve(first.object_id) == {:merged, final.object_id}
      assert Registry.by_external_id("example", "person-1") == final.object_id

      assert Enum.sort(Registry.canonical_family(final.object_id)) ==
               Enum.sort([first.object_id, middle.object_id, final.object_id])

      assert Enum.any?(Claims.incoming(final.object_id, predicate: "authored_by"), fn revision ->
               revision.assertion_id == claim.id
             end)

      assert Enum.any?(EntityPage.build(final.object_id).works, &(&1.object_id == work.object_id))
    end

    test "invalid, repeated and incompatible operations are refused" do
      {:ok, one} = person("One")
      {:ok, two} = person("Two")

      {:ok, concept} =
        Registry.create_entity(%{entity_kind: :concept, preferred_label: "Concept"})

      assert {:error, :inputs_required} = Registry.merge([], two.object_id, reason: "none")

      assert {:error, :output_cannot_be_input} =
               Registry.merge([one.object_id], one.object_id, reason: "cycle")

      assert {:error, :incompatible_kinds} =
               Registry.merge([one.object_id], concept.object_id, reason: "wrong kinds")

      assert {:error, :reason_required} = Registry.merge([one.object_id], two.object_id)
      assert {:ok, _} = Registry.merge([one.object_id], two.object_id, reason: "duplicate")

      assert {:error, :object_not_active} =
               Registry.merge([one.object_id], two.object_id, reason: "repeat")

      {:ok, three} = person("Three")

      assert {:error, :multiple_outputs_required} =
               Registry.split(three.object_id, [two.object_id], reason: "not a split")
    end

    test "reviewer can keep a split unresolved and later map it with a new revision" do
      user = DevilsDictionary.AccountsFixtures.user_fixture()
      user = Repo.update!(Ecto.Changeset.change(user, reviewer: true))
      scope = Scope.for_user(user)
      {:ok, context} = person("Ambiguous context")
      {:ok, first} = person("Context A")
      {:ok, second} = person("Context B")
      {:ok, author} = person("Author")
      {:ok, work} = Registry.create_work(%{preferred_label: "Contextual work"})

      {:ok, claim} =
        Claims.assert(work.object_id, "authored_by", author.object_id, %{
          context_object_id: context.object_id
        })

      original = Claims.current_revision(claim.id)

      {:ok, _} =
        Registry.split(context.object_id, [first.object_id, second.object_id],
          reason: "two contexts"
        )

      kase = Repo.get_by!(ReconciliationCase, assertion_id: claim.id)

      assert {:ok, unresolved} =
               Contributions.reconcile(
                 scope,
                 kase.id,
                 :unresolved,
                 nil,
                 "evidence is inconclusive"
               )

      assert unresolved.status == :open
      assert unresolved.payload["decision"]["kind"] == "unresolved"

      assert {:ok, resolved} =
               Contributions.reconcile(
                 scope,
                 kase.id,
                 :map,
                 first.object_id,
                 "the cited event names Context A"
               )

      current = Claims.current_revision(claim.id)
      assert current.context_object_id == first.object_id
      assert current.id != original.id
      assert Claims.review_state(current.id) == :needs_review
      assert resolved.status == :resolved
      assert resolved.resolved_by_actor_id
      assert Enum.at(Claims.history(claim.id), 0).context_object_id == context.object_id
    end
  end

  describe "approval covers exactly the displayed version" do
    test "attribution and evidence changes stale an accepted snapshot; an unchanged read does not" do
      claimant = actor("Original claimant")
      replacement = actor("Replacement claimant")

      {:ok, subject} =
        Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Artifact"})

      {:ok, object} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "Concept"})
      {:ok, evidence} = Registry.create_content(%{content_kind: :passage, body: "Evidence"})

      {:ok, claim} =
        Claims.assert(subject.object_id, "illustrates", object.object_id, %{
          origin_actor_id: claimant.id
        })

      revision = Claims.current_revision(claim.id)
      target = %{content_revision_id: Registry.current_content_revision(evidence.object_id).id}
      {:ok, _} = Claims.add_evidence(revision.id, target)
      accepted_with_context(claim)

      assert Connection.build(claim.id).review == :accepted
      assert Connection.build(claim.id).review == :accepted

      claim
      |> Ecto.Changeset.change(origin_actor_id: replacement.id)
      |> Repo.update!()

      assert Connection.build(claim.id).review == :changed_since_review

      {:ok, extra} = Registry.create_content(%{content_kind: :passage, body: "Counterevidence"})

      {:ok, _} =
        Claims.add_evidence(revision.id, %{
          content_revision_id: Registry.current_content_revision(extra.object_id).id,
          evidence_role: :contradicts
        })

      assert Connection.build(claim.id).review == :changed_since_review
    end

    test "evidence withdrawal marks the displayed approval stale" do
      {:ok, subject} =
        Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Artifact"})

      {:ok, object} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "Concept"})
      {:ok, evidence} = Registry.create_content(%{content_kind: :passage, body: "Quoted source"})
      {:ok, claim} = Claims.assert(subject.object_id, "illustrates", object.object_id)
      revision = Claims.current_revision(claim.id)

      {:ok, _} =
        Claims.add_evidence(revision.id, %{
          content_revision_id: Registry.current_content_revision(evidence.object_id).id
        })

      accepted_with_context(claim)
      assert Connection.build(claim.id).review == :accepted

      {:ok, _} =
        Registry.add_content_revision(evidence.object_id, %{
          body: "Source withdrawn",
          lifecycle_state: :withdrawn
        })

      assert Connection.build(claim.id).review == :changed_since_review
    end
  end
end
