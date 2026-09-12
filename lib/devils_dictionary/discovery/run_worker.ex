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
  rescue
    exception ->
      DevilsDictionary.Discovery.release_run_for_retry(run_id, "worker_exception")
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      DevilsDictionary.Discovery.release_run_for_retry(run_id, "worker_#{kind}")
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
end
