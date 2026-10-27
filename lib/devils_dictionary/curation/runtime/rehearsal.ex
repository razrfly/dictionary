defmodule DevilsDictionary.Curation.Runtime.Rehearsal do
  @moduledoc """
  A rehearsal (#267 §6): one real page's packet, run once through the
  runtime as an **attempt only**, with the readings the benchmark takes, and
  a record of what happened.

      mix dd.runtime rehearse --model-config SLUG --scope love --dry-run
      mix dd.runtime rehearse --model-config SLUG --scope love [--out PATH]

  In order:

    1. the service must be bound to the connected database
       (`Runtime.Authority`), or the rehearsal refuses `foreign_authority`
       (or `authority_unbound`, `authority_unreadable`) and touches nothing
       else;
    2. the page's packet is built as the screen offers it
       (`Packet.for_page/2` over `Candidates.for_page/1`), for the model
       config's pinned instruction, and frozen;
    3. readiness must pass (`Readiness.check/2`): a refusal such as
       `service_unreachable` is recorded and nothing is sent;
    4. the frozen packet runs once through `Runtime.run/3`, as the operator's
       actor, under the request key `rehearsal:<config slug>:<packet hash>`,
       while the service tree's resident set is sampled
       (`Bench.with_peak_rss/2`), with memory, swap and the loaded model read
       before and after (`Runtime.System.memory/0`, `Bench.service_facts/1`).

  The same scope and packet replay the same receipt: the request key is the
  packet's, so a second rehearsal of unchanged inputs sends nothing, and its
  record says `replay`.

  A rehearsal writes the attempt and its ledger entries (`Runtime.run/3`)
  and one JSON record, never over an existing one: it claims the record's
  path by creating it exclusively before anything else, so two rehearsals
  given the same path cannot both run. It writes no composition,
  review, publication, refresh state or page row, and visits nothing: the
  refresh clock is untouched. The record keeps ids, hashes, the validated
  answer (whose quotes are hashes and ranges) and the readings, never excerpt
  or label text.

  The dry run (`dry_run/3`) builds and freezes the same packet and calls and
  writes nothing.
  """

  alias DevilsDictionary.Curation.Candidates
  alias DevilsDictionary.Curation.Runtime

  alias DevilsDictionary.Curation.Runtime.{
    Authority,
    Bench,
    Endpoint,
    Gateway,
    ModelConfig,
    Packet,
    Readiness
  }

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage

  @record_version "runtime-rehearsal-v1"
  @dir "priv/curation/runtime_bench/rehearsals"

  @doc "Where records go by default: `#{@dir}/<UTC date>/<scope>.json`."
  def default_path(scope, date \\ Date.utc_today()),
    do: Path.join([@dir, Date.to_iso8601(date), "#{scope}.json"])

  @doc "The request key of a rehearsal: the config's slug and the frozen packet's hash."
  def request_key(%ModelConfig{slug: slug}, %{hash: hash}), do: "rehearsal:#{slug}:#{hash}"

  @doc """
  Builds and freezes the scope's packet for the config's instruction, as the
  dry run prints it and the rehearsal sends it. `{:ok, prepared}`, with
  `:page`, `:candidates`, `:packet`, `:frozen` and `:request_key`, or
  `{:error, reason}` (`Packet.for_page/2`'s and `Packet.freeze/2`'s
  refusals). Reads only. `opts`: `:language` (`"en"`).
  """
  def prepare(scope, %ModelConfig{} = config, opts \\ []) do
    page =
      scope
      |> Lexicon.lookup(Keyword.get(opts, :language, "en"))
      |> WordPage.build(viewer: :public)

    candidates = Candidates.for_page(page)

    with {:ok, packet} <-
           Packet.for_page(page,
             instruction_version: config.instruction_version,
             candidates: candidates
           ),
         {:ok, frozen} <- Packet.freeze(packet) do
      {:ok,
       %{
         page: page,
         candidates: candidates,
         packet: packet,
         frozen: frozen,
         request_key: request_key(config, frozen)
       }}
    end
  end

  @doc """
  The dry run: `prepare/3`, which calls nothing and writes nothing, not even
  a file.
  """
  def dry_run(scope, %ModelConfig{} = config, opts \\ []), do: prepare(scope, config, opts)

  @doc """
  Rehearses one scope, and writes its record. Returns `{status, record}`,
  `status` one of `:ok` (answered: accepted, abstained or refused on
  validation), `:replay`, `:uncertain` (sent and unanswered: the service is
  quarantined, see `mix dd.runtime recover`) or `:refused` (nothing was
  sent; the record says at which step and why). `record["path"]` is where it
  was written.

  `{:error, {:record_exists, path}}`, before the database or the service is
  touched, when a record is already there: a record is never overwritten.
  The path is claimed atomically (created exclusively, holding a `running`
  stub) before the rehearsal starts, so a concurrent rehearsal given the
  same path gets this answer too. If the rehearsal raises, the claim is
  removed. A process killed mid-run leaves its `running` stub, which says
  what was being rehearsed and by whom.

  `opts`: `:actor_id`, the operator's actor id or a function returning it,
  called only once every check has passed, so a rehearsal refused at the
  authority, packet or readiness step adds no actor; `:out` (the record's
  path, `default_path/2` otherwise); `:language`; and the runtime's own
  (`:service_key`, `:run_dir`, `:system`, …).
  """
  def run(scope, %ModelConfig{} = config, opts) do
    path = Keyword.get_lazy(opts, :out, fn -> default_path(scope) end)

    case claim(path, scope, config) do
      :ok -> rehearse_claimed(path, scope, config, opts)
      :exists -> {:error, {:record_exists, path}}
    end
  end

  # The claimed path holds a `running` stub until the record replaces it.
  # A rehearsal that raises gives the path back.
  defp rehearse_claimed(path, scope, config, opts) do
    {status, record} = rehearse(scope, config, opts)
    record = Map.merge(record, %{"path" => path, "finished_at" => now()})
    File.write!(path, Jason.encode!(json(record), pretty: true))
    {status, record}
  catch
    kind, reason ->
      File.rm(path)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Exclusive creation is the atomic test: of two rehearsals given the same
  # path, exactly one creates it.
  defp claim(path, scope, config) do
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        stub = %{
          "record_version" => @record_version,
          "status" => "running",
          "scope" => scope,
          "model_config" => config.slug,
          "claimed_at" => DateTime.to_iso8601(now()),
          "owner" => Gateway.owner()
        }

        IO.binwrite(io, Jason.encode!(stub, pretty: true))
        File.close(io)
        :ok

      {:error, :eexist} ->
        :exists

      {:error, reason} ->
        raise File.Error, reason: reason, action: "claim the rehearsal record", path: path
    end
  end

  # ── the steps ─────────────────────────────────────────────────────────────

  defp rehearse(scope, config, opts) do
    record = %{
      "record_version" => @record_version,
      "scope" => scope,
      "language" => Keyword.get(opts, :language, "en"),
      "started_at" => now(),
      "database" => Authority.identity(opts)["database"],
      "model_config" =>
        Map.take(config, [
          :id,
          :slug,
          :model_name,
          :manifest_digest,
          :instruction_version,
          :runtime_version,
          :config_hash
        ])
    }

    # Only the bound database's callers share the slot: in any other, a
    # rehearsal touches nothing more.
    case Authority.check(opts) do
      {:ok, identity} -> packet_step(Map.put(record, "authority", identity), scope, config, opts)
      {:error, reason, detail} -> refused(record, "authority", reason, detail)
    end
  end

  defp packet_step(record, scope, config, opts) do
    case prepare(scope, config, opts) do
      {:ok, prepared} ->
        readiness_step(Map.put(record, "packet", packet(prepared)), config, prepared, opts)

      {:error, reason} ->
        refused(record, "packet", reason, nil)
    end
  end

  defp readiness_step(record, config, prepared, opts) do
    case Readiness.check(config, opts) do
      {:ok, report} ->
        call(Map.put(record, "readiness", report.checks), config, prepared, opts)

      {:error, reason, report} ->
        refused(Map.put(record, "readiness", report.checks), "readiness", reason, nil)
    end
  end

  defp call(record, config, prepared, opts) do
    runtime_opts =
      opts
      |> Keyword.drop([:out, :language, :actor_id])
      |> Keyword.merge(
        request_key: prepared.request_key,
        actor_id: actor_id(opts),
        purpose: :request
      )

    before = readings(opts)

    {result, peak} =
      Bench.with_peak_rss(fn -> Runtime.run(config, prepared.frozen, runtime_opts) end, opts)

    record =
      Map.merge(record, %{
        "request_key" => prepared.request_key,
        "readings" => %{"before" => before, "after" => readings(opts), "peak_rss_bytes" => peak}
      })

    case result do
      {:refused, reason} ->
        refused(record, "run", reason, nil)

      {status, receipt} when status in [:ok, :replay, :uncertain] ->
        {status, Map.merge(record, answered(status, receipt, prepared.packet))}
    end
  end

  defp actor_id(opts) do
    case Keyword.fetch!(opts, :actor_id) do
      fun when is_function(fun, 0) -> fun.()
      id -> id
    end
  end

  defp refused(record, step, reason, detail) do
    {:refused,
     Map.merge(record, %{
       "status" => "refused",
       "refused_at" => step,
       "refusal" => reason,
       "refusal_detail" => detail
     })}
  end

  # ── what the record keeps ─────────────────────────────────────────────────

  # The packet as the attempt keeps it (`Packet.summary/1`: ids, revisions,
  # hashes, the omitted list with reasons) and the counts a person reads.
  # Never excerpt or label text.
  defp packet(%{packet: packet, frozen: frozen}) do
    counts = packet["counts"] || %{}

    %{
      "hash" => frozen.hash,
      "bytes" => frozen.bytes,
      "candidates" => length(packet["candidates"]),
      "offered" => counts["offered"],
      "meanings" => length(packet["meanings"]),
      "meanings_total" => counts["meanings_total"],
      "omitted" => length(packet["omitted"] || []),
      "omitted_by_reason" => Enum.frequencies_by(packet["omitted"] || [], & &1["reason"]),
      "sources" => Map.new(packet["candidates"], &{&1["candidate_id"], &1["source"]}),
      "summary" => Packet.summary(frozen)
    }
  end

  defp answered(status, receipt, packet) do
    metrics = receipt.metrics || %{}
    by_id = Map.new(packet["candidates"], &{&1["candidate_id"], &1})

    %{
      "status" => to_string(status),
      "attempt" => receipt,
      "answer" => answer(receipt.result, by_id),
      "latency_ms" => %{
        "wall" => metrics["wall_ms"],
        "total" => metrics["total_duration_ms"],
        "load" => metrics["load_duration_ms"]
      },
      "tokens" => %{"prompt" => metrics["prompt_eval_count"], "output" => metrics["eval_count"]},
      "memory" => %{"before" => metrics["memory_before"], "after" => metrics["memory_after"]}
    }
  end

  defp answer(nil, _by_id), do: nil

  defp answer(result, by_id) do
    %{
      "decision" => result["decision"],
      "lead" => choice(result["lead"], by_id),
      "highlights" => Enum.map(result["highlights"] || [], &choice(&1, by_id)),
      "abstain_reason" => result["abstain_reason"]
    }
  end

  defp choice(nil, _by_id), do: nil

  defp choice(choice, by_id) do
    candidate = Map.get(by_id, choice["candidate_id"], %{})
    Map.merge(choice, Map.take(candidate, ["kind", "key", "source", "object_id"]))
  end

  # Memory and swap system-wide, and what the service has loaded.
  defp readings(opts) do
    memory =
      case Endpoint.system(opts).memory() do
        {:ok, m} -> m
        {:error, reason} -> %{unavailable: reason}
      end

    %{"at" => now(), "memory" => memory, "service" => Bench.service_facts(opts)}
  end

  defp now, do: DateTime.utc_now()

  # Receipts and refusals hold structs, atoms and tuples.
  defp json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json(%Date{} = d), do: Date.to_iso8601(d)

  defp json(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.delete(:__meta__) |> json()

  defp json(%{} = map), do: Map.new(map, fn {k, v} -> {k, json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(other), do: other
end
