defmodule DevilsDictionary.Curation.CompositionVersion do
  @moduledoc """
  One immutable arrangement of a composition (#196): at most one lead and
  three highlights, frozen against a configuration version and a scope.

  Manual only in this slice (K9). `origin` is `manual`, the author is a human
  account, and there is no run, participant or ballot. The database checks
  `arrangement_hash` against the items at commit (K5).

  `eligibility_fingerprint` records the items' eligibility when the version
  was made. A review accepts that fingerprint and a publication publishes it
  (R4).
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  schema "editorial_composition_versions" do
    field :composition_id, :id
    field :curation_configuration_id, :id
    field :configuration_version_id, :id
    field :version, :integer
    field :parent_version_id, :id
    field :origin, Ecto.Enum, values: [:manual], default: :manual
    field :change_reason, :string
    field :created_by_actor_id, :id
    field :scope_signature, :string
    field :scope_members, JsonValue
    field :resolution, :map
    field :lead_policy, Ecto.Enum, values: [:bierce_first_v1]
    field :arrangement_hash, :string
    field :eligibility_fingerprint, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
