defmodule DevilsDictionary.Encyclopedia.ConceptRelation do
  @moduledoc """
  Encyclopedic edges between things. In MVP-0: the Wikidata taxonomy
  (P171 / P279 / P31). Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types [:parent_taxon, :subclass_of, :instance_of, :part_of, :related]

  schema "concept_relations" do
    belongs_to :source, DevilsDictionary.Sources.Source
    belongs_to :from_concept, DevilsDictionary.Encyclopedia.Concept
    belongs_to :to_concept, DevilsDictionary.Encyclopedia.Concept

    field :type, Ecto.Enum, values: @types
    field :property, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:source_id, :from_concept_id, :to_concept_id, :type, :property])
    |> validate_required([:source_id, :from_concept_id, :to_concept_id, :type])
  end
end
