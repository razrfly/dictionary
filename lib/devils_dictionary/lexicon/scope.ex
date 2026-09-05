defmodule DevilsDictionary.Lexicon.Scope do
  @moduledoc """
  A scope is data. "animals" is one row; adding a scope is one task run, not a
  code change (scorecard E2).

  `rules` holds the frozen inputs each rule needs — WordNet roots, the
  Wiktionary category list, the Wikidata root — so building a scope needs no
  network. Spec: issue #69 §3 and §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "scopes" do
    field :slug, :string
    field :name, :string
    field :rules, :map, default: %{}
    field :stats, :map, default: %{}

    has_many :scope_lexemes, DevilsDictionary.Lexicon.ScopeLexeme

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [:slug, :name, :rules, :stats])
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
  end
end
