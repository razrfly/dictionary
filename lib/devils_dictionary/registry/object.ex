defmodule DevilsDictionary.Registry.Object do
  @moduledoc """
  The addressable identity every relationship points at.

  An `objects` row is identity and lifecycle, nothing else: the domain fields
  live in exactly one typed subtype table, joined on `object_id`. That split is
  what lets an assertion hold a real foreign key to "whatever kind of thing this
  endpoint is" — a `(type, id)` pair could not.

  Three database rules hold it together, and none of them is expressible as a
  single constraint (`docs/adr/0001-encyclopedia-model.md`):

    * **at most one, of the right kind** — each subtype's primary key is
      `object_id`, and a generated `kind` column carries a composite foreign key
      to `objects (id, kind)`
    * **at least one, at commit** — a deferred constraint trigger, because the
      object row must exist before its subtype can reference it
    * **kind is immutable** — a `BEFORE UPDATE` trigger

  `lifecycle_state` is how an identity leaves: **retired**, never deleted. The
  Gate 0 spike found the reason the hard way — deleting a subtype row left an
  object typed `entity` with no entity row while an `authored_by` assertion
  still pointed at it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:lexeme, :sense, :entity, :content]
  @states [:active, :retired, :merged, :split]

  schema "objects" do
    field :kind, Ecto.Enum, values: @kinds
    field :lifecycle_state, Ecto.Enum, values: @states, default: :active

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The four registry kinds."
  def kinds, do: @kinds

  @doc "The lifecycle states an identity can be in."
  def states, do: @states

  def changeset(object, attrs) do
    object
    |> cast(attrs, [:kind, :lifecycle_state])
    |> validate_required([:kind])
    |> check_constraint(:kind, name: :objects_kind)
    |> check_constraint(:lifecycle_state, name: :objects_lifecycle_state)
  end

  @doc """
  Retiring is the only way an identity goes away.

  Deliberately not a `delete`: everything that referenced it must keep
  resolving, and its history must stay inspectable.
  """
  def retire_changeset(object), do: change(object, lifecycle_state: :retired)
end
