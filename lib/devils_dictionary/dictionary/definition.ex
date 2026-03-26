defmodule DevilsDictionary.Dictionary.Definition do
  @moduledoc """
  A definition for a topic from a specific source and tier.

  Definitions are organized into three tiers that represent the
  "hierarchy of knowledge":

  ## Tiers

  - **Aristocracy** (👑): The dead intellectuals tier. Witty, acerbic
    definitions from Ambrose Bierce's Devil's Dictionary, Oscar Wilde,
    Mark Twain, and other deceased luminaries. The pinnacle of the hierarchy.

  - **Middle Class** (📚): Institutional knowledge. Merriam-Webster,
    Oxford, encyclopedias. Clean, professional, aspirational definitions
    that represent the "proper" way to define things.

  - **Plebs** (📱): The crowdsourced chaos. Urban Dictionary, Reddit,
    Twitter/X. Raw, unfiltered, often profane definitions from the masses.
    Democracy in action.

  ## Display Order

  Definitions are ordered by tier (aristocracy first) and then by position
  within each tier. This visual hierarchy communicates the value judgment
  the platform makes about different knowledge sources.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DevilsDictionary.Dictionary.{Topic, Person}

  @tier_values [:aristocracy, :middle, :plebs]

  schema "definitions" do
    belongs_to :topic, Topic
    belongs_to :author, Person

    field :content, :string
    field :source_name, :string
    field :source_url, :string
    field :source_year, :integer
    field :tier, Ecto.Enum, values: @tier_values, default: :middle
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [:topic_id, :author_id, :content, :source_name, :source_url, :source_year, :tier, :position])
    |> validate_required([:topic_id, :content, :tier])
    |> validate_length(:content, min: 1)
    |> validate_inclusion(:tier, @tier_values)
    |> validate_number(:source_year, greater_than: 0, less_than_or_equal_to: Date.utc_today().year + 1)
    |> foreign_key_constraint(:topic_id)
    |> foreign_key_constraint(:author_id)
  end

  @doc """
  Returns the tier emoji for display.
  """
  def tier_emoji(:aristocracy), do: "👑"
  def tier_emoji(:middle), do: "📚"
  def tier_emoji(:plebs), do: "📱"
  def tier_emoji(_), do: "❓"

  @doc """
  Returns the tier display name.
  """
  def tier_name(:aristocracy), do: "Aristocracy of the Dead"
  def tier_name(:middle), do: "Middle Class"
  def tier_name(:plebs), do: "The Plebs"
  def tier_name(_), do: "Unknown"
end
