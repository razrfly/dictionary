defmodule DevilsDictionary.Lexicon.ScopeLexeme do
  @moduledoc """
  Membership of a lexeme in a scope, with the reason each rule matched.

  Composite primary key `(scope_id, lexeme_id)`. A lexeme in scope for more
  than one reason keeps them all — that is what `mix dd.scope.build` reports.
  Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "scope_lexemes" do
    belongs_to :scope, DevilsDictionary.Lexicon.Scope, primary_key: true
    belongs_to :lexeme, DevilsDictionary.Lexicon.Lexeme, primary_key: true

    field :reasons, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(scope_lexeme, attrs) do
    scope_lexeme
    |> cast(attrs, [:scope_id, :lexeme_id, :reasons])
    |> validate_required([:scope_id, :lexeme_id])
  end
end
