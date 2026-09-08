defmodule DevilsDictionary.Claims.PredicateEndpointRule do
  @moduledoc """
  One combination of endpoint kinds a predicate is allowed to connect.

  Enumerated rows, not arbitrary strings: `defines` connects a definition to a
  word or a source meaning and to nothing else, and the database is what refuses
  the rest. `assertion_revisions` carries the four endpoint kinds as columns
  filled by a `BEFORE` trigger and holds a composite foreign key into this
  table, so the rule survives `insert_all`, `COPY` and the linker's raw SQL —
  not only changesets.

  Subkinds are the sentinel `"-"` rather than `nil` when a kind has none. That
  is load-bearing: a foreign key with a NULL column is not enforced under
  `MATCH SIMPLE`, so nulls here would silently disable the whole check for every
  lexeme and sense endpoint.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.Predicate

  @none "-"

  @primary_key false
  schema "predicate_endpoint_rules" do
    belongs_to :predicate, Predicate, primary_key: true
    field :subject_kind, :string, primary_key: true
    field :subject_subkind, :string, primary_key: true, default: @none
    field :object_kind, :string, primary_key: true
    field :object_subkind, :string, primary_key: true, default: @none
  end

  @doc "The sentinel for \"this kind has no subkind\". Never nil — see the moduledoc."
  def none, do: @none

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :predicate_id,
      :subject_kind,
      :subject_subkind,
      :object_kind,
      :object_subkind
    ])
    |> validate_required([:predicate_id, :subject_kind, :object_kind])
    |> normalize(:subject_subkind)
    |> normalize(:object_subkind)
  end

  defp normalize(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, @none)
      _ -> changeset
    end
  end
end
