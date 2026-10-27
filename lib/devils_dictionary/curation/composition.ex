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

  The owner's D8 marks (#264 R15): `mode` is `:open` (the default) or
  `:mine` (proposals are shown and never taken for the owner), with who set
  it and when; `kept_items` names items of the published version, each by
  its exact reference, that every proposal carries
  (`Compositions.keep/4`). Only a human reviewer sets either.
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
    field :mode, Ecto.Enum, values: [:open, :mine], default: :open
    field :mode_set_by_actor_id, :id
    field :mode_set_at, :utc_datetime_usec
    field :kept_items, DevilsDictionary.Types.JsonValue, default: []

    timestamps(type: :utc_datetime_usec)
  end
end
