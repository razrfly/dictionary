defmodule DevilsDictionary.Discovery.RequestAttempt do
  @moduledoc "One outbound provider request, retained for rolling-budget accounting."

  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Discovery.Run
  alias DevilsDictionary.Sources.Source

  schema "discovery_request_attempts" do
    belongs_to :run, Run
    belongs_to :source, Source
    field :stage, :string
    field :attempted_at, :utc_datetime_usec
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:run_id, :source_id, :stage, :attempted_at])
    |> validate_required([:run_id, :source_id, :stage, :attempted_at])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:source_id)
  end
end
