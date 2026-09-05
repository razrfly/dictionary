defmodule DevilsDictionary.Lexicon.LexicalRelation do
  @moduledoc """
  Typed edges between words, with provenance, tolerant of targets we have not
  seen yet.

  `to_lemma` is always set, exactly as the source wrote it, and is kept
  forever; `to_lexeme_id` is filled by `mix dd.resolve` (WordNet resolves its
  own inside the absorb, since it is a closed graph). Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @types [
    :hypernym,
    :hyponym,
    :meronym,
    :holonym,
    :synonym,
    :antonym,
    :derived,
    :related,
    :coordinate,
    :form_of,
    :alt_of,
    :see_also,
    :other
  ]

  schema "lexical_relations" do
    belongs_to :source, DevilsDictionary.Sources.Source
    belongs_to :from_lexeme, DevilsDictionary.Lexicon.Lexeme
    belongs_to :from_sense, DevilsDictionary.Lexicon.Sense
    belongs_to :to_lexeme, DevilsDictionary.Lexicon.Lexeme
    belongs_to :to_sense, DevilsDictionary.Lexicon.Sense

    field :to_lemma, :string
    field :to_pos, :string
    field :to_group_key, :string
    field :type, Ecto.Enum, values: @types
    field :subtype, :string
    field :weight, :float, default: 1.0
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def types, do: @types

  @doc false
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [
      :source_id,
      :from_lexeme_id,
      :from_sense_id,
      :to_lemma,
      :to_pos,
      :to_lexeme_id,
      :to_sense_id,
      :to_group_key,
      :type,
      :subtype,
      :weight,
      :metadata
    ])
    |> validate_required([:source_id, :from_lexeme_id, :to_lemma, :type])
  end
end
