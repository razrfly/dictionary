defmodule DevilsDictionary.Lexicon.Sense do
  @moduledoc """
  One meaning as asserted by ONE source. Senses are never aligned across
  sources (decision #4); they meet only through `concepts`.

  `group_key` is "same meaning inside one source": the WordNet synset id, nil
  for Wiktionary. Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "senses" do
    belongs_to :lexeme, DevilsDictionary.Lexicon.Lexeme
    belongs_to :source, DevilsDictionary.Sources.Source
    belongs_to :source_record, DevilsDictionary.Sources.SourceRecord

    field :external_id, :string
    field :group_key, :string
    field :gloss, :string
    field :url, :string
    field :position, :integer, default: 0
    field :tags, {:array, :string}, default: []
    field :topics, {:array, :string}, default: []
    field :examples, {:array, :map}, default: []
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(sense, attrs) do
    sense
    |> cast(attrs, [
      :lexeme_id,
      :source_id,
      :source_record_id,
      :external_id,
      :group_key,
      :gloss,
      :url,
      :position,
      :tags,
      :topics,
      :examples,
      :metadata
    ])
    |> validate_required([:lexeme_id, :source_id, :external_id])
    |> unique_constraint([:source_id, :external_id])
  end
end
