defmodule DevilsDictionary.Curation.Publications do
  @moduledoc """
  Explicit, transactional publication of composition versions (R3–R5).

  `publish/3` is one reviewer action in one transaction:

    1. rechecks the reviewer role under the account row lock;
    2. locks the composition row;
    3. replays an idempotency key it has already used, or refuses a
       different use of it;
    4. checks the **expected pointer** the caller saw (`{:stale_pointer,
       current}`);
    5. checks the version still stands: same scope, same configuration
       version, a clean evaluation to its own eligibility fingerprint;
    6. checks the version's **latest** review is an acceptance of that
       fingerprint;
    7. writes the receipt and moves the pointer.

  The database repeats what matters. The receipt must name the latest,
  accepting review of the version it publishes. The pointer must equal its
  latest receipt at commit, and each receipt must continue the one before it.
  So two publications racing from the same pointer cannot both commit, even
  if a caller skips this module.

  `withdraw/3` moves the pointer to none, with a receipt of its own. Nothing
  here runs on a schedule or without a human.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Composition,
    CompositionPublication,
    CompositionVersion,
    Standing,
    Transaction
  }

  alias DevilsDictionary.Repo

  @doc """
  Publishes a version, as a reviewer. `opts`: `:reason`, `:idempotency_key`,
  and `:expected_pointer` (the currently published version id the caller
  saw, or `nil`). All three are required.
  """
  def publish(scope, version_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, key} <- Transaction.required(opts, :idempotency_key),
           expected = Keyword.fetch!(opts, :expected_pointer),
           {:ok, version} <-
             Transaction.need(Repo.get(CompositionVersion, version_id), :not_found),
           {:ok, composition} <- Standing.lock_composition(version.composition_id),
           :fresh <-
             Transaction.replay(CompositionPublication, key, fn r ->
               r.composition_id == composition.id and r.action == :publish and
                 r.published_version_id == version.id
             end),
           :ok <- Transaction.check(composition.state == :active, :composition_retired),
           :ok <- pointer(composition, expected),
           :ok <-
             Transaction.check(
               composition.current_published_version_id != version.id,
               :already_published
             ),
           :ok <- Standing.scope(version, composition),
           :ok <- Standing.configuration(version),
           {:ok, review} <- accepted(version),
           :ok <- Standing.eligible(Standing.evaluate(version, composition), version) do
        receipt =
          Repo.insert!(%CompositionPublication{
            composition_id: composition.id,
            action: :publish,
            previous_version_id: composition.current_published_version_id,
            published_version_id: version.id,
            authorizing_review_id: review.id,
            actor_id: actor.id,
            reason: reason,
            eligibility_fingerprint: version.eligibility_fingerprint,
            idempotency_key: key
          })

        move!(composition, version.id)
        {:ok, receipt}
      else
        {:replay, receipt} -> {:ok, receipt}
        error -> error
      end
    end)
  end

  @doc """
  Withdraws a composition's publication, as a reviewer. Its pointer becomes
  `nil`. `opts` as for `publish/3`; `:expected_pointer` is the published
  version being withdrawn.
  """
  def withdraw(scope, composition_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, key} <- Transaction.required(opts, :idempotency_key),
           expected = Keyword.fetch!(opts, :expected_pointer),
           {:ok, composition} <- Standing.lock_composition(composition_id),
           :fresh <-
             Transaction.replay(CompositionPublication, key, fn r ->
               r.composition_id == composition.id and r.action == :withdraw and
                 r.previous_version_id == expected
             end),
           :ok <- pointer(composition, expected),
           :ok <-
             Transaction.check(not is_nil(composition.current_published_version_id), :unpublished) do
        receipt =
          Repo.insert!(%CompositionPublication{
            composition_id: composition.id,
            action: :withdraw,
            previous_version_id: composition.current_published_version_id,
            actor_id: actor.id,
            reason: reason,
            idempotency_key: key
          })

        move!(composition, nil)
        {:ok, receipt}
      else
        {:replay, receipt} -> {:ok, receipt}
        error -> error
      end
    end)
  end

  @doc "The latest publication receipt of a composition, or `nil`."
  def latest(composition_id) do
    Repo.one(
      from p in CompositionPublication,
        where: p.composition_id == ^composition_id,
        order_by: [desc: p.id],
        limit: 1
    )
  end

  defp pointer(%Composition{current_published_version_id: current}, current), do: :ok

  defp pointer(%Composition{current_published_version_id: current}, _seen),
    do: {:error, {:stale_pointer, current}}

  defp accepted(version) do
    case Standing.latest_review(version.id) do
      %{decision: :accepted} = review -> {:ok, review}
      _ -> {:error, :not_approved}
    end
  end

  defp move!(composition, version_id) do
    composition
    |> Ecto.Changeset.change(
      current_published_version_id: version_id,
      lock_version: composition.lock_version + 1
    )
    |> Repo.update!()
  end
end
