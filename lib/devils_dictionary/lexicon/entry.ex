defmodule DevilsDictionary.Lexicon.Entry do
  @moduledoc """
  A text a source published about a word or a thing.

  Prose sources land here: Bierce's full definitions, Wikipedia's summaries.
  Living sources store a summary plus a link; only public-domain dictionaries
  are imported in full (decision #11). Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @formats [:text, :markdown, :html]

  schema "entries" do
    belongs_to :source, DevilsDictionary.Sources.Source
    belongs_to :source_record, DevilsDictionary.Sources.SourceRecord
    belongs_to :lexeme, DevilsDictionary.Lexicon.Lexeme
    belongs_to :concept, DevilsDictionary.Encyclopedia.Concept
    belongs_to :author, DevilsDictionary.Sources.Person

    field :headword, :string
    field :pos, :string
    field :body, :string
    field :body_format, Ecto.Enum, values: @formats, default: :text
    field :url, :string
    field :thumbnail_url, :string
    field :year, :integer
    field :position, :integer, default: 0
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :source_id,
      :source_record_id,
      :lexeme_id,
      :concept_id,
      :author_id,
      :headword,
      :pos,
      :body,
      :body_format,
      :url,
      :thumbnail_url,
      :year,
      :position,
      :metadata
    ])
    |> validate_required([:source_id])
    |> check_constraint(:lexeme_id, name: :entries_lexeme_or_concept)
  end
end
