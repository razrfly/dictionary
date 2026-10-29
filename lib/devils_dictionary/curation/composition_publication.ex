defmodule DevilsDictionary.Curation.CompositionPublication do
  @moduledoc """
  The authoritative publication receipt (R3, R4). It records the pointer
  moving from one version to another, or to none, in the same transaction,
  with the review that authorized it and the fingerprint it published.
  Append-only.

  `authority_kind` names what authorized it. It is
  `:operator` for an owner action, or `:single_editor` for an accepted model
  choice under the explicit enabled single-editor policy, with no review.
  For an operator publication the version's latest review,
  an acceptance. The panel-decision authority
  (`docs/curation/persistence-slice-1.md`, "Publication authority") needs
  decision records that do not exist yet, and the database refuses it.
  """
  use Ecto.Schema

  schema "editorial_composition_publications" do
    field :composition_id, :id
    field :action, Ecto.Enum, values: [:publish, :withdraw]
    field :authority_kind, Ecto.Enum, values: [:operator, :single_editor]
    field :previous_version_id, :id
    field :published_version_id, :id
    field :authorizing_review_id, :id
    field :actor_id, :id
    field :reason, :string
    field :eligibility_fingerprint, :string
    field :idempotency_key, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :committed_at, updated_at: false)
  end
end
