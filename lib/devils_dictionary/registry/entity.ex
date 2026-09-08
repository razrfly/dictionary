defmodule DevilsDictionary.Registry.Entity do
  @moduledoc """
  A thing in the world: a person, an organisation, a work, an edition, an event,
  an abstract practice, a taxon, a local artwork.

  Two things this replaces, and why both mattered.

  `people` held authors and `concepts` held encyclopedia subjects, with no
  foreign key between them — so Ambrose Bierce was two rows, and "his
  definitions" and "his biography" could not be shown as one person's. Here they
  are one `object_id`, and the page sections are just different predicates.

  `concepts.qid` was `NOT NULL`, so nothing could exist before Wikidata knew
  about it — no local artwork, no event, no concept a curator introduces.
  External identifiers now live in `external_identifiers`, keyed by namespace,
  and **adding one later leaves the identity and every attachment unchanged**.

  `entity_kind` is immutable in practice: the subtype tables carry a generated
  column with a composite foreign key to `(object_id, entity_kind)`, so changing
  it under a `person_details` row is refused by the database.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object

  @kinds ~w(person organization concept event work edition place artifact taxon other)a

  @primary_key false
  schema "entities" do
    belongs_to :object, Object, primary_key: true, define_field: false
    field :object_id, :id, primary_key: true

    field :entity_kind, Ecto.Enum, values: @kinds
    field :preferred_label, :string
    field :description, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [:object_id, :entity_kind, :preferred_label, :description, :metadata])
    |> validate_required([:object_id, :entity_kind])
    |> check_constraint(:entity_kind, name: :entities_entity_kind)
  end
end
