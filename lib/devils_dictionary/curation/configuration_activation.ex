defmodule DevilsDictionary.Curation.ConfigurationActivation do
  @moduledoc """
  The receipt for a configuration's pointer or state moving (C3, C8). It
  records who activated or disabled which version, from which, and why.

  Append-only. The database checks at commit that the configuration matches
  its latest receipt, and that each receipt continues from the one before it.
  """
  use Ecto.Schema

  schema "curation_configuration_activations" do
    field :configuration_id, :id
    field :action, Ecto.Enum, values: [:activate, :disable]
    field :configuration_version_id, :id
    field :previous_version_id, :id
    field :actor_id, :id
    field :reason, :string
    field :idempotency_key, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :committed_at, updated_at: false)
  end
end
