defmodule DevilsDictionary.Dictionary.TopicRelationship do
  @moduledoc """
  Semantic relationships between topics.

  Relationship types support word forms, synonyms, and various
  semantic connections that allow for rich navigation between topics.

  ## Relationship Types

  ### MVP Relationships
  - `:word_form` - Different forms of the same word (aristocracy ↔ aristocratic)
  - `:synonym` - Words with similar meanings (truth ↔ verity)
  - `:related` - General topical relationship (truth → honesty)
  - `:see_also` - Editorial cross-reference

  ### Future Relationships
  - `:antonym` - Opposite meanings (truth ↔ lie)
  - `:broader` - Hierarchical broader term (aristocracy → government)
  - `:narrower` - Hierarchical narrower term (government → aristocracy)
  - `:disambiguates` - Links from disambiguation page to specific topics

  ## Bidirectionality

  By default, relationships are bidirectional (if A relates to B, B relates to A).
  Some relationships like `:broader`/`:narrower` are unidirectional by nature.

  ## Weight

  The weight field (0.0 to 1.0) can be used to rank relationship importance
  for display ordering or search relevance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DevilsDictionary.Dictionary.Topic

  @relationship_types [
    :word_form,
    :synonym,
    :related,
    :see_also,
    :antonym,
    :broader,
    :narrower,
    :disambiguates
  ]

  # Relationships that are inherently unidirectional
  @unidirectional_types [:broader, :narrower, :disambiguates]

  schema "topic_relationships" do
    belongs_to :topic, Topic
    belongs_to :related_topic, Topic

    field :relationship_type, Ecto.Enum, values: @relationship_types
    field :bidirectional, :boolean, default: true
    field :weight, :float, default: 1.0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, [:topic_id, :related_topic_id, :relationship_type, :bidirectional, :weight])
    |> validate_required([:topic_id, :related_topic_id, :relationship_type])
    |> validate_inclusion(:relationship_type, @relationship_types)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:topic_id)
    |> foreign_key_constraint(:related_topic_id)
    |> unique_constraint([:topic_id, :related_topic_id, :relationship_type])
    |> check_constraint(:no_self_reference, name: :no_self_reference)
    |> auto_set_bidirectional()
  end

  # Automatically set bidirectional=false for inherently unidirectional relationships
  defp auto_set_bidirectional(changeset) do
    case get_field(changeset, :relationship_type) do
      type when type in @unidirectional_types ->
        put_change(changeset, :bidirectional, false)

      _ ->
        changeset
    end
  end

  @doc """
  Returns the inverse relationship type for bidirectional handling.

  For example, if topic A has `:broader` relationship to B,
  then B has `:narrower` relationship to A.
  """
  def inverse_type(:broader), do: :narrower
  def inverse_type(:narrower), do: :broader
  def inverse_type(type), do: type

  @doc """
  Returns a human-readable label for the relationship type.
  """
  def type_label(:word_form), do: "Word Form"
  def type_label(:synonym), do: "Synonym"
  def type_label(:related), do: "Related"
  def type_label(:see_also), do: "See Also"
  def type_label(:antonym), do: "Antonym"
  def type_label(:broader), do: "Broader Term"
  def type_label(:narrower), do: "Narrower Term"
  def type_label(:disambiguates), do: "Disambiguation"
  def type_label(_), do: "Unknown"
end
