defmodule DevilsDictionary.Claims.Contributions do
  @moduledoc "Authenticated contribution and reviewer commands; imported assertions use Claims directly."
  import Ecto.Query
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Sources.{Actor, ReconciliationCase}

  def reviewer?(%{user: %{id: id}}),
    do: Repo.exists?(from u in User, where: u.id == ^id and u.reviewer)

  def reviewer?(_), do: false

  def internal_contributor?(%{user: %{id: id}}),
    do:
      Repo.exists?(
        from u in User,
          where: u.id == ^id and (u.internal_contributor or u.reviewer)
      )

  def internal_contributor?(_), do: false

  def propose(%{user: %{id: id}}, subject, predicate, object, attrs, evidence_id, locator) do
    Repo.transaction(fn ->
      user = Repo.get!(User, id)
      actor = actor!(user)
      if String.trim(attrs[:rationale] || "") == "", do: Repo.rollback(:rationale_required)

      if String.trim(locator || "") != "" and is_nil(evidence_id),
        do: Repo.rollback(:evidence_required)

      attrs = Map.take(attrs, [:rationale, :context_object_id, :valid_from, :valid_to])

      attrs =
        Map.merge(attrs, %{
          submitted_by_actor_id: actor.id,
          origin_actor_id: actor.id,
          method: "curated"
        })

      claim = unwrap(Claims.assert(subject, predicate, object, attrs))
      revision = Claims.current_revision(claim.id)

      if evidence_id do
        target = revision_target(evidence_id)
        if is_nil(target), do: Repo.rollback(:invalid_evidence)

        unwrap(
          Claims.add_evidence(
            revision.id,
            Map.merge(target, %{
              locator: locator,
              attribution_text: "Submitted by account ##{user.id}"
            })
          )
        )
      end

      claim
    end)
  end

  def propose(_, _, _, _, _, _, _), do: {:error, :unauthorized}

  def review(scope, assertion_id, revision_id, decision, reason, displayed_items) do
    if reviewer?(scope) do
      Repo.transaction(fn ->
        # Recheck the role while locked, so a revoked reviewer cannot act through an old LiveView.
        user = Repo.one!(from u in User, where: u.id == ^scope.user.id, lock: "FOR UPDATE")
        unless user.reviewer, do: Repo.rollback(:unauthorized)
        Repo.query!("SELECT id FROM assertions WHERE id = $1 FOR UPDATE", [assertion_id])
        current = Claims.current_revision(assertion_id)
        if is_nil(current) or current.id != revision_id, do: Repo.rollback(:stale_revision)
        if String.trim(reason || "") == "", do: Repo.rollback(:reason_required)
        unless decision in ~w(accepted disputed rejected), do: Repo.rollback(:invalid_decision)
        if context_items(current) != displayed_items, do: Repo.rollback(:stale_context)
        context = unwrap(Claims.open_review_context(revision_id, displayed_items))

        unwrap(
          Claims.review(revision_id, decision, %{
            reason: reason,
            reviewer_actor_id: actor!(user).id,
            review_context_id: context.id
          })
        )
      end)
    else
      {:error, :unauthorized}
    end
  end

  def context_items(revision) do
    Claims.current_context_items(revision)
  end

  @doc "The exact current revision target for a content item or sense."
  def revision_target(nil), do: nil

  def revision_target(id) do
    case Registry.current_content_revision(id) do
      %{id: revision_id} ->
        %{content_revision_id: revision_id}

      nil ->
        case Registry.current_sense_revision(id) do
          %{id: revision_id} -> %{sense_revision_id: revision_id}
          nil -> nil
        end
    end
  end

  @doc "Open split-reconciliation cases, available only to current reviewers."
  def list_reconciliation_cases(scope) do
    if reviewer?(scope) do
      Repo.all(
        from c in ReconciliationCase,
          where: c.status == :open and c.kind == "identity_split",
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:object, :assertion]
      )
    else
      []
    end
  end

  @doc """
  Records a deliberate split decision without rewriting history.

  Mapping creates a new assertion revision and copies its exact evidence,
  replacing only evidence that cited the split identity. Leaving unresolved
  keeps the case open with an accountable note. Declining dismisses the case.
  """
  def reconcile(scope, case_id, decision, replacement_id, reason) do
    if reviewer?(scope) do
      Repo.transaction(fn ->
        user = Repo.one!(from u in User, where: u.id == ^scope.user.id, lock: "FOR UPDATE")
        unless user.reviewer, do: Repo.rollback(:unauthorized)

        reason = String.trim(reason || "")
        if reason == "", do: Repo.rollback(:reason_required)

        kase =
          Repo.one!(from c in ReconciliationCase, where: c.id == ^case_id, lock: "FOR UPDATE")

        if kase.status != :open, do: Repo.rollback(:case_closed)

        actor = actor!(user)

        case to_string(decision) do
          "map" -> map_reconciliation(kase, replacement_id, reason, actor)
          "unresolved" -> note_unresolved(kase, reason, actor)
          "decline" -> close_reconciliation(kase, :dismissed, nil, reason, actor)
          _ -> Repo.rollback(:invalid_decision)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  defp map_reconciliation(kase, replacement_id, reason, actor) do
    replacement_id = parse_id(replacement_id)
    candidates = kase.payload["candidate_output_ids"] || []

    unless replacement_id in candidates, do: Repo.rollback(:invalid_replacement)

    unless Registry.object(replacement_id).lifecycle_state == :active,
      do: Repo.rollback(:invalid_replacement)

    revision_id = kase.payload["assertion_revision_id"]
    current = Claims.current_revision(kase.assertion_id)

    if is_nil(current) or current.id != revision_id, do: Repo.rollback(:stale_revision)

    roles = kase.payload["attachment_roles"] || List.wrap(kase.payload["endpoint_role"])

    attrs =
      roles
      |> Enum.reduce(%{}, fn
        "subject", acc -> Map.put(acc, :subject_object_id, replacement_id)
        "object", acc -> Map.put(acc, :object_object_id, replacement_id)
        "context", acc -> Map.put(acc, :context_object_id, replacement_id)
        "jurisdiction", acc -> Map.put(acc, :jurisdiction_entity_id, replacement_id)
        _role, acc -> acc
      end)
      |> Map.put(
        :metadata,
        Map.put(current.metadata || %{}, "identity_split_reconciliation", %{
          "case_id" => kase.id,
          "from_object_id" => kase.object_id,
          "to_object_id" => replacement_id,
          "reason" => reason
        })
      )

    revision = unwrap(Claims.revise(kase.assertion_id, attrs))
    copy_reconciled_evidence(current, revision, kase.object_id, replacement_id)
    close_reconciliation(kase, :resolved, replacement_id, reason, actor)
  end

  defp copy_reconciled_evidence(from_revision, to_revision, split_id, replacement_id) do
    Enum.each(Claims.evidence(from_revision.id), fn evidence ->
      attrs =
        evidence
        |> Map.take([
          :source_record_revision_id,
          :content_revision_id,
          :sense_revision_id,
          :evidence_role,
          :locator,
          :attribution_text
        ])
        |> replace_split_evidence(split_id, replacement_id)

      unwrap(Claims.add_evidence(to_revision.id, attrs))
    end)
  end

  defp replace_split_evidence(%{content_revision_id: id} = attrs, split_id, replacement_id)
       when not is_nil(id) do
    cited = Repo.get!(Registry.ContentRevision, id)

    if cited.content_id == split_id do
      attrs
      |> Map.put(:content_revision_id, revision_target(replacement_id)[:content_revision_id])
      |> Map.put(:sense_revision_id, nil)
    else
      attrs
    end
  end

  defp replace_split_evidence(%{sense_revision_id: id} = attrs, split_id, replacement_id)
       when not is_nil(id) do
    cited = Repo.get!(Registry.SenseRevision, id)

    if cited.sense_id == split_id do
      attrs
      |> Map.put(:sense_revision_id, revision_target(replacement_id)[:sense_revision_id])
      |> Map.put(:content_revision_id, nil)
    else
      attrs
    end
  end

  defp replace_split_evidence(attrs, _split_id, _replacement_id), do: attrs

  defp note_unresolved(kase, reason, actor) do
    payload = put_case_decision(kase.payload, "unresolved", nil, reason, actor)
    kase |> ReconciliationCase.changeset(%{payload: payload}) |> Repo.update!()
  end

  defp close_reconciliation(kase, status, replacement_id, reason, actor) do
    payload =
      put_case_decision(kase.payload, to_string(status), replacement_id, reason, actor)

    kase
    |> ReconciliationCase.changeset(%{
      status: status,
      payload: payload,
      resolved_by_actor_id: actor.id,
      resolved_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()
  end

  defp put_case_decision(payload, decision, replacement_id, reason, actor) do
    Map.put(payload, "decision", %{
      "kind" => decision,
      "replacement_object_id" => replacement_id,
      "reason" => reason,
      "actor_id" => actor.id,
      "recorded_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
    })
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp actor!(user) do
    # Serializes first-use actor creation for this account.
    Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

    Repo.get_by(Actor, user_id: user.id) ||
      Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Account ##{user.id}"})
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
