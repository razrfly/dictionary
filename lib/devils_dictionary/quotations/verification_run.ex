defmodule DevilsDictionary.Quotations.VerificationRun do
  @moduledoc """
  One verification pass over everything credited to (or misattributed to) one
  person (#158 build 5). The run is the ledger row the verifier's requests are
  budgeted against — `discovery_request_attempts.verification_run_id` — and
  the refresh clock that makes re-verification a rule rather than a rerun
  (`refresh_after`, #144's shape). Why a table of its own and not a discovery
  run: `docs/integrations/verifier.md`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object

  @statuses [:pending, :running, :succeeded, :deferred, :failed]

  schema "verification_runs" do
    belongs_to :subject_object, Object
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :refresh_after, :utc_datetime_usec
    field :request_count, :integer, default: 0
    field :error_code, :string
    field :summary, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :subject_object_id,
      :status,
      :started_at,
      :completed_at,
      :refresh_after,
      :request_count,
      :error_code,
      :summary
    ])
    |> validate_required([:subject_object_id, :status])
    |> check_constraint(:status, name: :verification_runs_status)
  end
end
