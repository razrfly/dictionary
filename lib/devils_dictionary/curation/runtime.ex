defmodule DevilsDictionary.Curation.Runtime do
  @moduledoc """
  The curation runtime's one entry point (#195 stage A): send one frozen
  evidence packet to the private local model, and get a validated result or a
  precise refusal, with a durable receipt.

      Runtime.run(model_config, packet, request_key: "...", actor_id: id)

  In order:

    1. The packet fits the model config's context (`Packet.fits?/2`).
    2. Readiness passes (`Readiness.check/2`): the slot, the external volume,
       the version, the served digest and the manifest on the root.
    3. The packet still matches the registry (`Packet.verify/1`).
    4. Memory is not under pressure (`Runtime.System.memory/0`).
    5. It is admitted to the one slot (`Gateway.admit/3`).
    6. It is dispatched, which is committed before sending, then sent once.
       Only a refused connection is retried, at most twice.
    7. The answer is validated (`Contract.validate/3`) and recorded, and the
       slot is released and settled. A call that was sent and never answered
       leaves the service quarantined.
    8. Swap growth during the call pauses the service.

  It writes no composition, review, publication, claim or page row. The
  receipt is the attempt.
  """

  alias DevilsDictionary.Curation.Runtime.{
    Attempt,
    Authority,
    Contract,
    Endpoint,
    Gateway,
    ModelConfig,
    Ollama,
    Packet,
    Readiness,
    ServiceProcess
  }

  alias DevilsDictionary.Repo

  @doc """
  Runs one packet: a frozen map from `Packet.freeze/1`, a raw packet map, or
  a path to a packet file. Returns one of:

    * `{:ok, receipt}`: answered, whether accepted, abstained or refused on
      validation;
    * `{:replay, receipt}`: this request key has run before;
    * `{:uncertain, receipt}`: sent and unanswered, so the service is
      quarantined;
    * `{:refused, reason}`: nothing was admitted.

  `opts`: `:request_key` and `:actor_id` (required), and `:purpose`.
  """
  def run(config_or_slug, packet, opts) do
    with {:ok, config} <- model_config(config_or_slug),
         {:ok, frozen} <- prepare(packet, opts),
         :ok <- refuse(Packet.fits?(frozen, config.generation)),
         :ok <- ready(config, opts),
         :ok <- refuse(Packet.verify(frozen)),
         {:ok, before} <- memory_ok(opts) do
      admit_and_call(config, frozen, before, opts)
    end
  end

  @doc """
  The structured-output smoke call of readiness: a tiny fixed packet through
  the same slot, budget and validation of shape and references. It does not
  touch the registry. Returns what `run/3` returns.
  """
  def smoke(config_or_slug, opts) do
    with {:ok, config} <- model_config(config_or_slug),
         {:ok, frozen} <- Packet.freeze(smoke_packet()),
         :ok <- ready(config, opts),
         {:ok, before} <- memory_ok(opts) do
      frozen = decorate(frozen)

      admit_and_call(
        config,
        frozen,
        before,
        Keyword.merge(opts, purpose: :readiness_smoke, registry: false)
      )
    end
  end

  @doc "Resumes a paused service once readiness passes."
  def resume(config_or_slug, opts \\ []) do
    with {:ok, config} <- model_config(config_or_slug),
         {:ok, _report} <- readiness(config, Keyword.put(opts, :allow_paused, true)) do
      Gateway.resume(opts)
    end
  end

  @doc """
  Recovers a quarantined service. It stops the private service process and
  confirms it is gone, which is the proof that any old generation ended. It
  then settles the uncertain attempt and starts the service again. The
  service stays paused until `resume/2`.

  It stops nothing unless the caller's database is the one the service is
  bound to (`Runtime.Authority`) and that database's slot is quarantined.
  Otherwise a stray `recover` could end the authoritative caller's generation.
  `Gateway.recover/2` checks the quarantine again under the row lock.
  """
  def recover(opts \\ []) do
    with :ok <- bound_here(opts),
         :ok <- quarantined(opts),
         {:ok, confirmation} <- ServiceProcess.stop(opts),
         {:ok, recovered} <- Gateway.recover(confirmation, opts),
         {:ok, started} <- ServiceProcess.start(opts) do
      {:ok, Map.put(recovered, :started, started)}
    end
  end

  defp bound_here(opts) do
    case Authority.check(opts) do
      {:ok, _identity} -> :ok
      {:error, reason, _detail} -> {:error, reason}
    end
  end

  defp quarantined(opts) do
    case Gateway.service!(Keyword.get(opts, :service_key)) do
      %{state: :quarantined} -> :ok
      _other -> {:error, :not_quarantined}
    end
  end

  # ── the call ──────────────────────────────────────────────────────────────

  defp admit_and_call(config, frozen, before, opts) do
    case Gateway.admit(config, frozen, opts) do
      {:ok, attempt} ->
        {:ok, attempt} = Gateway.dispatch(attempt, opts)
        call(attempt, config, frozen, before, opts)

      {:replay, attempt} ->
        {:replay, receipt(attempt)}

      {:refused, reason} ->
        {:refused, reason}
    end
  end

  defp call(attempt, config, frozen, before, opts, retries \\ 0) do
    started = System.monotonic_time(:millisecond)
    max = Endpoint.get(:max_transport_retries, opts)

    case Ollama.chat(config, Packet.messages(frozen), Contract.schema(), opts) do
      {:ok, response} ->
        finish(
          attempt,
          response,
          frozen,
          before,
          System.monotonic_time(:millisecond) - started,
          opts
        )

      {:error, {:not_sent, _reason}} when retries < max ->
        {:ok, attempt} = Gateway.note_retry(attempt, opts)
        call(attempt, config, frozen, before, opts, retries + 1)

      {:error, {:not_sent, reason}} ->
        settled(Gateway.fail_pre_dispatch(attempt, reason, opts))

      {:error, {:uncertain, reason}} ->
        case Gateway.mark_uncertain(attempt, reason, opts) do
          {:ok, uncertain} -> {:uncertain, receipt(uncertain)}
          {:error, :stale} -> {:refused, :stale}
        end

      {:error, {:http, status, detail}} ->
        settled(
          Gateway.complete(
            attempt,
            %{
              outcome: :runtime_error,
              refusal_reasons: [["runtime", "http_#{status}"]],
              metrics: %{"runtime_detail" => detail}
            },
            opts
          )
        )
    end
  end

  defp finish(attempt, response, frozen, before, wall_ms, opts) do
    {outcome, result, reasons, observed} =
      case Contract.validate(response, frozen, opts) do
        {:ok, %{outcome: outcome, result: result, observed: observed}} ->
          {outcome, result, [], observed}

        {:refused, reasons, observed} ->
          {:refused, nil, reasons, observed}
      end

    after_memory = sample_memory(opts)

    metrics =
      response
      |> runtime_metrics()
      |> Map.merge(observed)
      |> Map.merge(%{
        "wall_ms" => wall_ms,
        "thinking_tokens" => "unknown",
        "memory_before" => before,
        "memory_after" => after_memory
      })

    result =
      Gateway.complete(
        attempt,
        %{outcome: outcome, result: result, refusal_reasons: reasons, metrics: metrics},
        opts
      )

    maybe_pause_for_memory(before, after_memory, opts)
    settled(result)
  end

  defp settled({:ok, attempt}), do: {:ok, receipt(attempt)}
  defp settled({:error, :stale}), do: {:refused, :stale}

  # Ollama reports nanoseconds. Counts it does not report stay absent, never
  # zero.
  defp runtime_metrics(response) do
    ms = fn key -> response[key] && div(response[key], 1_000_000) end

    %{
      "total_duration_ms" => ms.("total_duration"),
      "load_duration_ms" => ms.("load_duration"),
      "prompt_eval_count" => response["prompt_eval_count"],
      "prompt_eval_duration_ms" => ms.("prompt_eval_duration"),
      "eval_count" => response["eval_count"],
      "eval_duration_ms" => ms.("eval_duration")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # ── guards ────────────────────────────────────────────────────────────────

  defp ready(config, opts) do
    case readiness(config, opts) do
      {:ok, _report} -> :ok
      {:error, reason, _report} -> {:refused, reason}
    end
  end

  defp readiness(config, opts), do: Readiness.check(config, opts)

  defp memory_ok(opts) do
    case sample_memory(opts) do
      %{"free_percent" => free} = sample when is_integer(free) ->
        if free < Endpoint.get(:pause_min_free_percent, opts) do
          Gateway.pause(:memory_pressure, opts)
          {:refused, :memory_pressure}
        else
          {:ok, sample}
        end

      unknown ->
        {:ok, unknown}
    end
  end

  defp sample_memory(opts) do
    case Endpoint.system(opts).memory() do
      {:ok, m} ->
        %{"swap_used_bytes" => m.swap_used_bytes, "free_percent" => m.free_percent}

      {:error, _} ->
        %{"unavailable" => true}
    end
  end

  defp maybe_pause_for_memory(
         %{"swap_used_bytes" => a},
         %{"swap_used_bytes" => b, "free_percent" => free},
         opts
       ) do
    cond do
      b - a >= Endpoint.get(:pause_swap_growth_bytes, opts) -> Gateway.pause(:swap_growth, opts)
      free < Endpoint.get(:pause_min_free_percent, opts) -> Gateway.pause(:memory_pressure, opts)
      true -> :ok
    end
  end

  defp maybe_pause_for_memory(_before, _after, _opts), do: :ok

  defp refuse(:ok), do: :ok
  defp refuse({:error, reason}), do: {:refused, reason}

  # ── inputs and outputs ────────────────────────────────────────────────────

  defp model_config(%ModelConfig{} = config), do: {:ok, config}

  defp model_config(slug) when is_binary(slug) do
    case Repo.get_by(ModelConfig, slug: slug) do
      nil -> {:refused, :model_config_unknown}
      config -> {:ok, config}
    end
  end

  defp prepare(%{packet: _, hash: _} = frozen, _opts), do: {:ok, decorate(frozen)}

  defp prepare(path, _opts) when is_binary(path) do
    case Packet.read(path) do
      {:ok, frozen} -> {:ok, decorate(frozen)}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp prepare(%{} = packet, opts) do
    case Packet.freeze(packet, opts) do
      {:ok, frozen} -> {:ok, decorate(frozen)}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp decorate(frozen),
    do:
      Map.merge(frozen, %{
        summary: Packet.summary(frozen),
        prompt_sha256: Packet.prompt_sha256(frozen)
      })

  @doc "The receipt of an attempt: what an operator is told, and what the ledger holds."
  def receipt(%Attempt{} = a) do
    %{
      attempt_id: a.id,
      request_key: a.request_key,
      purpose: a.purpose,
      state: a.state,
      outcome: a.outcome,
      result: a.result,
      refusal_reasons: a.refusal_reasons,
      metrics: a.metrics,
      fence: a.fence,
      packet_hash: a.packet_hash,
      model_config_id: a.model_config_id,
      transport_retries: a.transport_retries,
      reserved_ms: a.reserved_ms,
      admitted_at: a.admitted_at,
      finished_at: a.finished_at
    }
  end

  @doc "The fixed, fictional packet of the smoke call."
  def smoke_packet do
    %{
      "packet_version" => Packet.version(),
      "instruction_version" => Packet.instruction_version(),
      "target" => %{"language_tag" => "en", "lexeme_ids" => [], "headwords" => ["smoke"]},
      "lead_policy" => "bierce_first_v1",
      "meanings" => [%{"meaning_id" => "m0", "kind" => "lexeme", "label" => "smoke"}],
      "candidates" => [
        %{
          "candidate_id" => "c1",
          "kind" => "content",
          "source" => "fixture",
          "excerpt" => "SMOKE, n. What rises when a quick test works at all.",
          "excerpt_sha256" =>
            DevilsDictionary.Curation.Digest.sha256(
              "SMOKE, n. What rises when a quick test works at all."
            ),
          "allowed_meanings" => ["m0"]
        }
      ],
      "priority_candidates" => []
    }
  end
end
