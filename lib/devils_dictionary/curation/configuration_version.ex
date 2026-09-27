defmodule DevilsDictionary.Curation.ConfigurationVersion do
  @moduledoc """
  One immutable version of a configuration (#201).

  In this slice every version is **manual-only**. It carries a lead policy
  and a highlight limit, and no model configuration, because none has been
  validated (#195). `roster_hash` is the digest of its members, which the
  database checks at commit, so a roster cannot be extended later (C4).
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
