defmodule DevilsDictionary.Curation.ConfigurationVersion do
  @moduledoc """
  One immutable version of a configuration (#201).

  Carries immutable lead/highlight policy, roster and optional pinned editor
  binding. Publication defaults to manual; explicit single_editor_v1 permits
  agent authority only while that editor is enabled (#275 owner amendment).
  `roster_hash` is the digest of its members, checked at commit, so a roster
  cannot be extended later. Binding, activation and enablement stay separate.
  """
  use Ecto.Schema

  schema "curation_configuration_versions" do
    field :configuration_id, :id
    field :version, :integer
    field :manifest_hash, :string
    field :manifest, :map
    field :lead_policy, Ecto.Enum, values: [:bierce_first_v1]
    field :max_highlights, :integer, default: 3
    field :roster_hash, :string
    field :created_by_actor_id, :id
    field :change_reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
