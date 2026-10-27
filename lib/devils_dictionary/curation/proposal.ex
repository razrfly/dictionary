defmodule DevilsDictionary.Curation.Proposal do
  @moduledoc """
  A model version's lifecycle (#264 R9, R10): the version itself stays
  immutable, and this row says what became of it.

  **Identity**, fixed when it is written: the composition and its model
  version, the configuration version, the refresh row and generation that
  ran it, the attempt's request key and packet hash, the model config, the
  generic editor's profile and version, the merged arrangement's hash, the
  published version the generation was admitted against
  (`published_parent_version_id`, `nil` when nothing was published; #253
  §6a's "`parent_version_id` N", OD-1), whether the pointer had moved by the
  time it arrived (`superseded_on_arrival`, a fact about arrival, not a
  state), the digest of the kept marks it was merged with, the kept items
  not carried (`carried`, each with its reason) and the model's choices
  with no place left (`overflow`).

  **Lifecycle**, one transition from `:pending`:

    * `:taken`: a reviewer took it, as is or edited, into a manual version
      parented to it (`resolution_version_id`), with the quality form;
    * `:dismissed`: a reviewer rejected its version (`resolution_review_id`)
      with a reason, the form optional;
    * `:obsolete`: a newer proposal of the composition, or an activation of
      another configuration version, replaced it; no actor.

  The database refuses any other change, any delete, a second pending
  proposal for a composition, and a taken or dismissed proposal without a
  human reviewer.
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  @states [:pending, :taken, :dismissed, :obsolete]

  schema "curation_proposals" do
    field :composition_id, :id
    field :version_id, :id
    field :configuration_version_id, :id
    field :refresh_state_id, :id
    field :refresh_generation, :integer
    field :request_key, :string
    field :model_config_id, :id
    field :profile_id, :id
    field :profile_version_id, :id
    field :packet_hash, :string
    field :arrangement_hash, :string
    field :published_parent_version_id, :id
    field :superseded_on_arrival, :boolean, default: false
    field :marks_digest, :string
    field :carried, JsonValue, default: []
    field :overflow, JsonValue, default: []

    field :state, Ecto.Enum, values: @states, default: :pending
    field :resolved_at, :utc_datetime_usec
    field :resolved_by_actor_id, :id
    field :resolution_reason, :string
    field :resolution_version_id, :id
    field :resolution_review_id, :id
    field :obsoleted_by_proposal_id, :id
    field :quality_form, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def states, do: @states
end
