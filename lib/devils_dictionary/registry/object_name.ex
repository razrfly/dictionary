defmodule DevilsDictionary.Registry.ObjectName do
  @moduledoc """
  A name an object is known by: a pseudonym, an alias, a translated label, a
  scientific name, the title a source printed.

  Names do not create identities. Two people can share one and one person can
  have many, so a name is evidence for a match and never a key — #73's
  "identical names do not prove identical people", made structural.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry.Object

  schema "object_names" do
    belongs_to :object, Object
    field :name, :string
    field :language_tag, :string
    field :name_kind, :string, default: "alias"
    belongs_to :source_record_revision, SourceRecordRevision

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(name, attrs) do
    name
    |> cast(attrs, [:object_id, :name, :language_tag, :name_kind, :source_record_revision_id])
    |> validate_required([:object_id, :name])
    |> unique_constraint([:object_id, :name, :name_kind, :language_tag],
      name: :object_names_unique_index
    )
  end
end
