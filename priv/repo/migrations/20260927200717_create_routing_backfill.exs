defmodule DevilsDictionary.Repo.Migrations.CreateRoutingBackfill do
  @moduledoc """
  Issue #194 Stage 2: the backfill's checkpoint (ADR 0004 §8, step 3).

  Two additive tables. A run is bound to the digests of its export, policy,
  population and reviews; an item is one population record's outcome in that
  run, written in the same transaction as the decision, page and address it
  produced. Both are append-only, apart from a run's `finished_at`, so the
  checkpoint cannot be rewritten after the fact. Nothing existing is altered.
  """
  use Ecto.Migration

  @dispositions ~w(allocated awaiting_review deferred_by_review not_addressed refused
                   missing_from_export missing_from_database input_changed evidence_changed
                   classification_refused)

  def up do
    create table(:routing_backfill_runs) do
      add :run_key, :text, null: false
      add :input_sha256, :text, null: false
      add :policy_sha256, :text, null: false
      add :policy_version, :text, null: false
      add :population_sha256, :text, null: false
      add :reviews_sha256, :text
      add :records, :integer, null: false
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:routing_backfill_runs, [:run_key])

    create constraint(:routing_backfill_runs, :routing_backfill_runs_digests,
             check: """
             run_key ~ '^[0-9a-f]{64}$' AND input_sha256 ~ '^[0-9a-f]{64}$' AND
             policy_sha256 ~ '^[0-9a-f]{64}$' AND population_sha256 ~ '^[0-9a-f]{64}$' AND
             (reviews_sha256 IS NULL OR reviews_sha256 ~ '^[0-9a-f]{64}$') AND records >= 0
             """
           )

    create table(:routing_backfill_items) do
      add :run_id, references(:routing_backfill_runs, on_delete: :restrict), null: false
      add :object_id, references(:objects, on_delete: :restrict), null: false
      add :position, :integer, null: false
      add :disposition, :text, null: false
      add :reason, :text
      add :decision_id, references(:classification_decisions, on_delete: :restrict)
      add :page_id, references(:pages, on_delete: :restrict)
      add :path_id, references(:public_paths, on_delete: :restrict)
      add :proposed_path, :text
      add :review, :map
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:routing_backfill_items, [:run_id, :object_id])
    create unique_index(:routing_backfill_items, [:run_id, :position])
    create index(:routing_backfill_items, [:object_id])

    create constraint(:routing_backfill_items, :routing_backfill_items_shape,
             check: """
             position >= 0 AND
             disposition IN (#{Enum.map_join(@dispositions, ", ", &"'#{&1}'")}) AND
             (disposition <> 'allocated' OR (page_id IS NOT NULL AND path_id IS NOT NULL))
             """
           )

    execute """
    CREATE FUNCTION routing_backfill_append_only() RETURNS trigger AS $$
    BEGIN
      -- Nested, because only a run has finished_at: PL/pgSQL would read the
      -- field of an item's row too if it stood in the same condition.
      IF TG_TABLE_NAME = 'routing_backfill_runs' AND TG_OP = 'UPDATE' THEN
        IF OLD.finished_at IS NULL AND NEW.finished_at IS NOT NULL
           AND (to_jsonb(NEW) - 'finished_at') = (to_jsonb(OLD) - 'finished_at') THEN
          RETURN NEW;
        END IF;
      END IF;

      RAISE EXCEPTION '% is append-only', TG_TABLE_NAME
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql;
    """

    for table <- ~w(routing_backfill_runs routing_backfill_items) do
      execute """
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION routing_backfill_append_only()
      """
    end
  end

  def down do
    drop table(:routing_backfill_items)
    drop table(:routing_backfill_runs)
    execute "DROP FUNCTION routing_backfill_append_only()"
  end
end
