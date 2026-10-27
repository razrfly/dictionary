defmodule DevilsDictionary.Curation.Runtime.Snapshot do
  @moduledoc """
  What the ops Health page's "Editor runtime" card shows (#267 §3.4, #264
  R17): the runtime's current state, read with SELECTs only.

  `read/1` returns:

    * `:service`: the slot's row (`inference_services`) for the configured
      service key, or `nil`. A slot marked `available` says nothing about
      whether the process is running: the window's start and stop live in
      its record;
    * `:database`: the connected database's name;
    * `:authority`: the marker in the run directory, read and never
      written (`Runtime.Authority.bound/1`): `%{database, service_key,
      here}`, `:unbound` or `:unreadable`. `here` says whether it names the
      connected database and cluster;
    * `:model_configs`: every registered model config, oldest first;
    * `:today`: the UTC day's inference from the service's ledger
      (`inference_ledger_entries`), `%{day, charged_ms, reserved_ms,
      limit_ms}`, or `nil` without a service row;
    * `:last_smoke` and `:last_attempt`: the service's newest readiness smoke
      and newest attempt of any purpose, or `nil`.

  **Non-mutating.** It never calls `Gateway.service!/1`, which inserts the
  service row, nor `Gateway.budget/2` or `Readiness.check/2`, which reach
  it, nor anything that speaks HTTP or touches the process
  (`ServiceProcess`). An empty database reads as `nil`s and `[]`.

  Pending review units are #264's (its "Proposals" card), not the runtime's:
  an idle slot implies nothing about review work.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.Runtime.{
    Attempt,
    Authority,
    Endpoint,
    LedgerEntry,
    ModelConfig,
    Service
  }

  alias DevilsDictionary.Repo

  @doc """
  The snapshot. `opts`: `:service_key`, `:run_dir` and `:system` (as
  everywhere in the runtime), and `:today` (a `Date`, the UTC day by
  default).
  """
  def read(opts \\ []) do
    key = Endpoint.get(:service_key, opts)
    service = Repo.get_by(Service, key: key)
    identity = Authority.identity(opts)

    %{
      service: service,
      database: identity["database"],
      authority: authority(identity, opts),
      model_configs: Repo.all(from c in ModelConfig, order_by: c.id),
      today: today(service, Keyword.get_lazy(opts, :today, &Date.utc_today/0), opts),
      last_smoke: last_attempt(service, :readiness_smoke),
      last_attempt: last_attempt(service, nil)
    }
  end

  defp authority(identity, opts) do
    case Authority.bound(opts) do
      {:ok, marker} ->
        %{
          database: marker["database"],
          service_key: marker["service_key"],
          here: marker == identity
        }

      :unbound ->
        :unbound

      {:error, :unreadable} ->
        :unreadable
    end
  end

  defp today(nil, _day, _opts), do: nil

  defp today(%Service{id: id}, day, opts) do
    sums =
      Repo.all(
        from e in LedgerEntry,
          where: e.service_id == ^id and e.day == ^day,
          group_by: e.kind,
          select: {e.kind, sum(e.amount_ms)}
      )
      |> Map.new()

    %{
      day: day,
      charged_ms: Map.get(sums, :charge, 0),
      reserved_ms: Map.get(sums, :reserve, 0) - Map.get(sums, :release, 0),
      limit_ms: Endpoint.get(:daily_budget_ms, opts)
    }
  end

  defp last_attempt(nil, _purpose), do: nil

  defp last_attempt(%Service{id: id}, purpose) do
    query = from a in Attempt, where: a.service_id == ^id, order_by: [desc: a.id], limit: 1
    query = if purpose, do: where(query, [a], a.purpose == ^purpose), else: query
    Repo.one(query)
  end
end
