defmodule DevilsDictionary.Discovery.Budget do
  @moduledoc "A database-coordinated rolling request budget shared across nodes."

  import Ecto.Query

  alias DevilsDictionary.Discovery.{Mapping, RequestAttempt, Run}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @doc "Claims one outbound request for a run, or returns a conservative retry delay."
  def claim(run_id, stage) when is_binary(stage) do
    limit = config(:request_budget_per_minute)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -60, :second)

    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id)
      mapping = Repo.get!(Mapping, run.mapping_id)
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [mapping.source_id])
      source = Repo.get!(Source, mapping.source_id)
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

        used >= limit ->
          Repo.rollback({:budget_exhausted, 60})

        true ->
          %RequestAttempt{}
          |> RequestAttempt.changeset(%{
            run_id: run.id,
            source_id: mapping.source_id,
            stage: stage,
            attempted_at: now
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
                last_request_at: now,
                updated_at: now
              ]
            )

          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
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

  defp seconds_until(future, now), do: max(DateTime.diff(future, now, :second), 1)

  defp config(key),
    do: Application.fetch_env!(:devils_dictionary, :discovery) |> Keyword.fetch!(key)
end
