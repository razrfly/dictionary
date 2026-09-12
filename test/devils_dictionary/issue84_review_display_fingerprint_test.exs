defmodule DevilsDictionary.Issue84ReviewDisplayFingerprintTest do
  @moduledoc "Review acceptance covers every mutable value the connection displays."

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.{Connection, Contributions}
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup do
    Fixtures.seed_catalog!()

    reviewer =
      user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()

    %{reviewer_scope: Scope.for_user(reviewer)}
  end

  test "review becomes stale when displayed entity text changes, but not for undisplayed metadata" do
    artifact = entity(:artifact, "Original artwork")
    meaning = entity(:concept, "Meaning")
    {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", meaning.object_id)
    accept!(claim)

    {accepted, query_count} = count_queries(fn -> Connection.build(claim.id) end)
    assert accepted.review == :accepted
    assert Claims.display_review_states([accepted.revision.id])[accepted.revision.id] == :accepted
    assert query_count <= 24

    Repo.update!(Ecto.Changeset.change(artifact, metadata: %{"internal_note" => "not displayed"}))
    assert Connection.build(claim.id).review == :accepted

    Repo.update!(
      Ecto.Changeset.change(artifact,
        preferred_label: "A DIFFERENT DISPLAYED WORK",
        description: "Changed interpretation"
      )
    )

    page = Connection.build(claim.id)
    assert page.subject.label == "A DIFFERENT DISPLAYED WORK"
    assert page.review == :changed_since_review

    assert Claims.display_review_states([page.revision.id])[page.revision.id] ==
             :changed_since_review
  end

  test "merge to a differently described survivor stales the old endpoint review" do
    artifact = entity(:artifact, "Original artifact")
    survivor = entity(:artifact, "Canonical artifact with different display")
    meaning = entity(:concept, "Merge meaning")
    {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", meaning.object_id)
    accept!(claim)

    assert {:ok, _event} =
             Registry.merge([artifact.object_id], survivor.object_id,
               reason: "Review fingerprint merge"
             )

    page = Connection.build(claim.id)
    assert page.subject.object_id == survivor.object_id
    assert page.subject.merged_from == artifact.object_id
    assert page.review == :changed_since_review
  end

  test "jurisdiction and attribution display changes stale acceptance" do
    artifact = entity(:artifact, "Jurisdiction artifact")
    meaning = entity(:concept, "Jurisdiction meaning")
    jurisdiction = entity(:place, "Original jurisdiction")
    claimant = Repo.insert!(%Actor{actor_kind: :external, label: "Original claimant"})

    {:ok, claim} =
      Claims.assert(artifact.object_id, "illustrates", meaning.object_id, %{
        jurisdiction_entity_id: jurisdiction.object_id,
        origin_actor_id: claimant.id
      })

    accept!(claim)
    assert Connection.build(claim.id).review == :accepted

    Repo.update!(Ecto.Changeset.change(jurisdiction, preferred_label: "Renamed jurisdiction"))
    assert Connection.build(claim.id).review == :changed_since_review

    # A fresh review covers the renamed jurisdiction, then a mutable actor label
    # change independently invalidates that new display context.
    accept!(claim)
    assert Connection.build(claim.id).review == :accepted

    Repo.update!(Ecto.Changeset.change(claimant, label: "Renamed claimant"))
    assert Connection.build(claim.id).review == :changed_since_review
  end

  test "review submission refuses an entity changed after the page snapshot", ctx do
    artifact = entity(:artifact, "Submission artwork")
    meaning = entity(:concept, "Submission meaning")
    {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", meaning.object_id)
    revision = Claims.current_revision(claim.id)
    displayed = Contributions.context_items(revision)

    Repo.update!(Ecto.Changeset.change(artifact, preferred_label: "Changed before submit"))

    assert {:error, :stale_context} =
             Contributions.review(
               ctx.reviewer_scope,
               claim.id,
               revision.id,
               "accepted",
               "Looked at the earlier label",
               displayed
             )

    assert Claims.review_state(revision.id) == :needs_review
  end

  defp entity(kind, label) do
    {:ok, entity} = Registry.create_entity(%{entity_kind: kind, preferred_label: label})
    entity
  end

  defp accept!(claim) do
    revision = Claims.current_revision(claim.id)

    {:ok, context} =
      Claims.open_review_context(revision.id, Claims.current_context_items(revision))

    {:ok, _review} = Claims.review(revision.id, :accepted, %{review_context_id: context.id})
    revision
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "issue84-review-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:devils_dictionary, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {ref, :query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain_queries(ref, 0)}
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
