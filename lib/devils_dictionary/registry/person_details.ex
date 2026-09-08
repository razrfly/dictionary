defmodule DevilsDictionary.Registry.PersonDetails do
  @moduledoc """
  The person-shaped facts about an entity whose `entity_kind` is `person`.

  A typed extension, not a competing identity: there is no separate population
  of "authors". Bierce authoring a definition, Bierce being the subject of a
  biography and Bierce being named in a cultural claim are the same `entity_id`.

  The composite foreign key on `(entity_id, entity_kind)` means this row cannot
  attach to a concept or a work — the database refuses it, not a changeset.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Entity

  @primary_key false
  schema "person_details" do
    belongs_to :entity, Entity, primary_key: true, references: :object_id, define_field: false
    field :entity_id, :id, primary_key: true
    field :birth_date, :date
    field :death_date, :date

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(details, attrs) do
    details
    |> cast(attrs, [:entity_id, :birth_date, :death_date])
    |> validate_required([:entity_id])
    |> validate_dates()
  end

  defp validate_dates(changeset) do
    born = get_field(changeset, :birth_date)
    died = get_field(changeset, :death_date)

    if born && died && Date.compare(born, died) == :gt do
      add_error(changeset, :death_date, "is before the birth date")
    else
      changeset
    end
  end
end
