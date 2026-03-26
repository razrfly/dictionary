defmodule DevilsDictionary.Dictionary.Topic do
  @moduledoc """
  A topic (word/term) in the dictionary.

  Topics can have multiple definitions from different tiers:
  - Aristocracy: Dead intellectuals (Bierce, Wilde, etc.)
  - Middle Class: Institutional sources (Merriam-Webster, etc.)
  - Plebs: Crowdsourced (Urban Dictionary, user submissions)

  Topics support display types for handling disambiguation and redirects:
  - standard: Normal topic page
  - redirect: Redirects to another topic (e.g., "color" → "colour")
  - disambiguation: Shows links to multiple related topics
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DevilsDictionary.Dictionary.{Definition, TopicRelationship}

  @type_values [:concept, :thing, :place, :event, :action, :person, :organization, :other]
  @display_type_values [:standard, :redirect, :disambiguation]

  schema "topics" do
    field :title, :string
    field :slug, :string
    field :type, Ecto.Enum, values: @type_values, default: :concept
    field :pronunciation, :string
    field :part_of_speech, :string
    field :definition_count, :integer, default: 0, read_after_writes: true

    field :display_type, Ecto.Enum, values: @display_type_values, default: :standard
    belongs_to :redirect_to, __MODULE__

    has_many :definitions, Definition
    has_many :relationships, TopicRelationship, foreign_key: :topic_id
    has_many :reverse_relationships, TopicRelationship, foreign_key: :related_topic_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [:title, :slug, :type, :pronunciation, :part_of_speech, :display_type, :redirect_to_id])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:type, @type_values)
    |> validate_inclusion(:display_type, @display_type_values)
    |> generate_slug()
    |> unique_constraint(:slug)
    |> validate_redirect()
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :title) do
      nil ->
        changeset

      title ->
        slug = Slug.slugify(title)
        put_change(changeset, :slug, slug)
    end
  end

  defp validate_redirect(changeset) do
    case get_field(changeset, :display_type) do
      :redirect ->
        changeset
        |> validate_required([:redirect_to_id])

      _ ->
        changeset
        |> put_change(:redirect_to_id, nil)
    end
  end
end
