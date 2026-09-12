defmodule DevilsDictionaryWeb.Issue84Checkpoint4AcceptanceTest do
  @moduledoc "Issue #84's connected durability acceptance walk."

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.{Connection, Contributions}
  alias DevilsDictionary.Sources.ReconciliationCase
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()

    contributor =
      user_fixture()
      |> Ecto.Changeset.change(internal_contributor: true)
      |> Repo.update!()

    reviewer =
      user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()

    %{
      conn: log_in_user(conn, contributor),
      sources: sources,
      contributor_scope: Scope.for_user(contributor),
      reviewer_scope: Scope.for_user(reviewer)
    }
  end

  test "create → cite → review → challenge survives refresh, withdrawal, merge and split", ctx do
    {:ok, artifact} =
      Contributions.create_local_entity(ctx.contributor_scope, %{
        entity_kind: "artifact",
        preferred_label: "Family Table acceptance artwork",
        source_url: "https://museum.example/family-table"
      })

    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: "nepotism-acceptance",
        part_of_speech: "noun"
      })

    {:ok, meaning} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: ctx.sources["wordnet"].id,
        external_key: "nepotism-acceptance.n.01",
        gloss: "favoritism toward relatives"
      })

    support_a = source_passage!(ctx.sources["wiktionary"].id, "Museum catalogue evidence")
    support_b = source_passage!(ctx.sources["wordnet"].id, "Independent archive evidence")
    counter = source_passage!(ctx.sources["bierce"].id, "A critic's counter-reading")

    assert {:ok, claim} =
             Contributions.propose(
               ctx.contributor_scope,
               artifact.object_id,
               "illustrates",
               meaning.object_id,
               %{
                 rationale: "The fictional arrangement depicts preferential family treatment.",
                 claimant: :unknown,
                 context_object_id: meaning.object_id,
                 language_tag: "en"
               },
               [
                 exact(support_a, :supports, "catalogue paragraph 2"),
                 exact(support_b, :supports, "archive page 7")
               ]
             )

    first = Claims.current_revision(claim.id)
    accept!(ctx.reviewer_scope, claim.id, first)
    assert Connection.build(claim.id).review == :accepted

    {:ok, detail, _html} = live(build_conn(), ~p"/connections/#{claim.id}")
    assert has_element?(detail, "#connection-review", "accepted")
    assert has_element?(detail, "#connection-evidence", "catalogue paragraph 2")

    artifact_path =
      ~p"/entities/#{artifact.object_id}/#{Connection.slugify(artifact.preferred_label)}"

    {:ok, artifact_view, _html} = live(build_conn(), artifact_path)
    assert has_element?(artifact_view, "#connection-out-#{claim.id}")
    assert [seen] = Claims.incoming(meaning.object_id, predicate: "illustrates")
    assert seen.assertion_id == claim.id

    challenger =
      user_fixture()
      |> Ecto.Changeset.change(internal_contributor: true)
      |> Repo.update!()

    assert {:ok, challenged} =
             Contributions.challenge(
               Scope.for_user(challenger),
               claim.id,
               first.id,
               "The critic identifies a different interpretation.",
               [exact(counter, :supports, "review paragraph 4")]
             )

    assert challenged.revision_number == 2
    assert Claims.display_review_state(challenged.id) == :needs_review
    accept!(ctx.reviewer_scope, claim.id, challenged)
    assert Connection.build(claim.id).review == :accepted

    # A source refresh does not mutate the selected evidence revision or silently
    # carry the old approval onto the changed display context.
    cited_a = Registry.current_content_revision(support_a.object_id)

    {:ok, _refreshed} =
      Registry.add_content_revision(support_a.object_id, %{
        body: "Museum catalogue evidence, corrected after review"
      })

    assert Connection.build(claim.id).review == :changed_since_review
    assert Enum.any?(Claims.evidence(challenged.id), &(&1.content_revision_id == cited_a.id))

    # The other source then withdraws. Both immutable citations remain in the
    # claim history; the surviving source and the editorial history remain too.
    cited_b = Registry.current_content_revision(support_b.object_id)

    {:ok, _withdrawn} =
      Registry.add_content_revision(support_b.object_id, %{
        body: "Withdrawn archive evidence",
        lifecycle_state: :withdrawn
      })

    retained = Claims.evidence(challenged.id)
    assert Enum.any?(retained, &(&1.content_revision_id == cited_b.id))
    assert Enum.count(retained, &(&1.evidence_role == :supports)) == 2
    assert Connection.build(claim.id).review == :changed_since_review

    # Merging the artifact changes no historical endpoint. The survivor's page
    # aggregates the old attachment, and the old URL remains meaningful.
    {:ok, survivor} =
      Registry.create_entity(%{
        entity_kind: :artifact,
        preferred_label: "Family Table canonical artwork"
      })

    assert {:ok, _event} =
             Registry.merge([artifact.object_id], survivor.object_id,
               reason: "Duplicate local catalogue identity"
             )

    assert Claims.current_revision(claim.id).subject_object_id == artifact.object_id
    assert Connection.build(claim.id).subject.object_id == survivor.object_id
    assert Enum.any?(Claims.outgoing(survivor.object_id), &(&1.assertion_id == claim.id))

    merged_path =
      ~p"/entities/#{artifact.object_id}/#{Connection.slugify(survivor.preferred_label)}"

    {:ok, merged_view, _html} = live(build_conn(), merged_path)
    assert has_element?(merged_view, "#entity-merged-notice")
    assert has_element?(merged_view, "#connection-out-#{claim.id}")

    # The selected meaning also served as context. Splitting it creates one
    # explicit case carrying both roles; nothing guesses which meaning wins.
    first_choice = split_sense!(lexeme, ctx.sources["wordnet"].id, "family favoritism")
    second_choice = split_sense!(lexeme, ctx.sources["wordnet"].id, "institutional favoritism")

    assert {:ok, _event} =
             Registry.split(meaning.object_id, [first_choice.object_id, second_choice.object_id],
               reason: "The source separated two meanings"
             )

    assert Connection.build(claim.id) == nil
    kase = Repo.get_by!(ReconciliationCase, assertion_id: claim.id)

    assert Enum.sort(kase.payload["attachment_roles"]) == [
             "context",
             "object",
             "review_context"
           ]

    assert {:ok, resolved} =
             Contributions.reconcile(
               ctx.reviewer_scope,
               kase.id,
               :map,
               first_choice.object_id,
               "The cited wording is explicitly about family favoritism"
             )

    assert resolved.status == :resolved
    current = Claims.current_revision(claim.id)
    assert current.revision_number == 3
    assert current.object_object_id == first_choice.object_id
    assert current.context_object_id == first_choice.object_id
    assert Claims.display_review_state(current.id) == :needs_review
    assert Claims.incoming(second_choice.object_id, predicate: "illustrates") == []
    assert Enum.any?(Claims.incoming(first_choice.object_id), &(&1.assertion_id == claim.id))
    assert Enum.map(Claims.history(claim.id), & &1.revision_number) == [1, 2, 3]

    {:ok, final_detail, _html} = live(build_conn(), ~p"/connections/#{claim.id}")
    assert has_element?(final_detail, "#connection-review", "needs_review")
    assert has_element?(final_detail, "#connection-counterevidence", "review paragraph 4")

    survivor_path =
      ~p"/entities/#{survivor.object_id}/#{Connection.slugify(survivor.preferred_label)}"

    {:ok, survivor_view, _html} = live(build_conn(), survivor_path)
    assert has_element?(survivor_view, "#connection-out-#{claim.id}")
  end

  test "the post-baseline adaptation relationship is available through the ordinary composer",
       ctx do
    {:ok, original} =
      Registry.create_work(%{
        preferred_label: "Extension Original Needle",
        work_kind: "novel"
      })

    {:ok, adaptation} =
      Registry.create_work(%{
        preferred_label: "Extension Adaptation Needle",
        work_kind: "film"
      })

    {:ok, artifact} =
      Registry.create_entity(%{
        entity_kind: :artifact,
        preferred_label: "Extension Artifact Needle"
      })

    {:ok, view, _html} = live(ctx.conn, ~p"/connect")
    view |> form("#subject-search", %{"q" => adaptation.preferred_label}) |> render_change()
    view |> element("#composer-subject-hit-#{adaptation.object_id}") |> render_click()
    assert has_element?(view, "#predicate-adaptation_of")
    view |> element("#predicate-adaptation_of") |> render_click()
    view |> form("#object-search", %{"q" => "Extension"}) |> render_change()
    assert has_element?(view, "#composer-object-hit-#{original.object_id}")
    refute has_element?(view, "#composer-object-hit-#{artifact.object_id}")
    view |> element("#composer-object-hit-#{original.object_id}") |> render_click()

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#composer-form", %{
               "rationale" => "The film deliberately adapts the fictional novel."
             })
             |> render_submit()

    {:ok, detail, _html} = live(build_conn(), to)
    assert has_element?(detail, "#connection-header", "an adaptation of")
  end

  defp source_passage!(source_id, body) do
    {:ok, content} =
      Registry.create_content(%{content_kind: :passage, source_id: source_id, body: body})

    content
  end

  defp split_sense!(lexeme, source_id, gloss) do
    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: source_id,
        external_key: "split-#{System.unique_integer([:positive])}",
        gloss: gloss
      })

    sense
  end

  defp exact(content, role, locator) do
    %{
      content_revision_id: Registry.current_content_revision(content.object_id).id,
      evidence_role: role,
      locator: locator
    }
  end

  defp accept!(scope, assertion_id, revision) do
    assert {:ok, _review} =
             Contributions.review(
               scope,
               assertion_id,
               revision.id,
               "accepted",
               "Checked against the exact cited versions",
               Contributions.context_items(revision)
             )
  end
end
