defmodule DevilsDictionary.Quotations.VerifyWorker do
  @moduledoc """
  The verifier's clock (#158 build 5): on each tick, the people whose
  quotations are due are verified, a few at a time. Due is
  `VerificationRun.refresh_after` — thirty days after a success, the
  retry time after a deferral — so re-verification is a refresh rule
  (#144's shape), never a rerun of a shelf.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 25 * 60, fields: [:worker], states: [:available, :scheduled, :executing]]

  alias DevilsDictionary.Quotations.Verifier

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Verifier.run_due(Map.get(args, "limit", 5))
    :ok
  end
end
