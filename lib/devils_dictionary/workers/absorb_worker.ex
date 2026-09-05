defmodule DevilsDictionary.Workers.AbsorbWorker do
  @moduledoc """
  Runs one source's `absorb/2` as a job, with the same `import_runs` bookkeeping
  the mix task does.

  The dump absorbs are synchronous by design (S0/S1) and stay that way — this
  exists so the import dashboard can start one from a button, and so a long
  Wikidata or Wikipedia pass can be kicked off without holding a terminal.
  """

  use Oban.Worker, queue: :absorb, max_attempts: 3

  alias DevilsDictionary.{Absorb, Lexicon, Sources}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => slug} = args}) do
    module = Absorb.source_module!(slug)
    source = Sources.get_source_by_slug!(slug)
    scope = args["scope"] && Lexicon.get_scope_by_slug!(args["scope"])

    run =
      Sources.start_run(args["task"] || "absorb",
        source_id: source.id,
        scope_id: scope && scope.id
      )

    started = System.monotonic_time(:millisecond)

    try do
      {:ok, stats} = module.absorb(scope, opts(args))
      elapsed = System.monotonic_time(:millisecond) - started

      Sources.finish_run(run, stringify(Map.put(stats, :elapsed_ms, elapsed)))
      :ok
    rescue
      error ->
        elapsed = System.monotonic_time(:millisecond) - started
        Sources.fail_run(run, Exception.message(error), %{"elapsed_ms" => elapsed})
        reraise error, __STACKTRACE__
    end
  end

  defp opts(args) do
    for {k, v} <- args, k not in ~w(source scope task), do: {String.to_existing_atom(k), v}
  end

  defp stringify(stats), do: Map.new(stats, fn {k, v} -> {to_string(k), v} end)
end
