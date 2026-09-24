defmodule DevilsDictionary.Discovery.RequestAttempt do
  @moduledoc "One outbound provider request, retained for rolling-budget accounting."

  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Discovery.Run
  alias DevilsDictionary.Quotations.VerificationRun
  alias DevilsDictionary.Sources.Source

  schema "discovery_request_attempts" do
    # Exactly one of the two (a database check): a discovery run spends a
    # provider's budget, a verification run a checker's (#158 build 5).
    belongs_to :run, Run
    belongs_to :verification_run, VerificationRun
    belongs_to :source, Source
    field :stage, :string
    field :attempted_at, :utc_datetime_usec
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:run_id, :verification_run_id, :source_id, :stage, :attempted_at])
    |> validate_required([:source_id, :stage, :attempted_at])
    |> check_constraint(:run_id, name: :discovery_request_attempts_one_run)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:verification_run_id)
    |> foreign_key_constraint(:source_id)
  end
end
