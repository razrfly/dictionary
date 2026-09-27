defmodule DevilsDictionary.Curation.CompositionMembership do
  @moduledoc "One registry object in a composition's scope. In this slice, only lexemes."
  use Ecto.Schema

  schema "editorial_composition_memberships" do
    field :composition_id, :id
    field :object_id, :id
    field :role, Ecto.Enum, values: [:lexeme], default: :lexeme

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
