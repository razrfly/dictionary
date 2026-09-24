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
    |> outcome()
  end

  @doc """
  Claims one request against a **shared** budget: a source that is not the
  run's provider, spent on that run's behalf.

  #164 C1: minting a creator fetches Wikidata inside a discovery run, and the
  per-process 200 ms sleep in `Absorb.Clients.HTTP` is pacing for one process,
  not a budget. So the fetch is drawn against the `wikidata` source's own row
  in `source_policies`, counted in `discovery_request_attempts` under that
  source's id and the run that caused it — which is what makes it appear in the
  operator's view beside the provider that asked, and what lets two runs on
  two nodes share one window. The run's own `transport_attempts` and
  `request_count` are the provider's and are not touched.

  `run` is a discovery run's id, or `{:verification, id}` for the quotation
  verifier's run (#158 build 5), whose checkers — Gutenberg, Wikiquote's author
  pages, Wikidata — are spent from outside any discovery run.

  Same answers as `claim/3`: `{:ok, wait_ms}`, `{:deferred, seconds}` or
  `{:error, reason}`.
  """
  def claim_shared(source_slug, run, stage, opts \\ [])
      when is_binary(source_slug) and is_binary(stage) do
    run_ref =
      case run do
        {:verification, id} -> %{run_id: nil, verification_run_id: id}
        id -> %{run_id: id, verification_run_id: nil}
      end

    now = DateTime.utc_now()
    interval_ms = Keyword.get(opts, :request_interval_ms, 0)

    Repo.transaction(fn ->
      source =
        Repo.get_by(Source, slug: source_slug) || Repo.rollback(:shared_source_missing)

      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [source.id])
      policy = Policy.for!(source.slug)
      cutoff = DateTime.add(now, -policy.request_budget_window_seconds, :second)

      used =
        Repo.aggregate(
          from(attempt in RequestAttempt,
            where: attempt.source_id == ^source.id and attempt.attempted_at > ^cutoff
          ),
          :count
        )

      if used >= policy.request_budget_limit do
        seconds =
          source.id
          |> oldest_attempt_at(cutoff)
          |> DateTime.add(policy.request_budget_window_seconds, :second)
          |> seconds_until(now)

        Repo.rollback({:budget_exhausted, seconds})
      end

      scheduled_at = next_slot(source.id, now, interval_ms)

      %RequestAttempt{}
      |> RequestAttempt.changeset(
        Map.merge(run_ref, %{source_id: source.id, stage: stage, attempted_at: scheduled_at})
      )
      |> Repo.insert!()

      {:ok, max(DateTime.diff(scheduled_at, now, :millisecond), 0)}
    end)
    |> outcome()
  end

  @doc """
  What one transaction result means to the caller: a slot, a wait, or a refusal.

  Named and public because it has to be **total**, and because that is the one
  thing a test can hold it to. The three rollbacks above are the three this
  function writes today; before #144 Phase 0 the `case` listed exactly those
  and nothing else, so any other transaction failure — a serialization error
  under concurrency, a rollback a later clause adds and forgets to map, the
  adapter's own `{:error, :rollback}` — left this function as a
  `CaseClauseError` raised through `Discovery.Transport` and out of a run that
  had no way to recover from it. A failed claim spent nothing; the honest
  answer is a refusal the run can fail on and retry.
  """
  def outcome({:ok, {:ok, wait_ms}}), do: {:ok, wait_ms}
  def outcome({:error, {:budget_exhausted, seconds}}), do: {:deferred, seconds}
  def outcome({:error, {:provider_backoff, seconds}}), do: {:deferred, seconds}
  def outcome({:error, :attempts_exhausted}), do: {:error, :attempts_exhausted}
  def outcome({:error, _other}), do: {:error, :claim_failed}

  @doc "Persists provider-wide not-before time so visits and workers cannot bypass it."
  def defer_provider(run_id, retry_after, reason) do
    run = Repo.get!(Run, run_id)
    mapping = Repo.get!(Mapping, run.mapping_id)
    defer_source(mapping.source_id, retry_after, reason)
  end

  @doc """
  The same not-before time, on a source by id — for callers outside a
  discovery run (the quotation verifier). Never moves an existing time earlier.
  """
  def defer_source(source_id, retry_after, reason) do
    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [source_id])
      source = Repo.get!(Source, source_id)

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
