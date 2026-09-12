defmodule DevilsDictionary.Discovery.CleanupWorker do
  @moduledoc "Scheduled, bounded cache cleanup and abandoned-run recovery."

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 14 * 60, fields: [:worker], states: [:available, :scheduled, :executing]]

  @impl Oban.Worker
  def perform(_job) do
    _summary = DevilsDictionary.Discovery.cleanup()
    :ok
  end
end
