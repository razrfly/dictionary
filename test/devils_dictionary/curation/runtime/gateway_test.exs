defmodule DevilsDictionary.Curation.Runtime.GatewayTest do
  @moduledoc """
  G2–G10 of `docs/curation/runtime-stage-a.md`: the slot, its fence,
  uncertainty and recovery, and accounting that settles once. Each test has a
  service of its own, so they run concurrently without sharing a slot. The
  cross-connection race is `GatewayRaceTest`.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.{Attempt, Gateway, LedgerEntry, Service}
  alias DevilsDictionary.RuntimeFixtures

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    config = RuntimeFixtures.model_config!()
    actor = actor!(account([:reviewer]))
    key = "test-#{System.unique_integer([:positive])}"
    %{config: config, actor: actor, key: key, opts: [service_key: key]}
  end

  defp frozen(tag \\ "p"), do: %{packet: %{}, hash: Digest.sha256(tag), bytes: 10, summary: %{}}

  defp admit(ctx, extra \\ []) do
    opts =
      ctx.opts
      |> Keyword.merge(request_key: key("r"), actor_id: ctx.actor.id)
      |> Keyword.merge(Keyword.delete(extra, :frozen))

    Gateway.admit(ctx.config, Keyword.get(extra, :frozen, frozen()), opts)
  end

  defp service(ctx), do: Repo.get_by!(Service, key: ctx.key)

  defp ledger(attempt) do
    Repo.all(
      from e in LedgerEntry,
        where: e.attempt_id == ^attempt.id,
        order_by: [e.kind, e.day],
        select: {e.kind, e.day, e.amount_ms}
    )
  end

  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  describe "the slot (G1, G2, G3)" do
    test "an admitted attempt holds the slot; a second caller is refused, and so is the database",
         ctx do
      {:ok, first} = admit(ctx)
      settle!()

      assert %Service{state: :occupied, holder_attempt_id: holder, fence: 1} = service(ctx)
      assert holder == first.id
      assert first.fence == 1 and first.state == :admitted
      assert first.owner =~ "/os:#{System.pid()}/"
      assert [{:reserve, _day, 125_000}] = ledger(first)

      assert {:refused, :slot_busy} = admit(ctx)

      # A caller that skips the gateway still cannot make a second live attempt.
      assert {:refused, :unique, "inference_attempts_one_live_per_service"} =
               refused(fn ->
                 first
                 |> Ecto.put_meta(state: :built)
                 |> Map.merge(%{id: nil, request_key: key("raw")})
                 |> Repo.insert!()
               end)
    end

    test "an attempt cannot finish while it still holds the slot, even if the service is untouched",
         ctx do
      {:ok, holder} = admit(ctx)
      settle!()

      # Finish the holder completely, ledger and all, but leave the service
      # naming it. Only the attempt-side holder check can see this.
      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 released =
                   holder
                   |> Ecto.Changeset.change(
                     state: :released,
                     outcome: :never_sent,
                     finished_at: holder.admitted_at,
                     settled_at: holder.admitted_at
                   )
                   |> Repo.update!()

                 Repo.insert!(%LedgerEntry{
                   service_id: released.service_id,
                   attempt_id: released.id,
                   kind: :release,
                   day: released.budget_day,
                   amount_ms: released.reserved_ms
                 })
               end)

      assert message =~ "holds its service without being live"
      assert %Service{state: :occupied, holder_attempt_id: id} = service(ctx)
      assert id == holder.id
    end

    test "a model config without numeric context and output bounds is refused", ctx do
      unbounded =
        for key <- ["num_ctx", "num_predict"],
            generation <- [
              Map.delete(ctx.config.generation, key),
              Map.put(ctx.config.generation, key, nil),
              Map.put(ctx.config.generation, key, "8")
            ],
            do: generation

      for generation <- unbounded do
        assert {:refused, :check, "local_model_configs_shape"} =
                 refused(fn ->
                   ctx.config
                   |> Ecto.put_meta(state: :built)
                   |> Map.merge(%{
                     id: nil,
                     slug: key("unbounded"),
                     config_hash: Digest.sha256(key("unbounded")),
                     generation: generation
                   })
                   |> Repo.insert!()
                 end)
      end
    end

    test "a duplicate request replays its receipt; a different request under the key conflicts",
         ctx do
      k = key("dup")
      {:ok, first} = admit(ctx, request_key: k)
      {:ok, _} = Gateway.dispatch(first, ctx.opts)
      {:ok, done} = Gateway.complete(first, %{outcome: :abstained}, ctx.opts)

      assert {:replay, %Attempt{id: id, state: :completed}} = admit(ctx, request_key: k)
      assert id == done.id

      assert {:refused, :idempotency_conflict} =
               admit(ctx, request_key: k, frozen: frozen("other"))

      settle!()
    end
  end

  describe "fences and uncertainty (G4, G5)" do
    test "a result is accepted once, from the holder under its fence", ctx do
      {:ok, attempt} = admit(ctx)

      # Nothing was sent yet, so nothing can have been answered.
      assert {:error, :stale} = Gateway.complete(attempt, %{outcome: :accepted}, ctx.opts)

      {:ok, dispatched} = Gateway.dispatch(attempt, ctx.opts)
      assert {:error, :stale} = Gateway.dispatch(attempt, ctx.opts)

      assert {:ok, done} =
               Gateway.complete(dispatched, %{outcome: :accepted, result: %{"x" => 1}}, ctx.opts)

      assert {:error, :stale} = Gateway.complete(dispatched, %{outcome: :accepted}, ctx.opts)
      settle!()

      assert done.state == :completed and done.settled_at
      assert %Service{state: :available, holder_attempt_id: nil} = service(ctx)
      assert [{:charge, _, _}, {:release, _, 125_000}, {:reserve, _, 125_000}] = ledger(done)

      # A finished attempt never changes again.
      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.query!("UPDATE inference_attempts SET outcome = 'refused' WHERE id = $1", [
                   done.id
                 ])
               end)
    end

    test "a timeout after dispatch quarantines the service, frees nothing and refunds nothing",
         ctx do
      {:ok, attempt} = admit(ctx)
      {:ok, attempt} = Gateway.dispatch(attempt, ctx.opts)
      {:ok, uncertain} = Gateway.mark_uncertain(attempt, :timeout, ctx.opts)
      settle!()

      assert uncertain.state == :uncertain and is_nil(uncertain.settled_at)
      assert %Service{state: :quarantined, holder_attempt_id: holder} = service(ctx)
      assert holder == attempt.id
      assert [{:reserve, _, 125_000}] = ledger(attempt)
      assert {:refused, :quarantined} = admit(ctx)

      # The answer that arrives after the timeout is not recorded either.
      assert {:error, :stale} = Gateway.complete(attempt, %{outcome: :accepted}, ctx.opts)
    end

    test "an expired admitted lease releases the slot; an expired dispatched lease quarantines it",
         ctx do
      now = at("2026-09-27T10:00:00Z")
      {:ok, admitted} = admit(ctx, now: now)

      assert {:ok, :nothing} = Gateway.sweep(Keyword.put(ctx.opts, :now, now))
      assert {:ok, :released} = Gateway.sweep(Keyword.put(ctx.opts, :now, DateTime.add(now, 200)))
      settle!()

      released = Repo.get!(Attempt, admitted.id)
      assert {released.state, released.outcome} == {:released, :never_sent}
      assert [{:release, _, 125_000}, {:reserve, _, 125_000}] = ledger(admitted)
      assert service(ctx).state == :available

      {:ok, second} = admit(ctx, now: now)
      {:ok, _} = Gateway.dispatch(second, Keyword.put(ctx.opts, :now, now))

      assert {:ok, :quarantined} =
               Gateway.sweep(Keyword.put(ctx.opts, :now, DateTime.add(now, 200)))

      settle!()

      assert Repo.get!(Attempt, second.id).state == :uncertain
      assert service(ctx).state == :quarantined
    end
  end

  describe "recovery (G6)" do
    test "a confirmed stop settles the uncertain attempt once and holds the slot until resume",
         ctx do
      now = at("2026-09-27T10:00:00Z")
      {:ok, attempt} = admit(ctx, now: now)
      {:ok, attempt} = Gateway.dispatch(attempt, Keyword.put(ctx.opts, :now, now))
      {:ok, _} = Gateway.mark_uncertain(attempt, :timeout, ctx.opts)

      assert {:error, :not_quarantined} =
               Gateway.recover(%{stopped_at: now}, Keyword.put(ctx.opts, :service_key, "other"))

      stopped = DateTime.add(now, 600)

      assert {:ok, %{attempt: ended, service: svc}} =
               Gateway.recover(%{stopped_at: stopped, evidence: %{"stopped_pid" => 1}}, ctx.opts)

      settle!()

      # Charged all ten minutes up to the confirmed stop: no refund on a guess.
      assert {ended.state, ended.outcome} == {:ended_by_restart, :unknown}

      assert [{:charge, _, 600_000}, {:release, _, 125_000}, {:reserve, _, 125_000}] =
               ledger(attempt)

      assert {svc.state, svc.epoch, svc.holder_attempt_id} == {:paused, 1, nil}

      assert {:error, :not_quarantined} = Gateway.recover(%{stopped_at: stopped}, ctx.opts)
      assert {:refused, :paused} = admit(ctx)
      assert {:error, :stale} = Gateway.complete(attempt, %{outcome: :accepted}, ctx.opts)

      assert {:ok, %Service{state: :available}} = Gateway.resume(ctx.opts)
      assert {:ok, _} = admit(ctx)
      settle!()
    end
  end

  describe "accounting (G7, G8)" do
    test "the budget refuses admission once today's occupancy is spent", ctx do
      now = at("2026-09-27T10:00:00Z")
      opts = Keyword.put(ctx.opts, :daily_budget_ms, 200_000)

      {:ok, a} =
        Gateway.admit(
          ctx.config,
          frozen(),
          opts ++ [request_key: key("b1"), actor_id: ctx.actor.id, now: now]
        )

      {:ok, a} = Gateway.dispatch(a, Keyword.put(opts, :now, now))

      {:ok, _} =
        Gateway.complete(a, %{outcome: :accepted}, Keyword.put(opts, :now, DateTime.add(now, 90)))

      assert %{charged_ms: 90_000, reserved_ms: 0, remaining_ms: 110_000} =
               Gateway.budget(~D[2026-09-27], opts)

      assert {:refused, :budget_exhausted} =
               Gateway.admit(
                 ctx.config,
                 frozen(),
                 opts ++ [request_key: key("b2"), actor_id: ctx.actor.id, now: now]
               )

      # Tomorrow is another day, but only because nothing of today spilled into it.
      tomorrow = at("2026-09-28T09:00:00Z")

      assert {:ok, _} =
               Gateway.admit(
                 ctx.config,
                 frozen(),
                 opts ++ [request_key: key("b3"), actor_id: ctx.actor.id, now: tomorrow]
               )

      settle!()
    end

    test "occupancy crossing midnight is charged to both UTC days", ctx do
      before_midnight = at("2026-09-27T23:59:30Z")
      after_midnight = at("2026-09-28T00:00:45Z")

      {:ok, a} = admit(ctx, now: before_midnight)
      {:ok, a} = Gateway.dispatch(a, Keyword.put(ctx.opts, :now, before_midnight))

      {:ok, _} =
        Gateway.complete(a, %{outcome: :accepted}, Keyword.put(ctx.opts, :now, after_midnight))

      settle!()

      assert [
               {:charge, ~D[2026-09-27], 30_000},
               {:charge, ~D[2026-09-28], 45_000},
               {:release, ~D[2026-09-27], 125_000},
               {:reserve, ~D[2026-09-27], 125_000}
             ] = ledger(a)

      assert %{charged_ms: 45_000} = Gateway.budget(~D[2026-09-28], ctx.opts)
    end

    test "the pending-work cap refuses admission", ctx do
      assert {:refused, :pending_cap_reached} = admit(ctx, pending_cap_units: 0)
    end

    test "the ledger settles each attempt once, and only a finished one", ctx do
      {:ok, a} = admit(ctx)
      settle!()

      entry = fn kind, amount ->
        Repo.insert!(%LedgerEntry{
          service_id: a.service_id,
          attempt_id: a.id,
          kind: kind,
          day: a.budget_day,
          amount_ms: amount
        })
      end

      assert {:refused, _, message} = refused(fn -> entry.(:release, 125_000) end)
      assert message =~ "not finished"
      assert {:refused, :unique, _} = refused(fn -> entry.(:reserve, 125_000) end)

      {:ok, a} = Gateway.dispatch(a, ctx.opts)
      {:ok, _} = Gateway.complete(a, %{outcome: :accepted}, ctx.opts)
      settle!()

      assert {:refused, :unique, _} = refused(fn -> entry.(:release, 125_000) end)
      assert {:refused, :unique, _} = refused(fn -> entry.(:charge, 1) end)

      # And a finished attempt cannot skip its release at all.
      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.query!("DELETE FROM inference_ledger_entries WHERE attempt_id = $1", [a.id])
               end)
    end
  end

  describe "pausing (G10)" do
    test "three runtime failures in a row pause the service until an operator resumes it", ctx do
      for n <- 1..3 do
        {:ok, a} = admit(ctx, request_key: key("f#{n}"))
        {:ok, a} = Gateway.dispatch(a, ctx.opts)
        {:ok, _} = Gateway.complete(a, %{outcome: :runtime_error}, ctx.opts)
      end

      assert %Service{state: :paused, paused_reason: "repeated_runtime_failures"} = service(ctx)
      assert {:refused, :paused} = admit(ctx)

      assert {:ok, %Service{state: :available, consecutive_failures: 0}} =
               Gateway.resume(ctx.opts)

      settle!()
    end

    test "a validation refusal is an answer, not a runtime failure", ctx do
      for n <- 1..3 do
        {:ok, a} = admit(ctx, request_key: key("v#{n}"))
        {:ok, a} = Gateway.dispatch(a, ctx.opts)

        {:ok, _} =
          Gateway.complete(
            a,
            %{outcome: :refused, refusal_reasons: [["lead", "unknown_candidate"]]},
            ctx.opts
          )
      end

      assert service(ctx).state == :available
      settle!()
    end
  end
end
