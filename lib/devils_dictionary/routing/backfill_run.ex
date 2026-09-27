defmodule DevilsDictionary.Routing.BackfillRun do
  @moduledoc """
  One Stage 2 backfill run (#194): the digests it is bound to, and when it
  started and finished. Its checkpoint is its `Routing.BackfillItem` rows.
  See `Routing.Backfill`.
  """
  use Ecto.Schema

  alias DevilsDictionary.Sources.Actor

  schema "routing_backfill_runs" do
    field :run_key, :string
    field :input_sha256, :string
    field :policy_sha256, :string
    field :policy_version, :string
    field :population_sha256, :string
    field :reviews_sha256, :string
    field :records, :integer
    belongs_to :actor, Actor
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
