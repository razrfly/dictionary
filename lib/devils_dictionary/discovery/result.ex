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

    # The identifiers the provider proposed for this item, read back from its
    # source record's current revision at display time (#116 M3). Not a column:
    # the payload already holds them, and a shelf dedups across sources on them
    # without any provider's persisted results being rewritten.
    field :identifiers, {:array, :map}, virtual: true, default: []

    # Read at display time, never stored (#164 C5). `creator_links` is who the
    # registry says made this now — one current, publicly visible
    # `authored_by` per entry, `%{object_id, label}` — so a withdrawn credit
    # unlinks on the next render with nothing to invalidate. `object_kind` and
    # `content_revision_id` let the card send a content object to its evidence
    # page rather than present it as an entry.
    field :creator_links, {:array, :map}, virtual: true, default: []
    field :object_kind, Ecto.Enum, values: [:lexeme, :sense, :entity, :content], virtual: true
    field :content_revision_id, :id, virtual: true

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
