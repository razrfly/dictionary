defmodule DevilsDictionary.Workers.EnrichWorker do
  @moduledoc """
  One on-demand fetch for one target, then materialize it.

  Two rules from #69 §5, and both are about not losing work:

    * the source's `rate_limit_ms/0` is honoured here, not inside the client, so
      three concurrent jobs against one API still pace themselves;
    * a quota or a 429 is a `{:snooze, seconds}`, **never** a discard. The
      client surfaces it as `{:rate_limited, seconds}` and it comes back round.

  A `{:absent, until}` result is a success: the marker row is the answer, and
  #69 §5's terminal-state table says we skip that target until `until`.
  """

  use Oban.Worker, queue: :enrich, max_attempts: 5

  alias DevilsDictionary.Absorb
  alias DevilsDictionary.Absorb.Materializer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => slug, "target" => target}}) do
    module = Absorb.source_module!(slug)

    Process.sleep(module.rate_limit_ms())

    case module.enrich(target, []) do
      {:ok, record} ->
        case Materializer.run(record, module) do
          {:ok, _counts} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:absent, _until} ->
        :ok

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
