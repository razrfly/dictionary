defmodule DevilsDictionary.Curation.ShelfCitation do
  @moduledoc "Immutable local identity of one exact discovery observation (#270 L5)."
  use Ecto.Schema

  schema "curation_shelf_citations" do
    field :source_id, :id
    field :external_ref_sha256, :string
    field :cited_source_record_id, :id
    field :cited_revision_id, :id
    field :cited_checksum, :string
    field :cited_object_id, :id
    field :source_record_id, :id
    field :source_record_revision_id, :id
    field :discovery_result_id, :id
    field :discovery_run_id, :id
    field :mapping_id, :id
    field :target_object_id, :id
    field :adapter_version, :string
    field :observed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :expiry_origin, :string
    field :retention_seconds, :integer
    field :policy_sha256, :string
    field :fallback_policy_sha256, :string
    field :observation_policy_state, :string
    field :field_policy, :string
    field :shelf_kind, :string
    field :content_date_meaning, :string
    field :content_date_precision, :string
    field :match_kind, :string
    field :match_evidence, :string
    field :match_relation, :string
    field :match_level, :string
    field :link_sha256, :string
    field :created_by_actor_id, :id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
