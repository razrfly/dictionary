defmodule DevilsDictionary.Curation.ScopeChange do
  @moduledoc """
  The receipt for a composition's scope being set or changed (K2, K3). It
  records the member ids, the signature before and after, who, and why.
  Append-only.
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  schema "editorial_composition_scope_changes" do
    field :composition_id, :id
    field :previous_signature, :string
    field :scope_signature, :string
    field :members, JsonValue
    field :actor_id, :id
    field :reason, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :changed_at, updated_at: false)
  end
end
