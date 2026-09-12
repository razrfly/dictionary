defmodule DevilsDictionary.Discovery.Budget do
  @moduledoc "A database-coordinated rolling request budget shared across nodes."

  import Ecto.Query

  alias DevilsDictionary.Discovery.{Mapping, Run}
  alias DevilsDictionary.Repo

  @doc "Claims one outbound request for a run, or returns a conservative retry delay."
  def claim(run_id) do
    limit = config(:request_budget_per_minute)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -60, :second)

    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id)
      mapping = Repo.get!(Mapping, run.mapping_id)
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [mapping.source_id])

      used =
        Repo.one(
          from r in Run,
            join: m in Mapping,
            on: m.id == r.mapping_id,
            where: m.source_id == ^mapping.source_id and r.last_request_at > ^cutoff,
            select: coalesce(sum(r.request_count), 0)
        )

      if used >= limit do
        Repo.rollback({:budget_exhausted, 60})
      else
        {1, _} =
          Repo.update_all(
            from(r in Run, where: r.id == ^run.id),
            inc: [request_count: 1],
            set: [last_request_at: now, updated_at: now]
          )

        :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, {:budget_exhausted, seconds}} -> {:deferred, seconds}
    end
  end

  defp config(key),
    do: Application.fetch_env!(:devils_dictionary, :discovery) |> Keyword.fetch!(key)
end
