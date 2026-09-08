defmodule DevilsDictionary.Registry.ExternalIdentifier do
  @moduledoc """
  An identifier some other system uses for this object: a Wikidata QID, a
  Wikipedia page id, a WordNet ILI, a Gutenberg number.

  Namespaced, because `Q191050` means nothing without saying whose scheme it is,
  and **statused**, because a candidate match and an established one are
  different claims. Only `verified` rows are unique per `(namespace,
  external_id)`; candidates coexist freely, which is what lets a linker record
  three plausible QIDs without any of them silently becoming the answer.

  This is where `concepts.qid NOT NULL` went. Identity is the internal
  `object_id`; adding an external id later changes nothing about it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry.Object

  @statuses [:verified, :candidate, :rejected]

  schema "external_identifiers" do
    belongs_to :object, Object
    field :namespace, :string
    field :external_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :verified
    field :metadata, :map, default: %{}
    belongs_to :source_record_revision, SourceRecordRevision

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(identifier, attrs) do
    identifier
    |> cast(attrs, [
      :object_id,
      :namespace,
      :external_id,
      :status,
      :metadata,
      :source_record_revision_id
    ])
    |> validate_required([:object_id, :namespace, :external_id])
    |> unique_constraint([:namespace, :external_id],
      name: :external_identifiers_verified_index,
      message: "is already verified for another object"
    )
    |> check_constraint(:status, name: :external_identifiers_status)
  end
end
