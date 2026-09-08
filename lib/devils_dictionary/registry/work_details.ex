defmodule DevilsDictionary.Registry.WorkDetails do
  @moduledoc """
  A creative work: *The Devil's Dictionary*, a poem, an artwork, a recording.

  Distinct from the editions that manifest it, so one hosted transcription does
  not become a second *Devil's Dictionary*. That separation is what lets a
  definition say `published_in` a particular edition while `authored_by` points
  at the person and the work stands on its own page.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Entity

  @primary_key false
  schema "work_details" do
    belongs_to :entity, Entity, primary_key: true, references: :object_id, define_field: false
    field :entity_id, :id, primary_key: true
    field :work_kind, :string
    field :original_language, :string
    field :first_published_year, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(details, attrs) do
    details
    |> cast(attrs, [:entity_id, :work_kind, :original_language, :first_published_year])
    |> validate_required([:entity_id])
  end
end
