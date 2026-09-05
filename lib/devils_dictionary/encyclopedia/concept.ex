defmodule DevilsDictionary.Encyclopedia.Concept do
  @moduledoc """
  A thing, keyed by Wikidata QID.

  Words and things are different tables (backbone rule 1); they meet only
  through `concept_links`. Populated from S2. Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:taxon, :thing, :other]

  schema "concepts" do
    field :qid, :string
    field :label, :string
    field :description, :string
    field :kind, Ecto.Enum, values: @kinds, default: :thing
    field :wikipedia_title, :string
    field :wikipedia_pageid, :integer
    field :image_url, :string
    field :image_attribution, :string
    field :wordnet_ili, :string
    field :taxon, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :taxon_concept, __MODULE__

    has_many :entries, DevilsDictionary.Lexicon.Entry

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(concept, attrs) do
    concept
    |> cast(attrs, [
      :qid,
      :label,
      :description,
      :kind,
      :wikipedia_title,
      :wikipedia_pageid,
      :image_url,
      :image_attribution,
      :wordnet_ili,
      :taxon,
      :taxon_concept_id,
      :metadata
    ])
    |> validate_required([:qid])
    |> unique_constraint(:qid)
  end
end
