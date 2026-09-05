defmodule DevilsDictionary.Sources.Person do
  @moduledoc """
  Authors of layers. Bierce in MVP-0; Johnson and Webster later.
  Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "people" do
    field :name, :string
    field :slug, :string
    field :birth_date, :date
    field :death_date, :date
    field :bio, :string
    field :wikidata_id, :string

    belongs_to :source, DevilsDictionary.Sources.Source

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(person, attrs) do
    person
    |> cast(attrs, [:name, :slug, :birth_date, :death_date, :bio, :wikidata_id, :source_id])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
