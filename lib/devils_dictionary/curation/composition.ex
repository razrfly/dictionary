defmodule DevilsDictionary.Curation.Composition do
  @moduledoc """
  A configuration-scoped editorial composition (#196).

  Its identity is `(scope_kind, scope_signature, language_tag,
  curation_configuration_id)`. That is the configuration, never its version.
  Two configurations over one scope are two compositions, with independent
  histories, pointers and clocks (K1).

  `scope_signature` is the SHA-256 of its sorted memberships, never a spelling
  or a slug (K2). `current_published_version_id` moves only with a publication
  receipt (R3).
  """
  use Ecto.Schema

  schema "editorial_compositions" do
    field :curation_configuration_id, :id
    field :scope_kind, Ecto.Enum, values: [:lexical_page, :lexeme]
    field :language_tag, :string
    field :scope_signature, :string
    field :state, Ecto.Enum, values: [:active, :retired], default: :active
    field :current_published_version_id, :id
    field :lock_version, :integer, default: 1
    field :created_by_actor_id, :id

    timestamps(type: :utc_datetime_usec)
  end
end
