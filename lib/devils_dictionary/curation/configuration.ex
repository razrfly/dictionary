defmodule DevilsDictionary.Curation.Configuration do
  @moduledoc """
  A system-owned curation configuration identity (#201).

  The identity is stable. What it means at any moment is its current
  immutable version, and the pointer moves only with an activation receipt
  (C3). `role` separates the one global default from internal test
  configurations; there is no domain or personal ownership yet.

  `state` is `draft` until a reviewer activates a version, then `enabled` or
  `disabled`. The database checks both halves: a draft has no current
  version, and an enabled configuration always has one.
  """
  use Ecto.Schema

  @roles [:global_default, :internal_test]
  @states [:draft, :enabled, :disabled]

  schema "curation_configurations" do
    field :slug, :string
    field :name, :string
    field :ownership_kind, Ecto.Enum, values: [:system], default: :system
    field :role, Ecto.Enum, values: @roles
    field :state, Ecto.Enum, values: @states, default: :draft
    field :current_version_id, :id
    field :created_by_actor_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def roles, do: @roles
  def states, do: @states
end
