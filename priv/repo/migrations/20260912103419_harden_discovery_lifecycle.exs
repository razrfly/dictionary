defmodule DevilsDictionary.Repo.Migrations.HardenDiscoveryLifecycle do
  use Ecto.Migration

  def up do
    alter table(:sources) do
      add :discovery_retry_after, :utc_datetime_usec
      add :discovery_retry_reason, :string
    end

    alter table(:source_records) do
      add :display_allowed, :boolean, null: false, default: true
      add :display_policy_reason, :text
      add :display_policy_changed_at, :utc_datetime_usec
      add :display_policy_actor_id, references(:actors, on_delete: :restrict)
    end

    create constraint(:source_records, :source_records_display_policy_shape,
             check: """
             (display_policy_reason IS NULL AND display_policy_changed_at IS NULL AND
               display_policy_actor_id IS NULL) OR
             (display_policy_reason IS NOT NULL AND display_policy_changed_at IS NOT NULL AND
               display_policy_actor_id IS NOT NULL)
             """
           )

    alter table(:discovery_runs) do
      add :execution_lease_expires_at, :utc_datetime_usec
    end

    create index(:discovery_runs, [:status, :execution_lease_expires_at])

    alter table(:discovery_results) do
      add :source_record_id, references(:source_records, on_delete: :restrict)
    end

    create index(:discovery_results, [:source_record_id])

    drop constraint(:discovery_runs, :discovery_runs_terminal_shape)

    create constraint(:discovery_runs, :discovery_runs_terminal_shape,
             check: """
             (status = 'pending' AND completed_at IS NULL AND completion_reason IS NULL AND
               execution_lease_expires_at IS NULL) OR
             (status = 'running' AND started_at IS NOT NULL AND completed_at IS NULL AND
               completion_reason IS NULL AND execution_lease_expires_at IS NOT NULL) OR
             (status = 'succeeded' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               refresh_after IS NOT NULL AND expires_at IS NOT NULL AND error_code IS NULL AND
               execution_lease_expires_at IS NULL AND
               ((completion_reason = 'results' AND result_count > 0) OR
                (completion_reason IN ('no_exact_keyword','no_results','transient_results') AND
                  result_count >= 0))) OR
             (status = 'failed' AND started_at IS NOT NULL AND completed_at IS NOT NULL AND
               retry_at IS NOT NULL AND error_code IS NOT NULL AND completion_reason IS NULL AND
               result_count = 0 AND execution_lease_expires_at IS NULL)
             """
           )

    execute("""
    CREATE OR REPLACE FUNCTION keep_completed_discovery_run_immutable() RETURNS trigger AS $$
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
        NEW.last_request_at IS DISTINCT FROM OLD.last_request_at OR
        NEW.execution_lease_expires_at IS DISTINCT FROM OLD.execution_lease_expires_at
      ) THEN
        RAISE EXCEPTION 'completed discovery runs are immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  def down do
    drop constraint(:source_records, :source_records_display_policy_shape)
    drop constraint(:discovery_runs, :discovery_runs_terminal_shape)

    alter table(:discovery_results), do: remove(:source_record_id)
    alter table(:discovery_runs), do: remove(:execution_lease_expires_at)

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

    execute("""
    CREATE OR REPLACE FUNCTION keep_completed_discovery_run_immutable() RETURNS trigger AS $$
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
    """)

    alter table(:source_records) do
      remove :display_policy_actor_id
      remove :display_policy_changed_at
      remove :display_policy_reason
      remove :display_allowed
    end

    alter table(:sources) do
      remove :discovery_retry_reason
      remove :discovery_retry_after
    end
  end
end
