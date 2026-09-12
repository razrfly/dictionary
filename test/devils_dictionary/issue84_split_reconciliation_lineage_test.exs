defmodule DevilsDictionary.Issue84SplitReconciliationLineageTest do
  @moduledoc "Split reconciliation advances related cases without masking unrelated edits."

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Sources.ReconciliationCase
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup do
    Fixtures.seed_catalog!()
    :ok
  end

  test "two split cases on one assertion resolve in either mapping order" do
    for order <- [:subject_first, :object_first] do
      %{claim: claim, subject_case: subject_case, object_case: object_case} = split_claim!()
      scope = reviewer_scope!()

      steps =
        case order do
          :subject_first ->
            [
              {subject_case, first_candidate(subject_case)},
              {object_case, first_candidate(object_case)}
            ]

          :object_first ->
            [
              {object_case, first_candidate(object_case)},
              {subject_case, first_candidate(subject_case)}
            ]
        end

      Enum.each(steps, fn {kase, replacement_id} ->
        assert {:ok, resolved} =
                 Contributions.reconcile(
                   scope,
                   kase.id,
                   "map",
                   replacement_id,
                   "The selected output preserves this attachment"
                 )

        assert resolved.status == :resolved
      end)

      [first, second] = Enum.map(steps, &elem(&1, 0))
      rebased = Repo.get!(ReconciliationCase, second.id)
      assert [lineage] = rebased.payload["revision_lineage"]
      assert lineage["via_reconciliation_case_id"] == first.id
      assert lineage["to_assertion_revision_id"] > lineage["from_assertion_revision_id"]

      current = Claims.current_revision(claim.id)
      assert current.revision_number == 3
      assert current.subject_object_id == first_candidate(subject_case)
      assert current.object_object_id == first_candidate(object_case)
      assert length(current.metadata["identity_split_reconciliations"]) == 2
    end
  end

  test "an unrelated semantic revision still makes an open split case stale" do
    %{claim: claim, subject_case: subject_case} = split_claim!()
    scope = reviewer_scope!()

    {:ok, changed} = Claims.revise(claim.id, %{rationale: "An unrelated semantic correction"})

    assert {:error, :stale_revision} =
             Contributions.reconcile(
               scope,
               subject_case.id,
               "map",
               first_candidate(subject_case),
               "This was based on the earlier assertion"
             )

    assert Repo.get!(ReconciliationCase, subject_case.id).status == :open
    assert Claims.current_revision(claim.id).id == changed.id
  end

  @tag :unboxed
  test "concurrent reviewers can resolve different cases without deadlock or lost mapping" do
    %{claim: claim, subject_case: subject_case, object_case: object_case} = split_claim!()
    subject_scope = reviewer_scope!()
    object_scope = reviewer_scope!()
    parent = self()

    subject_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        end

        Contributions.reconcile(
          subject_scope,
          subject_case.id,
          "map",
          first_candidate(subject_case),
          "Concurrent subject decision"
        )
      end)

    object_task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        end

        Contributions.reconcile(
          object_scope,
          object_case.id,
          "map",
          first_candidate(object_case),
          "Concurrent object decision"
        )
      end)

    assert_receive {:ready, subject_pid}
    assert_receive {:ready, object_pid}
    send(subject_pid, :go)
    send(object_pid, :go)

    assert {:ok, %ReconciliationCase{status: :resolved}} = Task.await(subject_task, 10_000)
    assert {:ok, %ReconciliationCase{status: :resolved}} = Task.await(object_task, 10_000)

    current = Claims.current_revision(claim.id)
    assert current.revision_number == 3
    assert current.subject_object_id == first_candidate(subject_case)
    assert current.object_object_id == first_candidate(object_case)
  end

  defp split_claim! do
    subject = entity!(:artifact, "Split subject")
    subject_a = entity!(:artifact, "Split subject A")
    subject_b = entity!(:artifact, "Split subject B")
    object = entity!(:concept, "Split object")
    object_a = entity!(:concept, "Split object A")
    object_b = entity!(:concept, "Split object B")
    {:ok, claim} = Claims.assert(subject.object_id, "illustrates", object.object_id)

    {:ok, _} =
      Registry.split(subject.object_id, [subject_a.object_id, subject_b.object_id],
        reason: "Subject identity split"
      )

    {:ok, _} =
      Registry.split(object.object_id, [object_a.object_id, object_b.object_id],
        reason: "Object identity split"
      )

    cases =
      Repo.all(
        from kase in ReconciliationCase,
          where: kase.assertion_id == ^claim.id,
          order_by: kase.id
      )

    %{
      claim: claim,
      subject_case: Enum.find(cases, &(&1.object_id == subject.object_id)),
      object_case: Enum.find(cases, &(&1.object_id == object.object_id))
    }
  end

  defp first_candidate(kase), do: List.first(kase.payload["candidate_output_ids"])

  defp reviewer_scope! do
    user = user_fixture() |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()
    Scope.for_user(user)
  end

  defp entity!(kind, label) do
    {:ok, entity} = Registry.create_entity(%{entity_kind: kind, preferred_label: label})
    entity
  end
end
