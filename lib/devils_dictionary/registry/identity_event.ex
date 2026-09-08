defmodule DevilsDictionary.Registry.IdentityEvent do
  @moduledoc """
  An audited retire, merge, split or restore.

  Merges and splits are the operations that can destroy meaning silently, so
  they leave a record: who did it, why, and — through `identity_event_members` —
  exactly which identities went in and which came out. A split has several
  outputs, which is why membership is its own table rather than a pair of
  columns.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.IdentityEventMember
  alias DevilsDictionary.Sources.Actor

  @operations [:retire, :merge, :split, :restore]

  schema "identity_events" do
    field :operation, Ecto.Enum, values: @operations
    belongs_to :actor, Actor
    field :reason, :string

    has_many :members, IdentityEventMember, foreign_key: :event_id

    timestamps(type: :utc_datetime_usec)
  end

  def operations, do: @operations

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:operation, :actor_id, :reason])
    |> validate_required([:operation])
    |> check_constraint(:operation, name: :identity_events_operation)
  end
end
