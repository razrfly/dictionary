defmodule DevilsDictionary.Discovery.Run do
  @moduledoc "One bounded provider attempt, including its immutable request and outcome."

  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Discovery.Mapping

  @statuses [:pending, :running, :succeeded, :failed]
  @reasons [:results, :no_exact_keyword, :no_results, :transient_results]

  schema "discovery_runs" do
    belongs_to :mapping, Mapping
    field :adapter_version, :string
    field :request_parameters, :map, default: %{}
    field :request_key, :string
    field :position_key, :string
    field :page_context, Ecto.UUID
    field :page, :integer, default: 0
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :refresh_after, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :retry_at, :utc_datetime_usec
    field :next_cursor, :string
    field :error_code, :string
    field :completion_reason, Ecto.Enum, values: @reasons
    field :result_count, :integer, default: 0
    field :request_count, :integer, default: 0
    field :last_request_at, :utc_datetime_usec
    field :display_allowed, :boolean, default: true

    has_many :results, DevilsDictionary.Discovery.Result

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def completion_reasons, do: @reasons

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :mapping_id,
      :adapter_version,
      :request_parameters,
      :request_key,
      :position_key,
      :page_context,
      :page,
      :status
    ])
    |> validate_required([
      :mapping_id,
      :adapter_version,
      :request_parameters,
      :request_key,
      :position_key,
      :page_context,
      :page,
      :status
    ])
    |> validate_number(:page, greater_than_or_equal_to: 0)
    |> unique_constraint([:mapping_id, :request_key],
      name: :discovery_runs_one_in_flight_index
    )
    |> foreign_key_constraint(:mapping_id)
  end

  def lifecycle_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :request_parameters,
      :status,
      :started_at,
      :completed_at,
      :refresh_after,
      :expires_at,
      :retry_at,
      :next_cursor,
      :error_code,
      :completion_reason,
      :result_count,
      :request_count,
      :last_request_at,
      :display_allowed
    ])
    |> validate_number(:result_count, greater_than_or_equal_to: 0)
    |> validate_number(:request_count, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :discovery_runs_terminal_shape)
  end
end
