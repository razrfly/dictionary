defmodule DevilsDictionary.Sources.Source do
  @moduledoc """
  One row per provider, human channel or bot.

  Tier, kind, access and license live here and nowhere else: content rows
  inherit them through `source_id`. Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @tiers [:aristocracy, :middle, :plebs]
  @kinds [
    :dictionary,
    :encyclopedia,
    :lexical_db,
    :knowledge_graph,
    :media_provider,
    :crowd,
    :bot,
    :corpus
  ]
  @accesses [:dump, :api, :static, :user]

  schema "sources" do
    field :slug, :string
    field :name, :string
    field :tier, Ecto.Enum, values: @tiers
    field :kind, Ecto.Enum, values: @kinds
    field :access, Ecto.Enum, values: @accesses
    field :era_year, :integer
    field :license, :string
    field :license_url, :string
    field :homepage, :string
    field :url_template, :string
    field :attribution, :string
    field :active, :boolean, default: true
    field :config, :map, default: %{}

    has_many :source_records, DevilsDictionary.Sources.SourceRecord

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :slug,
      :name,
      :tier,
      :kind,
      :access,
      :era_year,
      :license,
      :license_url,
      :homepage,
      :url_template,
      :attribution,
      :active,
      :config
    ])
    |> validate_required([:slug, :name, :tier, :kind, :access])
    |> unique_constraint(:slug)
  end
end
