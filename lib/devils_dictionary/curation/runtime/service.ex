defmodule DevilsDictionary.Curation.Runtime.Service do
  @moduledoc """
  One physical inference runtime and its single slot (#195, G1, G2).

  Every caller that names the same `key` goes through this row, on any node.
  Its row lock serializes admission, and its state says what the slot is
  doing:

    * `available`: nothing holds it;
    * `occupied`: `holder_attempt_id` holds it under `fence`;
    * `quarantined`: an attempt's completion is uncertain, and nothing may run
      until a controlled stop proves the old generation ended;
    * `paused`: memory pressure, repeated failures or a recovery awaiting
      readiness, until an operator resumes it.

  `fence` increases with every admission, so a late answer from an earlier
  holder is recognized and refused. `epoch` increases with every confirmed
  restart of the service.
  """
  use Ecto.Schema

  @states [:available, :occupied, :quarantined, :paused]

  schema "inference_services" do
    field :key, :string
    field :state, Ecto.Enum, values: @states, default: :available
    field :holder_attempt_id, :id
    field :fence, :integer, default: 0
    field :epoch, :integer, default: 0
    field :lease_expires_at, :utc_datetime_usec
    field :quarantine_reason, :string
    field :paused_reason, :string
    field :consecutive_failures, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
end
