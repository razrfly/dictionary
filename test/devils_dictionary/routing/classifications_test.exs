defmodule DevilsDictionary.Routing.ClassificationsTest do
  @moduledoc """
  Versioned decisions and overrides (ADR 0004 §3): exact history, the
  evidence an override describes, and a published address that no decision
  can move.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{Address, ClassificationDecision, Classifications, Resolver}

  setup do
    %{human: human!(), entity: entity!(:person, "Voltaire")}
  end

  test "a result is recorded once, and new evidence supersedes it with history kept", ctx do
    id = ctx.entity.object_id
    result = evaluate(id, "Q5")

    assert {:ok, :recorded, first} = Classifications.record(result)

    assert {first.origin, first.status, first.family, first.rule_ids} ==
             {:evaluator, :mapped, :people, ["people"]}

    assert first.source_pins == [
             %{"qid" => "Q#{9_000_000 + id}", "revision_id" => 1, "checksum" => "fixture-1"}
           ]

    assert {:ok, :unchanged, same} = Classifications.record(result)
    assert same.id == first.id

    assert {:ok, :recorded, second} = Classifications.record(evaluate(id, "Q5", revision: 2))
    assert second.supersedes_id == first.id
    assert second.evidence_fingerprint != first.evidence_fingerprint

    assert [{second.id, true}, {first.id, false}] ==
             Enum.map(Classifications.history(id), &{&1.id, &1.is_current})
  end

  test "review selects no family: an unknown subject never becomes Subjects", ctx do
    decision = leave_unmapped!(ctx.entity.object_id)

    assert {decision.status, decision.family, decision.candidate_families} ==
             {:needs_review, nil, []}

    assert "missing_class:Q1" in decision.warnings
  end

  test "an override is a human's, about the evidence they saw", ctx do
    id = ctx.entity.object_id
    reviewed = leave_unmapped!(id)

    verdict = %{
      status: :mapped,
      family: :people,
      reason: "a person, per biography",
      evidence_fingerprint: reviewed.evidence_fingerprint
    }

    assert Classifications.override(id, verdict, importer!().id) ==
             {:error, :human_reviewer_required}

    assert Classifications.override(
             id,
             %{verdict | evidence_fingerprint: String.duplicate("0", 64)},
             ctx.human.id
           ) ==
             {:error, :stale_evidence}

    assert Classifications.override(id, %{verdict | family: nil, status: :mapped}, ctx.human.id) ==
             {:error, :invalid_verdict}

    assert {:ok, override} = Classifications.override(id, verdict, ctx.human.id)

    assert {override.origin, override.family, override.reviewer_actor_id, override.reason,
            override.evidence_fingerprint, override.supersedes_id} ==
             {:override, :people, ctx.human.id, "a person, per biography",
              reviewed.evidence_fingerprint, reviewed.id}

    replacement = %{verdict | family: :subjects, reason: "a pseudonymous persona"}
    assert {:ok, replaced} = Classifications.override(id, replacement, ctx.human.id)

    assert Enum.map(Classifications.history(id), &{&1.id, &1.origin, &1.family}) == [
             {replaced.id, :override, :subjects},
             {override.id, :override, :people},
             {reviewed.id, :evaluator, nil}
           ]
  end

  test "an override survives reimport until the evidence contradicts it; the address never moves",
       ctx do
    id = ctx.entity.object_id
    reviewed = leave_unmapped!(id)

    {:ok, override} =
      Classifications.override(
        id,
        %{
          status: :mapped,
          family: :people,
          reason: "reviewed",
          evidence_fingerprint: reviewed.evidence_fingerprint
        },
        ctx.human.id
      )

    {:ok, page} = DevilsDictionary.Routing.Pages.ensure(:subject, id)
    page |> allocated!("/people/voltaire", ctx.human) |> published!()
    decisions = Repo.aggregate(ClassificationDecision, :count)

    # The same evidence again, then a new revision that still gives no family.
    assert {:ok, :override_preserved, %{id: same}} = Classifications.record(evaluate(id, "Q1"))

    assert {:ok, :override_preserved, %{id: ^same}} =
             Classifications.record(evaluate(id, "Q1", revision: 2))

    assert same == override.id
    assert Repo.aggregate(ClassificationDecision, :count) == decisions

    # Evidence that now maps to Works contradicts the People override.
    assert {:ok, :override_contradicted, review} =
             Classifications.record(evaluate(id, "Q482994", revision: 3))

    assert {review.status, review.family, review.candidate_families, review.supersedes_id} ==
             {:needs_review, nil, ["works"], override.id}

    assert "override_contradicted" in review.reasons
    refute Repo.get!(ClassificationDecision, override.id).is_current

    assert %{outcome: :canonical, location: "/people/voltaire"} =
             Resolver.resolve(Address.encode("/people/voltaire"))

    consistent!()
  end
end
