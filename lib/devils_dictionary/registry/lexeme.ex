defmodule DevilsDictionary.Registry.Lexeme do
  @moduledoc """
  A word: one row per language, lemma and part of speech.

  `lexical_key` is identity and it is **lossless** — `en/C++/noun` is not
  `en/c/noun`. The 7 September audit found 28,306 slug groups holding more than
  one distinct lowercased lemma, and searching for `C++` landed on `/define/c`
  headed `-c-`, because a slug generator's output was being treated as identity.
  So `slug` survives as a cosmetic, deliberately non-unique label: a word page
  is addressed by `object_id`, and `/define/:slug` resolves or disambiguates.

  Forms moved out to `lexeme_forms`, where each carries the source revision that
  attested it. `pronunciations`, `etymology` and `metadata` stay here; the
  multi-etymology question is a P2 policy decision, not a schema one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Registry.Object

  @primary_key false
  schema "lexemes" do
    belongs_to :object, Object, primary_key: true, define_field: false
    field :object_id, :id, primary_key: true

    field :language_tag, :string, default: "en"
    field :lemma, :string
    field :part_of_speech, :string, default: "unknown"
    field :lexical_key, :string
    field :slug, :string
    field :canonical_lexeme_id, :id
    field :etymology, :string
    field :etymology_source_id, :id
    field :origin_source_id, :id
    # `%{"items" => [%{"ipa" => ..., "tags" => [...]}]}`. See the migration.
    field :pronunciations, :map, default: %{}
    field :source_ids, {:array, :integer}, default: []
    field :metadata, :map, default: %{}
    field :enriched_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(object_id language_tag lemma part_of_speech slug canonical_lexeme_id
               etymology etymology_source_id origin_source_id pronunciations
               source_ids metadata enriched_at)a

  def changeset(lexeme, attrs) do
    lexeme
    |> cast(attrs, @castable)
    |> validate_required([:object_id, :language_tag, :lemma, :part_of_speech])
    |> put_lexical_key()
    |> put_slug()
    |> unique_constraint(:lexical_key)
  end

  @doc """
  The identity string for a word.

  Case- and punctuation-preserving, and computed rather than supplied so no
  writer can disagree with it.
  """
  def lexical_key(language_tag, lemma, part_of_speech),
    do: "#{language_tag}/#{lemma}/#{part_of_speech}"

  @doc """
  The cosmetic slug. Lossy on purpose, and never identity.

  `Slug.slugify/1` returns nil for a lemma made entirely of punctuation (`++`),
  so the downcased lemma is the fallback — a word with no slug would have no
  readable URL at all.
  """
  def slug(lemma), do: Slug.slugify(lemma) || String.downcase(lemma)

  defp put_lexical_key(changeset) do
    lang = get_field(changeset, :language_tag)
    lemma = get_field(changeset, :lemma)
    pos = get_field(changeset, :part_of_speech)

    if lang && lemma && pos do
      put_change(changeset, :lexical_key, lexical_key(lang, lemma, pos))
    else
      changeset
    end
  end

  defp put_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :lemma)} do
      {nil, lemma} when is_binary(lemma) -> put_change(changeset, :slug, slug(lemma))
      _ -> changeset
    end
  end
end
