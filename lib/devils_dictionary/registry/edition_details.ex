defmodule DevilsDictionary.Registry.EditionDetails do
  @moduledoc """
  A particular published manifestation of a work.

  `work_id` references `work_details`, not `entities`, so an edition *of a
  person* is not expressible. The FK is `on_delete: :restrict` because deleting
  a work out from under its editions is exactly the cascade #74 forbids — retire
  the identity instead.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.{Entity, WorkDetails}

  @primary_key false
  schema "edition_details" do
    belongs_to :entity, Entity, primary_key: true, references: :object_id, define_field: false
    field :entity_id, :id, primary_key: true
    belongs_to :work, WorkDetails, references: :entity_id
    field :edition_label, :string
    field :publication_year, :integer
    field :language_tag, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(details, attrs) do
    details
    |> cast(attrs, [:entity_id, :work_id, :edition_label, :publication_year, :language_tag])
    |> validate_required([:entity_id])
    |> foreign_key_constraint(:work_id)
  end
end
