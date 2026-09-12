defmodule DevilsDictionary.Discovery.Mapping do
  @moduledoc "A versioned, immutable recipe for retrieving culture for one registry target."

  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Sources.{Actor, Source}

  schema "discovery_mappings" do
    field :mapping_key, :string
    field :version, :integer
    belongs_to :target_object, Object
    belongs_to :source, Source
    field :operation, :string
    field :parameters, :map, default: %{}
    belongs_to :configured_by_actor, Actor
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @immutable ~w(mapping_key version target_object_id source_id operation parameters
                configured_by_actor_id)a

  def create_changeset(mapping, attrs) do
    mapping
    |> cast(attrs, @immutable ++ [:enabled])
    |> validate_required(@immutable ++ [:enabled])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:mapping_key, :version])
    |> unique_constraint(:mapping_key,
      name: :discovery_mappings_one_enabled_version_index
    )
    |> foreign_key_constraint(:target_object_id)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:configured_by_actor_id)
  end

  def activation_changeset(mapping, enabled) when is_boolean(enabled) do
    change(mapping, enabled: enabled)
  end
end
