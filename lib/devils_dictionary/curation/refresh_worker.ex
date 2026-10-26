defmodule DevilsDictionary.Curation.RefreshWorker do
  @moduledoc """
  One curation check (#259 §5.3), on its own queue, `:curation`.

  Claims the refresh row on the job's generation (refused, and the job
  cancelled, unless the row is queued on it), reads the composition's inputs
  for the On page that admitted it, and completes as `:unchanged` or
  `:needs_editor` under the fence `Curation.Refresh` keeps. A failure reading
  the inputs defers the run with backoff. **No model is called and the
  published pointer never moves.**

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
