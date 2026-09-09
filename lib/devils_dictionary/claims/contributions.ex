defmodule DevilsDictionary.Claims.Contributions do
  @moduledoc "Authenticated contribution and reviewer commands; imported assertions use Claims directly."
  import Ecto.Query
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Sources.Actor

  def reviewer?(%{user: %{id: id}}),
    do: Repo.exists?(from u in User, where: u.id == ^id and u.reviewer)

  def reviewer?(_), do: false

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
    [
      {:subject, revision.subject_object_id},
      {:object, revision.object_object_id},
      {:context, revision.context_object_id}
    ]
    |> Enum.flat_map(fn {role, id} ->
      case revision_target(id) do
        nil -> []
        target -> [{role, Enum.sort(target)}]
      end
    end)
  end

  defp revision_target(nil), do: nil

  defp revision_target(id) do
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

  defp actor!(user) do
    # Serializes first-use actor creation for this account.
    Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

    Repo.get_by(Actor, user_id: user.id) ||
      Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Account ##{user.id}"})
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
