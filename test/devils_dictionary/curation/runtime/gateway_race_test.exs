defmodule DevilsDictionary.Curation.Runtime.GatewayRaceTest do
  @moduledoc """
  G1, G4, G5 and G7 on committed transactions and separate connections: the
  evidence a single-process test cannot give (#195). Each caller checks out its
  own database connection, as a separate worker node would. Only PostgreSQL
  coordinates them, and the fake runtime counts how many generations ever
  overlap.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.Runtime
  alias DevilsDictionary.Curation.Runtime.{Attempt, Gateway, LedgerEntry, Packet, Service}
  alias DevilsDictionary.Repo

  @moduletag :unboxed

  setup do
    world = world!()
    config = model_config!() |> ready!()

    {:ok, packet} =
      Packet.build([world.love.object_id], "en", instruction_version: config.instruction_version)

    {:ok, frozen} = Packet.freeze(packet)
    actor = actor!(world.reviewer)

    Map.merge(world, %{
      config: config,
      frozen: frozen,
      actor: actor,
      opts: bind!(service_key: "race", actor_id: actor.id)
    })
  end

  # A caller on a connection of its own, which starts when told to. Not linked,
  # so a test can kill it mid-call as a crashed node would die.
  defp caller(fun) do
    parent = self()

    pid =
      spawn(fn ->
        Process.put(:"$callers", [parent])
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:ready, self()})

        receive do
          :go -> send(parent, {:done, self(), fun.()})
        end
      end)

    assert_receive {:ready, ^pid}, 5_000
    pid
  end

  # A fake runtime that holds each generation until released, and records the
  # most that were ever in flight at once.
  defp blocking_runtime(config) do
    parent = self()
    counters = :counters.new(2, [:atomics])

    stub_ollama!(config,
      chat: fn _request ->
        :counters.add(counters, 1, 1)
        in_flight = :counters.get(counters, 1)
        if in_flight > :counters.get(counters, 2), do: :counters.put(counters, 2, in_flight)
        send(parent, {:generating, self()})
        receive do: (:release -> :ok)
        :counters.sub(counters, 1, 1)
        {:json, answer(abstain())}
      end
    )

    counters
  end

  # Holds a caller between admission and dispatch: once its admission has
  # committed, it says so and waits to be told to dispatch. Only a process
  # that asked (`:hold_after_admission` in its dictionary) is held.
  defp hold_after_admission do
    handler = "runtime-hold-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:devils_dictionary, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        case Process.get(:hold_after_admission) do
          nil ->
            :ok

          parent ->
            cond do
              query =~ ~s(INSERT INTO "inference_attempts") ->
                Process.put(:admission_written, true)

              query == "commit" and Process.get(:admission_written) ->
                Process.delete(:hold_after_admission)
                send(parent, {:admitted, self()})
                receive do: (:dispatch -> :ok)

              true ->
                :ok
            end
        end
      end,
      nil
    )

    handler
  end

  # #221 A1: a slow caller whose lease runs out between admission and
  # dispatch is released by another caller's sweep. Its dispatch is then
  # stale, which is a refusal and not a `MatchError`, and nothing is sent.
  test "a sweep between admission and dispatch: the caller is refused, nothing is sent", ctx do
    calls = :counters.new(1, [])

    stub_ollama!(ctx.config,
      chat: fn _ ->
        :counters.add(calls, 1, 1)
        {:json, answer(abstain())}
      end
    )

    handler = hold_after_admission()
    on_exit(fn -> :telemetry.detach(handler) end)
    parent = self()

    slow =
      caller(fn ->
        Process.put(:hold_after_admission, parent)
        Runtime.run(ctx.config, ctx.frozen, Keyword.put(ctx.opts, :request_key, "slow"))
      end)

    send(slow, :go)
    assert_receive {:admitted, ^slow}, 10_000
    assert %Attempt{state: :admitted} = Repo.get_by!(Attempt, request_key: "slow")

    later = DateTime.add(DateTime.utc_now(), 3_600)
    assert {:ok, :released} = Gateway.sweep(service_key: "race", now: later)

    send(slow, :dispatch)
    assert_receive {:done, ^slow, {:refused, :stale}}, 10_000

    assert :counters.get(calls, 1) == 0
    attempt = Repo.get_by!(Attempt, request_key: "slow")

    assert {attempt.state, attempt.outcome, attempt.dispatched_at} ==
             {:released, :never_sent, nil}

    assert %Service{state: :available, holder_attempt_id: nil} =
             Repo.get_by!(Service, key: "race")

    assert [:release, :reserve] =
             Repo.all(
               from e in LedgerEntry,
                 where: e.attempt_id == ^attempt.id,
                 order_by: e.kind,
                 select: e.kind
             )
  end

  test "two independent callers: one generation, one busy refusal, one settlement", ctx do
    counters = blocking_runtime(ctx.config)

    callers =
      for n <- 1..2 do
        caller(fn ->
          Runtime.run(ctx.config, ctx.frozen, Keyword.put(ctx.opts, :request_key, "race-#{n}"))
        end)
      end

    Enum.each(callers, &send(&1, :go))

    assert_receive {:generating, generating}, 10_000
    assert_receive {:done, _refused_pid, {:refused, :slot_busy}}, 10_000
    refute_receive {:generating, _}, 200

    send(generating, :release)
    assert_receive {:done, _, {:ok, %{outcome: :abstained} = receipt}}, 10_000

    assert :counters.get(counters, 2) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.get_by!(Service, key: "race").state == :available

    assert [:charge, :release, :reserve] =
             Repo.all(
               from e in LedgerEntry,
                 where: e.attempt_id == ^receipt.attempt_id,
                 order_by: e.kind,
                 select: e.kind
             )
  end

  test "callers that skip the gateway still cannot both make a live attempt", ctx do
    service = Gateway.service!("race")
    parent = self()

    raw = fn tag ->
      caller(fn ->
        try do
          Repo.transaction(fn ->
            Repo.insert!(%Attempt{
              service_id: service.id,
              model_config_id: ctx.config.id,
              request_key: "raw-#{tag}",
              purpose: :request,
              packet_hash: ctx.frozen.hash,
              packet_bytes: 1,
              packet_summary: %{},
              requested_by_actor_id: ctx.actor.id,
              owner: "raw",
              fence: 1,
              service_epoch: 0,
              reserved_ms: 1,
              budget_day: Date.utc_today(),
              admitted_at: DateTime.utc_now(),
              lease_expires_at: DateTime.utc_now()
            })

            send(parent, {:inserted, tag})
            receive do: (:commit -> :ok)
          end)

          :committed
        rescue
          e in [Postgrex.Error, Ecto.ConstraintError] -> {:refused, e.__struct__}
        end
      end)
    end

    first = raw.(1)
    second = raw.(2)
    send(first, :go)
    assert_receive {:inserted, 1}, 5_000

    # The second insert waits on the first's uncommitted index entry.
    send(second, :go)
    refute_receive {:inserted, 2}, 300

    send(first, :commit)
    assert_receive {:done, ^first, :committed}, 5_000
    assert_receive {:done, ^second, {:refused, Ecto.ConstraintError}}, 5_000
    assert Repo.aggregate(Attempt, :count) == 1
  end

  @tag :capture_log
  test "a caller that dies mid-generation leaves the slot held until a confirmed stop", ctx do
    blocking_runtime(ctx.config)

    doomed =
      caller(fn ->
        Runtime.run(ctx.config, ctx.frozen, Keyword.put(ctx.opts, :request_key, "doomed"))
      end)

    send(doomed, :go)
    assert_receive {:generating, _in_flight}, 10_000

    Process.exit(doomed, :kill)
    attempt = Repo.get_by!(Attempt, request_key: "doomed")
    assert attempt.state == :dispatched

    # Its death proves nothing: the slot is still held for every other caller.
    other =
      caller(fn ->
        Runtime.run(ctx.config, ctx.frozen, Keyword.put(ctx.opts, :request_key, "other"))
      end)

    send(other, :go)
    assert_receive {:done, ^other, {:refused, :slot_busy}}, 10_000

    # Past its lease the service is quarantined, not freed.
    later = DateTime.add(DateTime.utc_now(), 3_600)
    assert {:ok, :quarantined} = Gateway.sweep(service_key: "race", now: later)
    assert Repo.get_by!(Service, key: "race").state == :quarantined

    # Only a confirmed stop settles it, once, and a late answer is then stale.
    {:ok, %{attempt: ended}} = Gateway.recover(%{stopped_at: later}, service_key: "race")
    assert ended.state == :ended_by_restart

    late = caller(fn -> Gateway.complete(attempt, %{outcome: :accepted}, service_key: "race") end)
    send(late, :go)
    assert_receive {:done, ^late, {:error, :stale}}, 5_000

    duplicate =
      caller(fn ->
        try do
          Repo.insert!(%LedgerEntry{
            service_id: attempt.service_id,
            attempt_id: attempt.id,
            kind: :charge,
            day: attempt.budget_day,
            amount_ms: 1
          })

          :inserted
        rescue
          Ecto.ConstraintError -> :unique
        end
      end)

    send(duplicate, :go)
    assert_receive {:done, ^duplicate, :unique}, 5_000

    assert Repo.all(
             from e in LedgerEntry,
               where: e.attempt_id == ^attempt.id and e.kind == :charge,
               select: e.amount_ms
           ) != []
  end
end
