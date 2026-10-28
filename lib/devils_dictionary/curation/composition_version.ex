defmodule DevilsDictionary.Curation.CompositionVersion do
  @moduledoc """
  One immutable arrangement of a composition (#196): at most one lead and
  three highlights, frozen against a configuration version and a scope.

  `origin` is `manual` (K9: the author is a human account, and there is no
  run, participant or ballot) or `model` (#264 R9): a proposal, written by the
  bound generic editor's bot actor from one completed attempt
  (`attempt_id`), which is never accepted or published itself, only taken
  into a manual version (R11, R13). The database checks both, and
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
    field :origin, Ecto.Enum, values: [:manual, :model], default: :manual
    field :attempt_id, :id
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
