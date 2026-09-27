defmodule DevilsDictionary.Curation.ConfigurationMember do
  @moduledoc """
  One seat on a configuration version's roster: an exact profile version, a
  slot, and weight 1 (C5).
  """
  use Ecto.Schema

  schema "curation_configuration_members" do
    field :configuration_version_id, :id
    field :profile_id, :id
    field :profile_version_id, :id
    field :slot, :integer
    field :voting_weight, :integer, default: 1

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
