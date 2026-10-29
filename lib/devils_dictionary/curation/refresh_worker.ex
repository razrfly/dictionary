defmodule DevilsDictionary.Curation.RefreshWorker do
  @moduledoc """
  One curation check (#259 §5.3), on its own queue, `:curation`.

  Claims the refresh row on the job's generation (refused, and the job
  cancelled, unless the row is queued on it), reads the composition's inputs
  for the On page that admitted it, and completes as `:unchanged` or
  `:needs_editor` under the fence `Curation.Refresh` keeps. A failure reading
  the inputs defers the run with backoff. **The published pointer never
  moves under manual policy; explicit single_editor_v1 policy may publish a
  validated accepted choice through the same fenced record.**

  **The editor (#264 R3).** The worker still makes two calls, `claim` and
  `check`. While the editor is enabled for the run's configuration version,
  `Refresh.check/3` hands a run that needs an editor to
  `Curation.Proposals.step/3` inside the same claim: the frozen packet goes
  to the pinned model, within the running lease, and a validated answer
  becomes a proposal. A service that is down defers the run with backoff,
  never advancing freshness and never delaying a reader: the call is here,
  in the worker, never in a request (#264 R6). While the editor is off, no
  model is called.

  `unique` only coalesces a duplicate insert of the same row's job; the
  correctness boundary is the row lock, the generation and the token
  (`Curation.Refresh`). A job that crashes after its claim leaves the row
  `:running` until its lease expires, and the next visit recovers it.
  """
  use Oban.Worker,
    queue: :curation,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:refresh_state_id],
      states: [:available, :scheduled, :retryable]
    ]

  alias DevilsDictionary.Curation.Refresh

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"refresh_state_id" => id, "generation" => generation, "slug" => slug}
      }) do
    with {:ok, claim} <- Refresh.claim(id, generation),
         {:ok, _row} <- Refresh.check(claim, slug) do
      :ok
    else
      {:error, reason} -> {:cancel, reason}
    end
  end
end
