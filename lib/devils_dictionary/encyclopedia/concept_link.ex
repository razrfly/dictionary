defmodule DevilsDictionary.Encyclopedia.ConceptLink do
  @moduledoc """
  The word ↔ thing bridge, and the template for every later edge (examples,
  attachments, votes): a typed link with a method, a confidence, a status and
  provenance.

  Conflicts are surfaced, never resolved silently. Spec: issue #69 §4 and the
  linking ladder in §5.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @methods [
    :wiktionary_qid,
    :wikidata_p5137,
    :wordnet_ili,
    :title_match,
    :disambiguation,
    :manual
  ]
  @statuses [:auto, :candidate, :confirmed, :rejected]

  schema "concept_links" do
    belongs_to :lexeme, DevilsDictionary.Lexicon.Lexeme
    belongs_to :sense, DevilsDictionary.Lexicon.Sense
    belongs_to :concept, DevilsDictionary.Encyclopedia.Concept
    belongs_to :source, DevilsDictionary.Sources.Source

    field :method, Ecto.Enum, values: @methods
    field :confidence, :float
    field :status, Ecto.Enum, values: @statuses, default: :auto
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :lexeme_id,
      :sense_id,
      :concept_id,
      :source_id,
      :method,
      :confidence,
      :status,
      :metadata
    ])
    |> validate_required([:lexeme_id, :concept_id, :method])
  end
end
