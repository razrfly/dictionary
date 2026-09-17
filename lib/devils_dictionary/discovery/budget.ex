defmodule DevilsDictionary.Discovery.Budget do
  @moduledoc "A database-coordinated rolling request budget shared across nodes."

  import Ecto.Query

  alias DevilsDictionary.Discovery.{Mapping, Policy, RequestAttempt, Run}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @doc """
  Claims one outbound request for a run, or returns a conservative retry delay.

  `{:ok, wait_ms}` is a reserved slot: the caller waits `wait_ms` and then
  issues the request. With `:request_interval_ms` the slot is placed at least
  that far after the provider's most recent attempt, whichever run made it, and
  the placement happens under the same per-source advisory lock the budget
  count uses. Two runs on one provider — `:provider_concurrency` allows two —
  therefore get slots the interval apart instead of each sleeping the interval
  on its own and issuing together. The reservation is the attempt row itself,
  so it outlives the transaction and is visible to the next claimant on any
  node.
  """
  def claim(run_id, stage, opts \\ []) when is_binary(stage) do
    now = DateTime.utc_now()
    interval_ms = Keyword.get(opts, :request_interval_ms, 0)

    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id)
      mapping = Repo.get!(Mapping, run.mapping_id)
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [mapping.source_id])
      source = Repo.get!(Source, mapping.source_id)
      policy = Policy.for!(source.slug)
      cutoff = DateTime.add(now, -policy.request_budget_window_seconds, :second)
      attempts = get_in(run.request_parameters, ["transport_attempts", stage]) || 0
      max_attempts = config(:max_retries) + 1

      used =
        Repo.aggregate(
          from(attempt in RequestAttempt,
            where: attempt.source_id == ^mapping.source_id and attempt.attempted_at > ^cutoff
          ),
          :count
        )

      cond do
        source.discovery_retry_after &&
            DateTime.compare(source.discovery_retry_after, now) == :gt ->
          Repo.rollback({:provider_backoff, seconds_until(source.discovery_retry_after, now)})

        attempts >= max_attempts ->
          Repo.rollback(:attempts_exhausted)

        used >= policy.request_budget_limit ->
          retry_at = oldest_attempt_at(mapping.source_id, cutoff)

          seconds =
            retry_at
            |> DateTime.add(policy.request_budget_window_seconds, :second)
            |> seconds_until(now)

          Repo.rollback({:budget_exhausted, seconds})

        true ->
          scheduled_at = next_slot(mapping.source_id, now, interval_ms)

          %RequestAttempt{}
          |> RequestAttempt.changeset(%{
            run_id: run.id,
            source_id: mapping.source_id,
            stage: stage,
            attempted_at: scheduled_at
          })
          |> Repo.insert!()

          transport_attempts =
            run.request_parameters
            |> Map.get("transport_attempts", %{})
            |> Map.put(stage, attempts + 1)

          request_parameters =
            Map.put(run.request_parameters, "transport_attempts", transport_attempts)

          {1, _} =
            Repo.update_all(
              from(r in Run, where: r.id == ^run.id),
              inc: [request_count: 1],
              set: [
                request_parameters: request_parameters,
                last_request_at: scheduled_at,
                updated_at: now
              ]
            )

          {:ok, max(DateTime.diff(scheduled_at, now, :millisecond), 0)}
      end
    end)
    |> case do
      {:ok, {:ok, wait_ms}} -> {:ok, wait_ms}
      {:error, {:budget_exhausted, seconds}} -> {:deferred, seconds}
      {:error, {:provider_backoff, seconds}} -> {:deferred, seconds}
      {:error, :attempts_exhausted} -> {:error, :attempts_exhausted}
    end
  end

  @doc "Persists provider-wide not-before time so visits and workers cannot bypass it."
  def defer_provider(run_id, retry_after, reason) do
    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id)
      mapping = Repo.get!(Mapping, run.mapping_id)
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [mapping.source_id])
      source = Repo.get!(Source, mapping.source_id)

      retry_after =
        case source.discovery_retry_after do
          nil ->
            retry_after

          current ->
            if(DateTime.compare(current, retry_after) == :gt, do: current, else: retry_after)
        end

      source
      |> Source.changeset(%{
        discovery_retry_after: retry_after,
        discovery_retry_reason: reason
      })
      |> Repo.update!()
    end)
  end

  defp seconds_until(future, now) do
    milliseconds = DateTime.diff(future, now, :millisecond)
    max(div(milliseconds + 999, 1_000), 1)
  end

  # Where this request may go: now, or the interval after the provider's latest
  # reserved slot, whichever is later. Unpaced providers are always "now".
  defp next_slot(_source_id, now, 0), do: now

  defp next_slot(source_id, now, interval_ms) do
    latest =
      Repo.one!(
        from attempt in RequestAttempt,
          where: attempt.source_id == ^source_id,
          select: max(attempt.attempted_at)
      )

    case latest do
      nil -> now
      latest -> Enum.max([now, DateTime.add(latest, interval_ms, :millisecond)], DateTime)
    end
  end

  defp oldest_attempt_at(source_id, cutoff) do
    Repo.one!(
      from attempt in RequestAttempt,
        where: attempt.source_id == ^source_id and attempt.attempted_at > ^cutoff,
        select: min(attempt.attempted_at)
    )
  end

  defp config(key),
    do: Application.fetch_env!(:devils_dictionary, :discovery) |> Keyword.fetch!(key)
end
