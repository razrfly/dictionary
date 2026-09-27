defmodule DevilsDictionary.Curation.Runtime.Gateway do
  @moduledoc """
  The one inference slot, and the accounting that goes with it (#195, G1–G10).
  See `docs/curation/runtime-stage-a.md`, "The slot protocol".

  The authority is PostgreSQL. Every transition starts by locking the service
  row (`FOR UPDATE`), so admission, dispatch, completion, quarantine, recovery
  and pause are serialized across every caller on every node. The database
  checks the result independently:

    * one live attempt per service (a partial unique index);
    * a holder that is live under the service's fence (at COMMIT);
    * only the documented lifecycle (a trigger);
    * each attempt reserves once, releases once, and is charged at most once
      per day (ledger uniques).

  **What a timeout proves: nothing.** `mark_uncertain/3` keeps the slot held
  and quarantines the service. Only `recover/2`, with the evidence of a
  confirmed stop of the service process, settles the attempt and frees the
  slot, charging everything up to the stop. A late answer from before the
  recovery fails the holder and fence check and is refused.

  Functions that take `now:` do so for the tests. They default to the clock.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.Runtime.{Attempt, Endpoint, LedgerEntry, ModelConfig, Service}
  alias DevilsDictionary.Repo

  # ── the service ───────────────────────────────────────────────────────────

  @doc "The service row for a key, created on first use."
  def service!(key \\ nil) do
    key = key || Endpoint.get(:service_key)
    now = DateTime.utc_now()

    Repo.insert_all(Service, [%{key: key, state: :available, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.get_by!(Service, key: key)
  end

  defp lock(key) do
    service!(key)
    Repo.one!(from s in Service, where: s.key == ^key, lock: "FOR UPDATE")
  end

  defp key(opts), do: Keyword.get(opts, :service_key) || Endpoint.get(:service_key)
  defp now(opts), do: opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> usec()

  # Every stored time has microsecond precision, whatever produced it.
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp later(dt, ms), do: dt |> DateTime.add(ms, :millisecond) |> usec()

  # ── admission ─────────────────────────────────────────────────────────────

  @doc """
  Admits one request for a frozen packet under a model config. Returns:

    * `{:ok, attempt}`: admitted and holding the slot;
    * `{:replay, attempt}`: this `request_key` was already admitted for the
      same packet and model config, in whatever state it is now;
    * `{:refused, reason}`, with nothing written and nothing reserved. The
      reason is one of `:idempotency_conflict`, `:slot_busy`, `:quarantined`,
      `:paused`, `:budget_exhausted` or `:pending_cap_reached`.

  `opts`: `:request_key` and `:actor_id` (required), `:purpose` (`:request`),
  `:owner`, `:service_key` and `:now`.
  """
  def admit(%ModelConfig{} = config, %{hash: hash, bytes: bytes} = frozen, opts) do
    request_key = Keyword.fetch!(opts, :request_key)
    purpose = Keyword.get(opts, :purpose, :request)
    now = now(opts)

    {:ok, result} =
      Repo.transaction(fn ->
        service = lock(key(opts))

        case Repo.get_by(Attempt, request_key: request_key) do
          %Attempt{} = existing ->
            if existing.packet_hash == hash and existing.model_config_id == config.id and
                 existing.purpose == purpose,
               do: {:replay, existing},
               else: {:refused, :idempotency_conflict}

          nil ->
            with :ok <- slot_free(service),
                 :ok <- pending_cap(service, opts),
                 :ok <- within_budget(service, now, opts) do
              {:ok,
               insert_admitted!(service, config, frozen, bytes, purpose, request_key, now, opts)}
            end
        end
      end)

    result
  end

  defp slot_free(%Service{state: :available}), do: :ok
  defp slot_free(%Service{state: :occupied}), do: {:refused, :slot_busy}
  defp slot_free(%Service{state: :quarantined}), do: {:refused, :quarantined}
  defp slot_free(%Service{state: :paused}), do: {:refused, :paused}

  defp pending_cap(service, opts) do
    live = Attempt.live()

    open =
      Repo.one(
        from a in Attempt,
          where: a.service_id == ^service.id and a.state in ^live,
          select: coalesce(sum(a.units), 0)
      )

    if open + 1 <= Endpoint.get(:pending_cap_units, opts),
      do: :ok,
      else: {:refused, :pending_cap_reached}
  end

  defp within_budget(service, now, opts) do
    %{remaining_ms: remaining} =
      budget(DateTime.to_date(now), Keyword.put(opts, :service_id, service.id))

    if remaining >= Endpoint.reservation_ms(opts), do: :ok, else: {:refused, :budget_exhausted}
  end

  defp insert_admitted!(service, config, frozen, bytes, purpose, request_key, now, opts) do
    fence = service.fence + 1
    reserved = Endpoint.reservation_ms(opts)
    lease = later(now, reserved)

    attempt =
      Repo.insert!(%Attempt{
        service_id: service.id,
        model_config_id: config.id,
        request_key: request_key,
        purpose: purpose,
        packet_hash: frozen.hash,
        packet_bytes: bytes,
        packet_summary: Map.get(frozen, :summary, %{}),
        prompt_sha256: Map.get(frozen, :prompt_sha256),
        requested_by_actor_id: Keyword.fetch!(opts, :actor_id),
        owner: Keyword.get_lazy(opts, :owner, &owner/0),
        fence: fence,
        service_epoch: service.epoch,
        state: :admitted,
        reserved_ms: reserved,
        units: 1,
        budget_day: DateTime.to_date(now),
        admitted_at: now,
        lease_expires_at: lease
      })

    ledger!(attempt, :reserve, attempt.budget_day, reserved)

    service
    |> Ecto.Changeset.change(
      state: :occupied,
      holder_attempt_id: attempt.id,
      fence: fence,
      lease_expires_at: lease
    )
    |> Repo.update!()

    attempt
  end

  @doc "Who is asking: the node and process, for the record."
  def owner, do: "#{node()}/#{inspect(self())}"

  # ── dispatch ──────────────────────────────────────────────────────────────

  @doc """
  Commits `dispatched` **before** the request is sent. Returns `{:ok,
  attempt}`, or `{:error, :stale}` if the attempt no longer holds the slot
  under its fence.
  """
  def dispatch(%Attempt{} = attempt, opts \\ []) do
    holding(attempt, opts, [:admitted], fn service, current ->
      now = now(opts)

      lease = later(now, Endpoint.reservation_ms(opts))

      service |> Ecto.Changeset.change(lease_expires_at: lease) |> Repo.update!()

      {:ok,
       current
       |> Ecto.Changeset.change(state: :dispatched, dispatched_at: now, lease_expires_at: lease)
       |> Repo.update!()}
    end)
  end

  @doc "Records one confirmed pre-dispatch retry (connection refused) on a dispatched attempt."
  def note_retry(%Attempt{} = attempt, opts \\ []) do
    holding(attempt, opts, [:dispatched], fn _service, current ->
      {:ok,
       current
       |> Ecto.Changeset.change(transport_retries: current.transport_retries + 1)
       |> Repo.update!()}
    end)
  end

  # ── finishing ─────────────────────────────────────────────────────────────

  @doc """
  Records an answer: the attempt is `completed` with its outcome, result,
  refusal reasons and metrics. The slot is released and the accounting
  settled, once. `{:error, :stale}` if it no longer holds the slot, so a late
  or duplicate answer writes nothing.

  `payload`: `:outcome` (`:accepted | :abstained | :refused |
  :runtime_error`), `:result`, `:refusal_reasons`, `:metrics`.
  """
  def complete(%Attempt{} = attempt, payload, opts \\ []) do
    holding(attempt, opts, [:dispatched], fn service, current ->
      now = now(opts)

      finished =
        current
        |> Ecto.Changeset.change(
          state: :completed,
          outcome: payload.outcome,
          result: Map.get(payload, :result),
          refusal_reasons: Map.get(payload, :refusal_reasons, []),
          metrics: Map.merge(current.metrics || %{}, Map.get(payload, :metrics, %{})),
          finished_at: now,
          settled_at: now
        )
        |> Repo.update!()

      settle!(finished, true)
      {:ok, release!(service, finished, payload.outcome == :runtime_error, opts)}
    end)
  end

  @doc """
  The connection was refused after the permitted retries, so nothing was
  ever sent. The attempt is `failed_pre_dispatch`, the slot released and the
  occupancy charged.
  """
  def fail_pre_dispatch(%Attempt{} = attempt, reason, opts \\ []) do
    holding(attempt, opts, [:dispatched], fn service, current ->
      now = now(opts)

      finished =
        current
        |> Ecto.Changeset.change(
          state: :failed_pre_dispatch,
          outcome: :never_sent,
          refusal_reasons: [["transport", to_string(reason)]],
          finished_at: now,
          settled_at: now
        )
        |> Repo.update!()

      settle!(finished, true)
      {:ok, release!(service, finished, true, opts)}
    end)
  end

  @doc """
  The request was sent, and no answer is known: a timeout, a broken
  connection or a dead caller. The attempt becomes `uncertain` and the service
  `quarantined`. The slot stays held and nothing is settled or refunded.
  """
  def mark_uncertain(%Attempt{} = attempt, reason, opts \\ []) do
    holding(attempt, opts, [:dispatched], fn service, current ->
      quarantine!(service, "uncertain_completion:#{reason}")

      {:ok,
       current
       |> Ecto.Changeset.change(
         state: :uncertain,
         metrics: Map.put(current.metrics || %{}, "uncertain_reason", to_string(reason))
       )
       |> Repo.update!()}
    end)
  end

  defp quarantine!(service, reason) do
    service
    |> Ecto.Changeset.change(state: :quarantined, quarantine_reason: reason)
    |> Repo.update!()
  end

  # Runs `fun` only while `attempt` holds the service's slot under its fence,
  # in one of `states`, with both rows locked.
  defp holding(attempt, _opts, states, fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        service =
          Repo.one!(from s in Service, where: s.id == ^attempt.service_id, lock: "FOR UPDATE")

        current = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

        if service.holder_attempt_id == current.id and service.fence == current.fence and
             current.state in states do
          fun.(service, current)
        else
          {:error, :stale}
        end
      end)

    result
  end

  # The slot goes back, unless the failures now call for a pause.
  defp release!(service, attempt, failure?, opts) do
    failures = if failure?, do: service.consecutive_failures + 1, else: 0
    pause? = failures >= Endpoint.get(:pause_after_failures, opts)

    service
    |> Ecto.Changeset.change(
      state: if(pause?, do: :paused, else: :available),
      paused_reason: if(pause?, do: "repeated_runtime_failures", else: nil),
      holder_attempt_id: nil,
      lease_expires_at: nil,
      consecutive_failures: failures
    )
    |> Repo.update!()

    attempt
  end

  # ── leases, recovery, pause ───────────────────────────────────────────────

  @doc """
  Checks the holder's lease. An `admitted` attempt past its lease never sent
  anything: it is `released`, charged nothing, and the slot is free. A
  `dispatched` attempt past its lease may still be generating, so the
  service is quarantined. Returns `{:ok, :nothing | :released |
  :quarantined}`.
  """
  def sweep(opts \\ []) do
    now = now(opts)

    {:ok, result} =
      Repo.transaction(fn ->
        service = lock(key(opts))

        holder =
          service.holder_attempt_id &&
            Repo.one(
              from a in Attempt, where: a.id == ^service.holder_attempt_id, lock: "FOR UPDATE"
            )

        cond do
          is_nil(holder) or DateTime.compare(holder.lease_expires_at, now) == :gt ->
            {:ok, :nothing}

          holder.state == :admitted ->
            released =
              holder
              |> Ecto.Changeset.change(
                state: :released,
                outcome: :never_sent,
                refusal_reasons: [["lease", "expired_before_dispatch"]],
                finished_at: now,
                settled_at: now
              )
              |> Repo.update!()

            settle!(released, false)
            release!(service, released, false, opts)
            {:ok, :released}

          holder.state == :dispatched ->
            quarantine!(service, "uncertain_completion:lease_expired")

            holder
            |> Ecto.Changeset.change(
              state: :uncertain,
              metrics: Map.put(holder.metrics || %{}, "uncertain_reason", "lease_expired")
            )
            |> Repo.update!()

            {:ok, :quarantined}

          true ->
            {:ok, :nothing}
        end
      end)

    result
  end

  @doc """
  Settles a quarantine after a **confirmed** stop of the service process. The
  caller proves that stop (`Runtime.ServiceProcess.stop/1`); this function
  records it:

    * the uncertain attempt becomes `ended_by_restart`, charged its whole
      occupancy up to `confirmation.stopped_at`, with no refund;
    * the epoch increases;
    * the service is `paused` until readiness passes and an operator resumes
      it.

  `{:error, :not_quarantined}` otherwise.
  """
  def recover(%{stopped_at: %DateTime{} = stopped_at} = confirmation, opts \\ []) do
    {:ok, result} =
      Repo.transaction(fn ->
        service = lock(key(opts))

        if service.state != :quarantined do
          {:error, :not_quarantined}
        else
          attempt =
            service.holder_attempt_id &&
              Repo.one(
                from a in Attempt, where: a.id == ^service.holder_attempt_id, lock: "FOR UPDATE"
              )

          ended =
            if attempt && attempt.state == :uncertain do
              finished_at = latest(usec(stopped_at), attempt.dispatched_at || attempt.admitted_at)

              ended =
                attempt
                |> Ecto.Changeset.change(
                  state: :ended_by_restart,
                  outcome: :unknown,
                  finished_at: finished_at,
                  settled_at: now(opts),
                  metrics:
                    Map.put(attempt.metrics || %{}, "recovery", %{
                      "stopped_at" => DateTime.to_iso8601(stopped_at),
                      "evidence" => Map.get(confirmation, :evidence, %{})
                    })
                )
                |> Repo.update!()

              settle!(ended, true)
              ended
            end

          service =
            service
            |> Ecto.Changeset.change(
              state: :paused,
              paused_reason: "recovered_awaiting_readiness",
              quarantine_reason: nil,
              holder_attempt_id: nil,
              lease_expires_at: nil,
              epoch: service.epoch + 1,
              consecutive_failures: 0
            )
            |> Repo.update!()

          {:ok, %{service: service, attempt: ended}}
        end
      end)

    result
  end

  @doc "Pauses an available service with a reason. An operator resumes it."
  def pause(reason, opts \\ []) do
    {:ok, result} =
      Repo.transaction(fn ->
        service = lock(key(opts))

        case service.state do
          :available ->
            {:ok,
             service
             |> Ecto.Changeset.change(state: :paused, paused_reason: to_string(reason))
             |> Repo.update!()}

          :paused ->
            {:ok, service}

          other ->
            {:error, other}
        end
      end)

    result
  end

  @doc """
  Resumes a paused service. The caller has just passed readiness
  (`Runtime.resume/1` does both).
  """
  def resume(opts \\ []) do
    {:ok, result} =
      Repo.transaction(fn ->
        service = lock(key(opts))

        if service.state == :paused do
          {:ok,
           service
           |> Ecto.Changeset.change(
             state: :available,
             paused_reason: nil,
             consecutive_failures: 0
           )
           |> Repo.update!()}
        else
          {:error, {:not_paused, service.state}}
        end
      end)

    result
  end

  # ── accounting ────────────────────────────────────────────────────────────

  @doc """
  One UTC day's budget: `%{day, limit_ms, charged_ms, reserved_ms,
  remaining_ms}`. `reserved_ms` is the open reservations admitted that day.
  Charges include every attempt's occupancy that fell on that day, whenever it
  was admitted.
  """
  def budget(%Date{} = day, opts \\ []) do
    service_id = Keyword.get_lazy(opts, :service_id, fn -> service!(key(opts)).id end)

    sums =
      Repo.all(
        from e in LedgerEntry,
          where: e.service_id == ^service_id and e.day == ^day,
          group_by: e.kind,
          select: {e.kind, sum(e.amount_ms)}
      )
      |> Map.new()

    charged = Map.get(sums, :charge, 0)
    reserved = Map.get(sums, :reserve, 0) - Map.get(sums, :release, 0)
    limit = Endpoint.get(:daily_budget_ms, opts)

    %{
      day: day,
      limit_ms: limit,
      charged_ms: charged,
      reserved_ms: reserved,
      remaining_ms: max(limit - charged - reserved, 0)
    }
  end

  # Release the reservation, and charge the occupancy (admission to finish)
  # to each UTC day it fell on. The ledger uniques make a second settlement of
  # the same attempt fail.
  defp settle!(attempt, charge?) do
    ledger!(attempt, :release, attempt.budget_day, attempt.reserved_ms)

    if charge? do
      for {day, ms} <- by_day(attempt.admitted_at, attempt.finished_at),
          do: ledger!(attempt, :charge, day, ms)
    end

    :ok
  end

  @doc """
  An occupancy interval, cut at UTC midnights, as `[{date, milliseconds}]`.
  An interval crossing midnight charges both days: no reset loophole.
  """
  def by_day(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.compare(to, from) != :gt do
      [{DateTime.to_date(from), 0}]
    else
      split(from, to, [])
    end
  end

  defp split(from, to, acc) do
    day = DateTime.to_date(from)
    {:ok, midnight} = DateTime.new(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

    if DateTime.compare(to, midnight) == :gt do
      split(midnight, to, [{day, DateTime.diff(midnight, from, :millisecond)} | acc])
    else
      Enum.reverse([{day, DateTime.diff(to, from, :millisecond)} | acc])
    end
  end

  defp ledger!(attempt, kind, day, amount) do
    Repo.insert!(%LedgerEntry{
      service_id: attempt.service_id,
      attempt_id: attempt.id,
      kind: kind,
      day: day,
      amount_ms: amount
    })
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
end
