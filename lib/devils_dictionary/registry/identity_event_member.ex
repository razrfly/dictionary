defmodule DevilsDictionary.Registry.IdentityEventMember do
  @moduledoc """
  One identity's part in a merge, split or retirement — `input` or `output`.

  The object FK is `on_delete: :restrict`: the audit trail of a merge is
  worthless if one of the identities it names can vanish.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.{IdentityEvent, Object}

  @roles [:input, :output]

  @primary_key false
  schema "identity_event_members" do
    belongs_to :event, IdentityEvent, primary_key: true
    belongs_to :object, Object, primary_key: true
    field :role, Ecto.Enum, values: @roles, primary_key: true
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:event_id, :object_id, :role])
    |> validate_required([:event_id, :object_id, :role])
    |> check_constraint(:role, name: :identity_event_members_role)
  end
end
