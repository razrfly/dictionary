defmodule DevilsDictionary.Discovery.Result do
  @moduledoc "A normalized provider item and the factual reason it matched."

  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Discovery.Run
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Sources.SourceRecord

  schema "discovery_results" do
    belongs_to :run, Run
    field :external_namespace, :string
    field :external_id, :string
    belongs_to :object, Object
    belongs_to :source_record, SourceRecord
    field :position, :integer
    field :match_details, :map, default: %{}
    field :preview_metadata, :map, default: %{}
    field :display_allowed, :boolean, default: true

    field :resolution_state, Ecto.Enum,
      values: [:matched, :newly_created, :insufficient_evidence, :conflicting_identifiers],
      default: :insufficient_evidence

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :run_id,
      :external_namespace,
      :external_id,
      :object_id,
      :source_record_id,
      :position,
      :match_details,
      :preview_metadata,
      :display_allowed,
      :resolution_state
    ])
    |> validate_required([
      :run_id,
      :external_namespace,
      :external_id,
      :position,
      :match_details,
      :preview_metadata,
      :display_allowed,
      :resolution_state
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:run_id, :external_namespace, :external_id])
    |> unique_constraint([:run_id, :position])
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:object_id)
    |> foreign_key_constraint(:source_record_id)
    |> check_constraint(:resolution_state, name: :discovery_results_resolution_state)
  end
end
