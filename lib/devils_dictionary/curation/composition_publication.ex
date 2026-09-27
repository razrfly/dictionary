defmodule DevilsDictionary.Curation.CompositionPublication do
  @moduledoc """
  The authoritative publication receipt (R3, R4). It records the pointer
  moving from one version to another, or to none, in the same transaction,
  with the review that authorized it and the fingerprint it published.
  Append-only.
  """
  use Ecto.Schema

  schema "editorial_composition_publications" do
    field :composition_id, :id
    field :action, Ecto.Enum, values: [:publish, :withdraw]
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
