defmodule DevilsDictionary.Lexicon.ScopeMember do
  @moduledoc """
  A word's membership of a scope, with the rules that put it there.

  `reasons` is an array because a lemma can match two rules — WordNet's hyponym
  closure *and* a Wiktionary category — and both are worth keeping: a scope with
  a member that cannot say why it is a member is not data-driven, it is a list.
  Re-pointed at `lexemes.object_id`; otherwise unchanged from MVP-0.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Registry.Lexeme

  @primary_key false
  schema "scope_lexeme_members" do
    belongs_to :scope, Scope, primary_key: true
    belongs_to :lexeme, Lexeme, primary_key: true, references: :object_id
    field :reasons, {:array, :string}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:scope_id, :lexeme_id, :reasons])
    |> validate_required([:scope_id, :lexeme_id])
  end
end
