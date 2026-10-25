defmodule DevilsDictionary.Repo.Migrations.CreateCurationRefreshStates do
  @moduledoc """
  The curation refresh clock (#259 §5.1, #253 §7, #198): one row per
  composition and configuration version, saying when its inputs were last
  checked, whether they have changed since, and when it is next due.

  The one table P5 adds. The correctness boundary is the partial unique
  index (at most one run in flight per composition, across configuration
  versions), the row lock and the fence (`lease_token`), never Oban's
  uniqueness.
  """
  use Ecto.Migration

  def change do
    create table(:curation_refresh_states) do
      add :composition_id, references(:editorial_compositions, on_delete: :restrict), null: false

      add :configuration_version_id,
          references(:curation_configuration_versions, on_delete: :restrict),
          null: false

      add :state, :text, null: false, default: "idle"
      add :refresh_generation, :bigint, null: false, default: 0
      add :lease_token, :bigint, null: false, default: 0
      add :lease_expires_at, :utc_datetime_usec
      add :lease_attempts, :integer, null: false, default: 0
      # Decided at admission: admitted only because the window passed.
      add :run_periodic, :boolean, null: false, default: false

      add :admitted_parent_version_id,
          references(:editorial_composition_versions, on_delete: :nilify_all)

      add :superseded_on_arrival, :boolean, null: false, default: false
      add :last_completed_at, :utc_datetime_usec
      add :last_outcome, :text
      add :last_outcome_reason, :text
      add :refresh_after, :utc_datetime_usec
      add :next_retry_at, :utc_datetime_usec
      add :failures, :integer, null: false, default: 0
      add :last_error, :text
      add :input_fingerprint, :text
      add :withheld_digest, :text
      add :dirty_at, :utc_datetime_usec
      add :dirty_reason, :text
      add :dirty_seq, :bigint, null: false, default: 0
      add :run_dirty_seq, :bigint
      add :inputs_last_changed_at, :utc_datetime_usec
      add :inputs_last_changed_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:curation_refresh_states, [:composition_id, :configuration_version_id])

    # At most one run queued or running per composition, whatever the
    # configuration version: the boundary admission relies on.
    create unique_index(:curation_refresh_states, [:composition_id],
             where: "state IN ('queued', 'running')",
             name: :curation_refresh_states_one_in_flight_index
           )

    create index(:curation_refresh_states, [:state, :refresh_after])

    create constraint(:curation_refresh_states, :curation_refresh_states_shape,
             check: """
             state IN ('idle', 'queued', 'running', 'suppressed', 'deferred') AND
             (last_outcome IS NULL OR last_outcome IN ('unchanged', 'needs_editor')) AND
             refresh_generation >= 0 AND lease_token >= 0 AND lease_attempts >= 0 AND
             failures >= 0 AND dirty_seq >= 0 AND
             (state NOT IN ('queued', 'running') OR lease_expires_at IS NOT NULL) AND
             (state <> 'running' OR run_dirty_seq IS NOT NULL) AND
             (state <> 'deferred' OR next_retry_at IS NOT NULL) AND
             (last_completed_at IS NULL OR (last_outcome IS NOT NULL AND refresh_after IS NOT NULL))
             """
           )
  end
end
