defmodule DevilsDictionary.Curation.Runtime.Endpoint do
  @moduledoc """
  The curation runtime's operational configuration (#195): where the private
  service listens, where its model cache lives, and the limits a call runs
  under.

  This is deliberately *not* provenance. What a model is lives in an
  immutable `local_model_configs` row (`Runtime.ModelConfig`). Moving the
  endpoint never changes a recorded attempt, and no persona has an endpoint of
  its own.
  """

  @defaults [
    service_key: "studio-ollama",
    base_url: "http://127.0.0.1:11435",
    mount_point: "/Volumes/LLM Models",
    models_root: "/Volumes/LLM Models/dictionary/ollama",
    run_dir: "/Volumes/LLM Models/dictionary/run",
    binary: "/Volumes/LLM Models/dictionary/bin/ollama",
    deadline_ms: 120_000,
    reservation_margin_ms: 5_000,
    daily_budget_ms: 30 * 60_000,
    pending_cap_units: 30,
    max_candidates: 12,
    max_excerpt_chars: 1_200,
    max_output_bytes: 16_384,
    max_transport_retries: 2,
    pause_after_failures: 3,
    pause_swap_growth_bytes: 512 * 1024 * 1024,
    pause_min_free_percent: 10,
    system: DevilsDictionary.Curation.Runtime.System
  ]

  @doc "The whole configuration, with defaults."
  def config do
    Keyword.merge(@defaults, Application.get_env(:devils_dictionary, :curation_runtime, []))
  end

  @doc "One setting, overridable per call by `opts`."
  def get(key, opts \\ []), do: Keyword.get(opts, key, Keyword.fetch!(config(), key))

  @doc "Extra Req options: the `Req.Test` plug in the suite, nothing in production."
  def req_options, do: Application.get_env(:devils_dictionary, :curation_runtime_req_options, [])

  @doc "The system inspector: the real host, or the suite's fake."
  def system(opts \\ []), do: get(:system, opts)

  @doc "What one call may occupy, and so what admission reserves."
  def reservation_ms(opts \\ []), do: get(:deadline_ms, opts) + get(:reservation_margin_ms, opts)

  @doc "The loopback port the private service listens on."
  def port(opts \\ []), do: URI.parse(get(:base_url, opts)).port
end
