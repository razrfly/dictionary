defmodule DevilsDictionary.Lexicon.Lexeme do
  @moduledoc """
  A word as a lexical unit: `(lang, lemma, pos)`.

  The full English index lives here — every Wiktionary headword is a row from
  day one, bare (`enriched_at` nil) until a scope pulls it in. Any source may
  create one. `lemma` is case-sensitive so *Turkey* and *turkey* never merge;
  lookups go through `lower(lemma)`. Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "lexemes" do
    field :lang, :string, default: "en"
    field :lemma, :string
    field :pos, :string, default: "unknown"
    field :slug, :string
    field :forms, {:array, :map}, default: []
    field :pronunciations, {:array, :map}, default: []
    field :etymology, :string
    field :etymology_source_id, :integer
    field :source_ids, {:array, :integer}, default: []
    field :metadata, :map, default: %{}
    field :enriched_at, :utc_datetime_usec

    belongs_to :canonical_lexeme, __MODULE__
    belongs_to :origin_source, DevilsDictionary.Sources.Source

    has_many :senses, DevilsDictionary.Lexicon.Sense
    has_many :entries, DevilsDictionary.Lexicon.Entry

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(lexeme, attrs) do
    lexeme
    |> cast(attrs, [
      :lang,
      :lemma,
      :pos,
      :slug,
      :forms,
      :pronunciations,
      :etymology,
      :etymology_source_id,
      :canonical_lexeme_id,
      :origin_source_id,
      :source_ids,
      :metadata,
      :enriched_at
    ])
    |> validate_required([:lang, :lemma, :pos])
    |> put_slug()
    |> unique_constraint([:lang, :lemma, :pos])
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil -> put_change(changeset, :slug, slug(get_field(changeset, :lemma)))
      _ -> changeset
    end
  end

  @doc """
  The page key. Not unique: `/define/:slug` shows every pos and every casing.
  """
  def slug(nil), do: nil
  def slug(lemma), do: Slug.slugify(lemma) || String.downcase(lemma)
end
