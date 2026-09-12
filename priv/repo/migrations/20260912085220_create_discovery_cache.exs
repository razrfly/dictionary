defmodule DevilsDictionary.Repo.Migrations.CreateDiscoveryCache do
  use Ecto.Migration

  def change do
    create table(:discovery_mappings) do
      add :mapping_key, :text, null: false
      add :version, :integer, null: false
      add :target_object_id, references(:objects, on_delete: :restrict), null: false
      add :source_id, references(:sources, on_delete: :restrict), null: false
      add :operation, :string, null: false
      add :parameters, :map, null: false, default: %{}
      add :configured_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:discovery_mappings, :discovery_mappings_positive_version,
             check: "version > 0"
           )

    create unique_index(:discovery_mappings, [:mapping_key, :version])

    create unique_index(:discovery_mappings, [:mapping_key],
             where: "enabled",
             name: :discovery_mappings_one_enabled_version_index
           )

    create index(:discovery_mappings, [:target_object_id, :source_id, :enabled])

    create table(:discovery_runs) do
      add :mapping_id, references(:discovery_mappings, on_delete: :delete_all), null: false
      add :adapter_version, :string, null: false
      add :request_parameters, :map, null: false, default: %{}
      add :request_key, :string, null: false
      add :position_key, :string, null: false
      add :page_context, :uuid, null: false
      add :page, :integer, null: false, default: 0
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :refresh_after, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :retry_at, :utc_datetime_usec
      add :next_cursor, :text
      add :error_code, :string
      add :completion_reason, :string
      add :result_count, :integer, null: false, default: 0
      add :request_count, :integer, null: false, default: 0
      add :last_request_at, :utc_datetime_usec
      add :display_allowed, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:discovery_runs, :discovery_runs_status,
             check: "status IN ('pending','running','succeeded','failed')"
           )

    create constraint(:discovery_runs, :discovery_runs_page, check: "page >= 0")

    create constraint(:discovery_runs, :discovery_runs_counts,
             check: "result_count >= 0 AND request_count >= 0"
           )

    create constraint(:discovery_runs, :discovery_runs_terminal_shape,
             check: """
             (status = 'pending' AND completed_at IS NULL AND completion_reason IS NULL) OR
             (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND
               completion_reason IS NULL) OR
             (status = 'succeeded' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               refresh_after IS NOT NULL AND expires_at IS NOT NULL AND error_code IS NULL AND
               ((completion_reason = 'results' AND result_count > 0) OR
                (completion_reason IN ('no_exact_keyword','no_results') AND result_count = 0) OR
                (completion_reason = 'transient_results' AND result_count > 0))) OR
             (status = 'failed' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               retry_at IS NOT NULL AND error_code IS NOT NULL AND completion_reason IS NULL AND
               result_count = 0)
             """
           )

    create unique_index(:discovery_runs, [:mapping_id, :request_key],
             where: "status IN ('pending','running')",
             name: :discovery_runs_one_in_flight_index
           )

    create index(:discovery_runs, [:mapping_id, :status, :started_at])
    create index(:discovery_runs, [:mapping_id, :page_context, :page])
    create index(:discovery_runs, [:last_request_at])
    create index(:discovery_runs, [:completed_at])

    create table(:discovery_results) do
      add :run_id, references(:discovery_runs, on_delete: :delete_all), null: false
      add :external_namespace, :string, null: false
      add :external_id, :string, null: false
      add :object_id, references(:objects, on_delete: :nilify_all)
      add :position, :integer, null: false
      add :match_details, :map, null: false, default: %{}
      add :preview_metadata, :map, null: false, default: %{}
      add :display_allowed, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:discovery_results, :discovery_results_position, check: "position >= 0")
    create unique_index(:discovery_results, [:run_id, :external_namespace, :external_id])
    create unique_index(:discovery_results, [:run_id, :position])
    create index(:discovery_results, [:object_id])
    create index(:discovery_results, [:external_namespace, :external_id])

    execute(
      """
      CREATE FUNCTION validate_discovery_mapping_target() RETURNS trigger AS $$
      DECLARE
        target_kind text;
        target_state text;
        provider_active boolean;
      BEGIN
        SELECT kind, lifecycle_state INTO target_kind, target_state
          FROM objects WHERE id = NEW.target_object_id;

        IF target_kind IS NULL OR target_kind NOT IN ('lexeme', 'sense') OR target_state <> 'active' THEN
          RAISE EXCEPTION 'discovery target must be an active lexeme or sense';
        END IF;

        IF target_kind = 'sense' AND NOT EXISTS (
          SELECT 1 FROM senses
           WHERE object_id = NEW.target_object_id AND identity_state = 'active'
        ) THEN
          RAISE EXCEPTION 'discovery sense target must be identity-active';
        END IF;

        SELECT active INTO provider_active FROM sources WHERE id = NEW.source_id;

        IF NEW.enabled AND provider_active IS NOT TRUE THEN
          RAISE EXCEPTION 'enabled discovery mapping requires an active provider source';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION validate_discovery_mapping_target()"
    )

    execute(
      """
      CREATE TRIGGER discovery_mappings_validate_target
        BEFORE INSERT OR UPDATE ON discovery_mappings
        FOR EACH ROW EXECUTE FUNCTION validate_discovery_mapping_target();
      """,
      "DROP TRIGGER discovery_mappings_validate_target ON discovery_mappings"
    )

    execute(
      """
      CREATE FUNCTION keep_discovery_mapping_version_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.mapping_key <> OLD.mapping_key OR NEW.version <> OLD.version OR
           NEW.target_object_id <> OLD.target_object_id OR NEW.source_id <> OLD.source_id OR
           NEW.operation <> OLD.operation OR NEW.parameters <> OLD.parameters OR
           NEW.configured_by_actor_id <> OLD.configured_by_actor_id THEN
          RAISE EXCEPTION 'discovery mapping versions are immutable';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION keep_discovery_mapping_version_immutable()"
    )

    execute(
      """
      CREATE TRIGGER discovery_mappings_keep_version_immutable
        BEFORE UPDATE ON discovery_mappings
        FOR EACH ROW EXECUTE FUNCTION keep_discovery_mapping_version_immutable();
      """,
      "DROP TRIGGER discovery_mappings_keep_version_immutable ON discovery_mappings"
    )

    execute(
      """
      CREATE FUNCTION keep_completed_discovery_run_immutable() RETURNS trigger AS $$
      BEGIN
        IF OLD.status IN ('succeeded', 'failed') AND (
          NEW.mapping_id <> OLD.mapping_id OR NEW.adapter_version <> OLD.adapter_version OR
          NEW.request_parameters <> OLD.request_parameters OR NEW.request_key <> OLD.request_key OR
          NEW.position_key <> OLD.position_key OR NEW.page_context <> OLD.page_context OR
          NEW.page <> OLD.page OR NEW.status <> OLD.status OR
          NEW.started_at IS DISTINCT FROM OLD.started_at OR
          NEW.completed_at IS DISTINCT FROM OLD.completed_at OR
          NEW.refresh_after IS DISTINCT FROM OLD.refresh_after OR
          NEW.expires_at IS DISTINCT FROM OLD.expires_at OR
          NEW.retry_at IS DISTINCT FROM OLD.retry_at OR
          NEW.next_cursor IS DISTINCT FROM OLD.next_cursor OR
          NEW.error_code IS DISTINCT FROM OLD.error_code OR
          NEW.completion_reason IS DISTINCT FROM OLD.completion_reason OR
          NEW.result_count <> OLD.result_count OR NEW.request_count <> OLD.request_count OR
          NEW.last_request_at IS DISTINCT FROM OLD.last_request_at
        ) THEN
          RAISE EXCEPTION 'completed discovery runs are immutable';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION keep_completed_discovery_run_immutable()"
    )

    execute(
      """
      CREATE TRIGGER discovery_runs_keep_completed_immutable
        BEFORE UPDATE ON discovery_runs
        FOR EACH ROW EXECUTE FUNCTION keep_completed_discovery_run_immutable();
      """,
      "DROP TRIGGER discovery_runs_keep_completed_immutable ON discovery_runs"
    )
  end
end
