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
    # What the server starts, beside its own binary, to hold a loaded model:
    # `llama-server` under Ollama 0.34.4. A stop ends one a dead server left
    # behind (#221 S1).
    runner_names: ["llama-server"],
    deadline_ms: 120_000,
    reservation_margin_ms: 5_000,
    daily_budget_ms: 30 * 60_000,
    pending_cap_units: 30,
    max_candidates: 12,
    # Packet v2's cut (#253 §5a, #262): the quotas by kind, in the order
    # unused quota flows down; the meaning bound; the source priority a kind
    # is filled in. Each policy names its version, which the refresh
    # fingerprint carries: a change of policy should name a new version.
    candidate_quotas: [content: 4, sense_quotation: 3, work: 3, exemplar: 2],
    max_meanings: 12,
    source_priority: ~w(bierce johnson wordnet wiktionary wikipedia),
    cut_policy: "cut-v1",
    meaning_policy: "meanings-v2",
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

  @doc """
  How often a refused connection is retried: `{:ok, n}`, or `{:error,
  {:transport_retries_out_of_bounds, n, ceiling}}` when the configuration
  asks for more than the database allows
  (`Runtime.Attempt.max_transport_retries/0`). The configuration may lower
  the count, never raise it (#221 A1).
  """
  def transport_retries(opts \\ []) do
    n = get(:max_transport_retries, opts)
    ceiling = DevilsDictionary.Curation.Runtime.Attempt.max_transport_retries()

    if is_integer(n) and n >= 0 and n <= ceiling,
      do: {:ok, n},
      else: {:error, {:transport_retries_out_of_bounds, n, ceiling}}
  end

  @doc "What one call may occupy, and so what admission reserves."
  def reservation_ms(opts \\ []), do: get(:deadline_ms, opts) + get(:reservation_margin_ms, opts)

  @doc "The loopback port the private service listens on."
  def port(opts \\ []), do: URI.parse(get(:base_url, opts)).port
end
