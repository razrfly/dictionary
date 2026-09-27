defmodule DevilsDictionary.Curation.ProfileVersion do
  @moduledoc """
  One immutable dossier of a curator profile (#196 `curator_profile_versions`).

  `source_refs` and `deceased_evidence_refs` are references, not text. They
  record what a reviewer checked; no biography is written here.
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  schema "curator_profile_versions" do
    field :profile_id, :id
    field :version, :integer
    field :manifest_hash, :string
    field :dossier, :map, default: %{}
    field :source_refs, JsonValue, default: []
    field :deceased_evidence_refs, JsonValue, default: []
    field :template_version, :string
    field :created_by_actor_id, :id
    field :change_reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
