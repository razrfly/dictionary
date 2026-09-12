defmodule DevilsDictionary.Discovery.RunWorker do
  @moduledoc "Executes an admitted discovery run outside the definition request."

  use Oban.Worker,
    queue: :discovery,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:run_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    DevilsDictionary.Discovery.execute_run(run_id)
  end
end
