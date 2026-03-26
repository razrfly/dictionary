defmodule DevilsDictionary.Dictionary.Person do
  @moduledoc """
  A person (author, creator, notable figure) in the dictionary.

  The tier assignment follows the "dead intellectuals" hierarchy:
  - Aristocracy: Dead authors/intellectuals (Bierce, Wilde, Twain)
  - Middle Class: Living institutional authors
  - Plebs: Anonymous or social media personalities

  A person with a death_date is automatically considered Aristocracy tier
  (the dead have proven their worth through time).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DevilsDictionary.Dictionary.Definition

  @tier_values [:aristocracy, :middle, :plebs]

  schema "people" do
    field :name, :string
    field :slug, :string
    field :birth_date, :date
    field :death_date, :date
    field :bio, :string
    field :photo_url, :string
    field :tier, Ecto.Enum, values: @tier_values, default: :middle

    # External API IDs for enrichment
    field :google_knowledge_id, :string
    field :tmdb_id, :integer
    field :open_library_id, :string
    field :wikidata_id, :string

    has_many :definitions, Definition, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(person, attrs) do
    person
    |> cast(attrs, [
      :name,
      :slug,
      :birth_date,
      :death_date,
      :bio,
      :photo_url,
      :tier,
      :google_knowledge_id,
      :tmdb_id,
      :open_library_id,
      :wikidata_id
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> generate_slug()
    |> unique_constraint(:slug)
    |> auto_assign_tier()
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug = Slug.slugify(name)
        put_change(changeset, :slug, slug)
    end
  end

  # Automatically assign aristocracy tier if person is dead
  defp auto_assign_tier(changeset) do
    case get_field(changeset, :death_date) do
      nil -> changeset
      _death_date -> put_change(changeset, :tier, :aristocracy)
    end
  end

  @doc """
  Returns true if this person is in the Aristocracy tier (dead intellectuals).
  """
  def aristocracy?(%__MODULE__{death_date: death_date}) when not is_nil(death_date), do: true
  def aristocracy?(%__MODULE__{tier: :aristocracy}), do: true
  def aristocracy?(_), do: false
end
