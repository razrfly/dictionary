defmodule DevilsDictionary.Curation.Reviews do
  @moduledoc """
  Human presentation review of composition versions (R1, R2).

  Only an account with the reviewer role decides. The role is rechecked
  under a row lock, and the database checks it again. There is no bot
  approver.

  Decisions are append-only, and the latest one is the version's state. An
  idempotency key replays its own decision and refuses a different one.

  **Acceptance is not publication.** Accepting a version:

    * writes no pointer, no publication receipt, no `assertion_reviews` row
      and no page row;
    * says the arrangement may be shown, not that any claim in it is true;
    * is refused unless the version still stands (`Standing`). Its
      configuration, its scope and its eligibility must all be as it was
      made. What was accepted is recorded as the version's eligibility
      fingerprint.
  """

  alias DevilsDictionary.Curation.{
    Authority,
    CompositionReview,
    CompositionVersion,
    Standing,
    Transaction
  }

  alias DevilsDictionary.Repo

  @doc """
  Records `decision` (`:accepted`, `:rejected`, `:withdrawn` or
  `:needs_review`) on a version, as a reviewer. `opts`: `:reason`,
  `:idempotency_key`.
  """
  def decide(scope, version_id, decision, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           :ok <- Transaction.check(decision in CompositionReview.decisions(), :unknown_decision),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, key} <- Transaction.required(opts, :idempotency_key),
           {:ok, version} <-
             Transaction.need(Repo.get(CompositionVersion, version_id), :not_found),
           {:ok, composition} <- Standing.lock_composition(version.composition_id),
           :fresh <-
             Transaction.replay(CompositionReview, key, fn r ->
               r.composition_version_id == version.id and r.decision == decision
             end) do
        evaluation = Standing.evaluate(version, composition)

        with :ok <- acceptable(decision, version, composition, evaluation) do
          {:ok,
           Repo.insert!(%CompositionReview{
             composition_id: composition.id,
             composition_version_id: version.id,
             reviewer_actor_id: actor.id,
             decision: decision,
             reason: reason,
             reviewed_eligibility_fingerprint: evaluation.fingerprint,
             idempotency_key: key
           })}
        end
      else
        {:replay, review} -> {:ok, review}
        error -> error
      end
    end)
  end

  defp acceptable(:accepted, version, composition, evaluation) do
    with :ok <- Transaction.check(composition.state == :active, :composition_retired),
         :ok <- Standing.scope(version, composition),
         :ok <- Standing.configuration(version) do
      Standing.eligible(evaluation, version)
    end
  end

  defp acceptable(_decision, _version, _composition, _evaluation), do: :ok
end
