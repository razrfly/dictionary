defmodule DevilsDictionary.Curation.Publications do
  @moduledoc """
  Transactional publication of composition versions (R3–R5).

  A publication has two parts, kept separate:

    * **an authority**, which says who or what decided this version should
      be shown;
    * **a commit**, which checks the version still stands and moves the
      pointer with a receipt.

  The commit is the same whatever the authority. It locks the composition
  row and checks:

    1. the **expected pointer** the caller saw (`{:stale_pointer, current}`);
    2. that the composition is active and the version is not already
       published;
    3. that the version still stands: same scope, same configuration version,
       and a clean evaluation to its own eligibility fingerprint;
    4. that the authority is valid.

  It then writes a receipt naming its authority (`authority_kind`) and moves
  the pointer, in one transaction. The database repeats what matters:

    * the receipt must satisfy its authority's rule;
    * the pointer must equal the latest receipt at commit;
    * each receipt must continue the one before it.

  So two publications racing from one pointer cannot both commit, even if a
  caller skips this module.

  **Authorities.**

    * **`:operator`** (`publish/3`) is available in this slice. A reviewer
      publishes a version whose latest review is an acceptance of its
      fingerprint. It is an *optional* operator path, for manual compositions,
      overrides and corrections. It is not the gate every selection must pass.
    * **`:panel_decision`** is the intended routine path, but it is **not
      available**. The configured panel reaching consensus on a version that
      passes the evidence and policy checks would publish it with no
      per-selection human sign-off. It needs genuine, finalized decision
      records, which do not exist until runs land (#197). The database refuses
      any authority but `operator`, and nothing here fabricates a run, vote or
      decision to stand in for one. What the integration must add is set out
      in `docs/curation/persistence-slice-1.md`, "Publication authority".

  **Single-editor authority** (#275, owner amendment 29 October): an explicitly
  enabled single_editor_v1 policy publishes its validated accepted model version
  inside the refresh fence, without any human acceptance. The database checks
  policy, binding, accepted attempt, pilot, running lease, unchanged inputs and
  expected parent. This is not panel consensus. Manual policy retains its old
  proposal-not-publishable rule and optional owner Take path.

  `withdraw/3` moves the pointer to none, with a receipt of its own, as an
  operator. The reader withholds an ineligible item on its own, without any
  withdrawal.

  **The refresh clock** (#259 §5.5), in the same transaction: a withdrawal
  suppresses the composition's checks (`Refresh.suppress/1`), so no check or
  proposal runs until the owner re-opens it; a publication resets the
  baseline the next check measures against (`Refresh.published/1`) and
  lifts a suppression.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Composition,
    CompositionPublication,
    CompositionVersion,
    Refresh,
    Standing,
    Transaction
  }

  alias DevilsDictionary.Repo

  @doc """
  Publishes a version on operator authority, as a reviewer. `opts`:
  `:reason`, `:idempotency_key`, and `:expected_pointer` (the currently
  published version id the caller saw, or `nil`). All three are required.
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
             end) do
        commit(composition, version, expected, operator(actor), reason, key)
      else
        {:replay, receipt} -> {:ok, receipt}
        error -> error
      end
    end)
  end

  @doc """
  Publish an accepted editor choice inside Refresh.write/4's fenced transaction.
  No human review is created. The database binds the receipt to the accepted
  attempt, enabled immutable policy, running lease, pilot scope and exact parent.
  """
  def publish_editor(version, claim) do
    Transaction.run(fn ->
      version = Repo.get!(CompositionVersion, version.id)

      with {:ok, composition} <- Standing.lock_composition(version.composition_id),
           :ok <- editor_fence(version, claim),
           :ok <- Transaction.check(composition.mode == :open, :owner_hold),
           cv =
             Repo.get!(
               DevilsDictionary.Curation.ConfigurationVersion,
               version.configuration_version_id
             ),
           :ok <-
             Transaction.check(
               DevilsDictionary.Curation.Configurations.autonomous?(cv),
               :manual_policy
             ),
           {:ok, editor} <- DevilsDictionary.Curation.Configurations.editor_enabled(cv.id),
           :ok <-
             Transaction.check(
               version.created_by_actor_id == editor.bot_actor.id,
               :editor_binding_changed
             ) do
        authority = %{
          kind: :single_editor,
          actor: editor.bot_actor,
          authorize: fn v ->
            Transaction.check(v.origin == :model and not is_nil(v.attempt_id), :not_model_choice)
            |> case do
              :ok -> {:ok, %{authorizing_review_id: nil}}
              error -> error
            end
          end
        }

        commit(
          composition,
          version,
          claim.admitted_parent_version_id,
          authority,
          "Validated single-editor selection; no human approval required.",
          "single-editor:#{version.id}"
        )
      else
        :off -> {:error, :editor_disabled}
        error -> error
      end
    end)
  end

  defp editor_fence(version, claim) do
    row = Repo.get(DevilsDictionary.Curation.RefreshState, claim.row_id)

    Transaction.check(
      (row && row.composition_id == version.composition_id) and
        row.configuration_version_id == version.configuration_version_id and
        row.state == :running and row.lease_token == claim.token and
        row.refresh_generation == claim.generation and row.run_dirty_seq == row.dirty_seq and
        DateTime.compare(row.lease_expires_at, DateTime.utc_now()) == :gt,
      :lease_lost
    )
  end

  defp publication_reasons(version) do
    items = DevilsDictionary.Curation.Compositions.items(version.id)

    case Enum.find(items, fn item ->
           blank = is_nil(item.note) or String.trim(item.note) == ""

           blank and
             not (item.role == :lead and version.resolution["lead_rule"] == "priority_source")
         end) do
      nil -> :ok
      item -> {:error, {:reason_required, item.role, item.position}}
    end
  end

  # The operator authority: the reviewer acting, and the version's latest
  # review, which must be an acceptance. The acceptance may be another
  # reviewer's; the receipt names both.
  defp operator(actor) do
    %{
      kind: :operator,
      actor: actor,
      authorize: fn version ->
        case Standing.latest_review(version.id) do
          %{decision: :accepted} = review -> {:ok, %{authorizing_review_id: review.id}}
          _ -> {:error, :not_approved}
        end
      end
    }
  end

  defp commit(composition, version, expected, authority, reason, key) do
    with :ok <-
           Transaction.check(
             version.origin == :manual or authority.kind == :single_editor,
             :proposal_not_publishable
           ),
         :ok <- Transaction.check(composition.state == :active, :composition_retired),
         :ok <- pointer(composition, expected),
         :ok <-
           Transaction.check(
             composition.current_published_version_id != version.id,
             :already_published
           ),
         :ok <- Standing.scope(version, composition),
         :ok <- Standing.configuration(version),
         {:ok, authorization} <- authority.authorize.(version),
         :ok <- Standing.eligible(Standing.evaluate(version, composition), version),
         :ok <- publication_reasons(version),
         :ok <-
           DevilsDictionary.Curation.ProviderText.validate(
             reason,
             DevilsDictionary.Curation.Compositions.items(version.id)
           ) do
      receipt =
        Repo.insert!(
          struct(
            CompositionPublication,
            Map.merge(authorization, %{
              composition_id: composition.id,
              action: :publish,
              authority_kind: authority.kind,
              previous_version_id: composition.current_published_version_id,
              published_version_id: version.id,
              actor_id: authority.actor.id,
              reason: reason,
              eligibility_fingerprint: version.eligibility_fingerprint,
              idempotency_key: key
            })
          )
        )

      move!(composition, version.id)
      # The next check measures against this version (#259 §5.5).
      if authority.kind == :operator, do: Refresh.published(composition.id)
      {:ok, receipt}
    end
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
           published_items =
             if(composition.current_published_version_id,
               do:
                 DevilsDictionary.Curation.Compositions.items(
                   composition.current_published_version_id
                 ),
               else: []
             ),
           :ok <-
             DevilsDictionary.Curation.ProviderText.validate(reason, published_items,
               fixed_reason: reason == "withdrawn_by_owner"
             ),
           :ok <- pointer(composition, expected),
           :ok <-
             Transaction.check(not is_nil(composition.current_published_version_id), :unpublished) do
        receipt =
          Repo.insert!(%CompositionPublication{
            composition_id: composition.id,
            action: :withdraw,
            authority_kind: :operator,
            previous_version_id: composition.current_published_version_id,
            actor_id: actor.id,
            reason: reason,
            idempotency_key: key
          })

        move!(composition, nil)
        # Withdrawal means keep this off the page: no check, no proposal,
        # until the owner re-opens it (#253 §6a, #259 §5.5).
        Refresh.suppress(composition.id)
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

  defp move!(composition, version_id) do
    composition
    |> Ecto.Changeset.change(
      current_published_version_id: version_id,
      lock_version: composition.lock_version + 1
    )
    |> Repo.update!()
  end
end
