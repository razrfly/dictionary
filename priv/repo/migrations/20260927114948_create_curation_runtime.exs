defmodule DevilsDictionary.Repo.Migrations.CreateCurationRuntime do
  @moduledoc """
  Curation runtime, stage A (#195): model provenance, the one inference slot,
  attempts and their accounting. Read `docs/curation/runtime-stage-a.md`; each
  constraint here is a row in its invariant map (G, P, C, R).

  Additive only. Nothing here references a composition, a claim or a page, and
  no run or participant column is invented for #197 to fill later.

    * `local_model_configs`: immutable provenance of one pinned model and its
      generation settings. The endpoint is application config, never a column.
    * `inference_services`: one row per physical runtime. Its lock, state and
      fence are the slot every caller on every node goes through (G1, G2).
    * `inference_attempts`: request identity, owner, fence and lifecycle. A
      partial unique index allows one live attempt per service (G1). A
      transition trigger allows only the documented lifecycle, and a finished
      attempt never changes again (G4, G5).
    * `inference_ledger_entries`: append-only reserve, release and charge
      entries per UTC day. Uniques make each attempt reserve once, release once
      and be charged at most once per day (G7, G8).
  """
  use Ecto.Migration

  @live "('admitted', 'dispatched', 'uncertain')"
  @terminal "('completed', 'failed_pre_dispatch', 'ended_by_restart', 'released')"

  def change do
    model_configs()
    services_and_attempts()
    ledger()
    triggers()
  end

  defp model_configs do
    create table(:local_model_configs) do
      add :slug, :text, null: false
      add :runtime, :text, null: false
      add :model_name, :text, null: false
      add :manifest_digest, :text, null: false
      add :layers, :jsonb, null: false
      add :weights_digest, :text, null: false
      add :parameter_size, :text
      add :quantization, :text
      add :family, :text
      add :format, :text
      add :license_name, :text
      add :license_digest, :text
      add :template_digest, :text
      add :runtime_version, :text, null: false
      add :capabilities, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :generation, :map, null: false
      add :instruction_version, :text, null: false
      add :output_contract_version, :text, null: false
      add :config_hash, :text, null: false
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:local_model_configs, [:slug])
    create unique_index(:local_model_configs, [:config_hash])

    create constraint(:local_model_configs, :local_model_configs_shape,
             check: """
             runtime = 'ollama' AND
             manifest_digest ~ '^[0-9a-f]{64}$' AND weights_digest ~ '^[0-9a-f]{64}$' AND
             jsonb_typeof(layers) = 'array' AND jsonb_typeof(capabilities) = 'array' AND
             (generation ->> 'num_ctx')::int BETWEEN 1024 AND 32768 AND
             (generation ->> 'num_predict')::int BETWEEN 1 AND 1024
             """
           )
  end

  defp services_and_attempts do
    create table(:inference_services) do
      add :key, :text, null: false
      add :state, :text, null: false, default: "available"
      add :holder_attempt_id, :bigint
      add :fence, :bigint, null: false, default: 0
      add :epoch, :integer, null: false, default: 0
      add :lease_expires_at, :utc_datetime_usec
      add :quarantine_reason, :text
      add :paused_reason, :text
      add :consecutive_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:inference_services, [:key])

    # G2: the slot's state and its holder agree.
    create constraint(:inference_services, :inference_services_shape,
             check: """
             state IN ('available', 'occupied', 'quarantined', 'paused') AND
             fence >= 0 AND epoch >= 0 AND consecutive_failures >= 0 AND
             (state <> 'occupied' OR holder_attempt_id IS NOT NULL) AND
             (state <> 'available' OR (holder_attempt_id IS NULL AND quarantine_reason IS NULL)) AND
             (state <> 'quarantined' OR quarantine_reason IS NOT NULL) AND
             (state <> 'paused' OR (paused_reason IS NOT NULL AND holder_attempt_id IS NULL))
             """
           )

    create table(:inference_attempts) do
      add :service_id, references(:inference_services, on_delete: :restrict), null: false
      add :model_config_id, references(:local_model_configs, on_delete: :restrict), null: false
      add :request_key, :text, null: false
      add :purpose, :text, null: false
      add :packet_hash, :text, null: false
      add :packet_bytes, :integer, null: false
      add :packet_summary, :map, null: false
      add :prompt_sha256, :text
      add :requested_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :owner, :text, null: false
      add :fence, :bigint, null: false
      add :service_epoch, :integer, null: false
      add :state, :text, null: false, default: "admitted"
      add :outcome, :text
      add :refusal_reasons, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :result, :map
      add :metrics, :map, null: false, default: %{}
      add :transport_retries, :integer, null: false, default: 0
      add :reserved_ms, :integer, null: false
      add :units, :integer, null: false, default: 1
      add :budget_day, :date, null: false
      add :admitted_at, :utc_datetime_usec, null: false
      add :dispatched_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :lease_expires_at, :utc_datetime_usec, null: false
      add :settled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:inference_attempts, [:request_key])
    create unique_index(:inference_attempts, [:id, :service_id])
    create index(:inference_attempts, [:service_id, :state])

    # G1: one live attempt per physical service, whatever the caller did.
    create unique_index(:inference_attempts, [:service_id],
             where: "state IN #{@live}",
             name: :inference_attempts_one_live_per_service
           )

    create constraint(:inference_attempts, :inference_attempts_shape,
             check: """
             purpose IN ('request', 'readiness_smoke', 'benchmark') AND
             state IN ('admitted', 'dispatched', 'completed', 'failed_pre_dispatch',
                       'uncertain', 'ended_by_restart', 'released') AND
             packet_hash ~ '^[0-9a-f]{64}$' AND packet_bytes > 0 AND
             reserved_ms > 0 AND units > 0 AND transport_retries BETWEEN 0 AND 2 AND fence > 0 AND
             jsonb_typeof(refusal_reasons) = 'array' AND
             (state IN #{@terminal}) = (settled_at IS NOT NULL) AND
             (state IN #{@terminal}) = (outcome IS NOT NULL) AND
             (outcome IS NULL OR outcome IN ('accepted', 'abstained', 'refused', 'runtime_error', 'unknown', 'never_sent')) AND
             (state NOT IN ('dispatched', 'completed', 'uncertain', 'ended_by_restart') OR dispatched_at IS NOT NULL) AND
             (state NOT IN ('completed', 'ended_by_restart', 'failed_pre_dispatch', 'released') OR finished_at IS NOT NULL)
             """
           )

    # G2: the holder is one of this service's attempts.
    execute """
            ALTER TABLE inference_services
              ADD CONSTRAINT inference_services_holder_fkey
              FOREIGN KEY (holder_attempt_id, id) REFERENCES inference_attempts (id, service_id)
            """,
            "ALTER TABLE inference_services DROP CONSTRAINT IF EXISTS inference_services_holder_fkey"
  end

  defp ledger do
    create table(:inference_ledger_entries) do
      add :service_id, :bigint, null: false
      add :attempt_id, :bigint, null: false
      add :kind, :text, null: false
      add :day, :date, null: false
      add :amount_ms, :integer, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # G7: reserve once, release once, charge at most once per UTC day.
    create unique_index(:inference_ledger_entries, [:attempt_id, :kind, :day])
    create index(:inference_ledger_entries, [:service_id, :day, :kind])

    create constraint(:inference_ledger_entries, :inference_ledger_entries_shape,
             check: "kind IN ('reserve', 'release', 'charge') AND amount_ms >= 0"
           )

    execute """
            ALTER TABLE inference_ledger_entries
              ADD CONSTRAINT inference_ledger_entries_attempt_fkey
              FOREIGN KEY (attempt_id, service_id) REFERENCES inference_attempts (id, service_id)
            """,
            "ALTER TABLE inference_ledger_entries DROP CONSTRAINT IF EXISTS inference_ledger_entries_attempt_fkey"
  end

  defp triggers do
    execute """
            CREATE FUNCTION runtime_row_is_immutable() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION '% rows are immutable (% on id %)', TG_TABLE_NAME, TG_OP, OLD.id
                USING ERRCODE = 'integrity_constraint_violation';
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS runtime_row_is_immutable() CASCADE"

    for table <- ~w(local_model_configs inference_ledger_entries) do
      execute """
              CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table}
                FOR EACH ROW EXECUTE FUNCTION runtime_row_is_immutable();
              """,
              "DROP TRIGGER IF EXISTS #{table}_immutable ON #{table}"
    end

    # G4, G5: the documented lifecycle only. A finished attempt never changes,
    # and what identifies an attempt never changes at all.
    execute """
            CREATE FUNCTION inference_attempts_lifecycle() RETURNS trigger AS $$
            DECLARE
              allowed boolean;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'inference_attempts rows are not deleted (id %)', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF OLD.state IN #{@terminal} THEN
                RAISE EXCEPTION 'attempt % is finished (%) and immutable', OLD.id, OLD.state
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF (NEW.request_key, NEW.service_id, NEW.model_config_id, NEW.purpose, NEW.packet_hash,
                  NEW.fence, NEW.service_epoch, NEW.reserved_ms, NEW.units, NEW.budget_day,
                  NEW.admitted_at, NEW.requested_by_actor_id, NEW.owner)
                 IS DISTINCT FROM
                 (OLD.request_key, OLD.service_id, OLD.model_config_id, OLD.purpose, OLD.packet_hash,
                  OLD.fence, OLD.service_epoch, OLD.reserved_ms, OLD.units, OLD.budget_day,
                  OLD.admitted_at, OLD.requested_by_actor_id, OLD.owner) THEN
                RAISE EXCEPTION 'attempt % identity cannot change', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              allowed := (OLD.state, NEW.state) IN (
                ('admitted', 'dispatched'), ('admitted', 'released'),
                ('dispatched', 'dispatched'), ('dispatched', 'completed'),
                ('dispatched', 'failed_pre_dispatch'), ('dispatched', 'uncertain'),
                ('uncertain', 'ended_by_restart')
              );

              IF NOT allowed THEN
                RAISE EXCEPTION 'attempt % cannot move from % to %', OLD.id, OLD.state, NEW.state
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS inference_attempts_lifecycle() CASCADE"

    execute """
            CREATE TRIGGER inference_attempts_lifecycle BEFORE UPDATE OR DELETE ON inference_attempts
              FOR EACH ROW EXECUTE FUNCTION inference_attempts_lifecycle();
            """,
            "DROP TRIGGER IF EXISTS inference_attempts_lifecycle ON inference_attempts"

    # G7: a reservation is released in full, once; a charge is only for a
    # finished attempt.
    execute """
            CREATE FUNCTION inference_ledger_entry_guard() RETURNS trigger AS $$
            DECLARE
              attempt record;
            BEGIN
              SELECT state, reserved_ms, budget_day INTO attempt FROM inference_attempts WHERE id = NEW.attempt_id;

              IF NEW.kind = 'reserve' AND (NEW.amount_ms <> attempt.reserved_ms OR NEW.day <> attempt.budget_day) THEN
                RAISE EXCEPTION 'a reservation is the attempt''s own, on its budget day'
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF NEW.kind = 'release' AND NOT EXISTS (
                SELECT 1 FROM inference_ledger_entries r
                 WHERE r.attempt_id = NEW.attempt_id AND r.kind = 'reserve'
                   AND r.day = NEW.day AND r.amount_ms = NEW.amount_ms
              ) THEN
                RAISE EXCEPTION 'a release returns exactly the attempt''s reservation'
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF NEW.kind IN ('release', 'charge') AND attempt.state NOT IN #{@terminal} THEN
                RAISE EXCEPTION 'attempt % is not finished; nothing is settled yet', NEW.attempt_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS inference_ledger_entry_guard() CASCADE"

    execute """
            CREATE TRIGGER inference_ledger_entry_guard BEFORE INSERT ON inference_ledger_entries
              FOR EACH ROW EXECUTE FUNCTION inference_ledger_entry_guard();
            """,
            "DROP TRIGGER IF EXISTS inference_ledger_entry_guard ON inference_ledger_entries"

    # G7: a finished attempt has released its reservation by COMMIT. It is
    # settled completely, or not at all.
    execute """
            CREATE FUNCTION inference_attempts_settled_check() RETURNS trigger AS $$
            BEGIN
              IF NEW.state IN #{@terminal} AND NOT EXISTS (
                SELECT 1 FROM inference_ledger_entries e WHERE e.attempt_id = NEW.id AND e.kind = 'release'
              ) THEN
                RAISE EXCEPTION 'attempt % finished without releasing its reservation', NEW.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS inference_attempts_settled_check() CASCADE"

    execute """
            CREATE CONSTRAINT TRIGGER inference_attempts_settled AFTER UPDATE ON inference_attempts
              DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION inference_attempts_settled_check();
            """,
            "DROP TRIGGER IF EXISTS inference_attempts_settled ON inference_attempts"

    # G1, G4: the slot is held by a live attempt. Checked at COMMIT, so the
    # holder and the attempt move together.
    execute """
            CREATE FUNCTION inference_services_holder_check() RETURNS trigger AS $$
            DECLARE
              s record;
            BEGIN
              SELECT * INTO s FROM inference_services WHERE id = NEW.id;
              IF s.holder_attempt_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM inference_attempts a
                 WHERE a.id = s.holder_attempt_id AND a.state IN #{@live} AND a.fence = s.fence
              ) THEN
                RAISE EXCEPTION 'service % is held by an attempt that is not live under its fence', NEW.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS inference_services_holder_check() CASCADE"

    execute """
            CREATE CONSTRAINT TRIGGER inference_services_holder AFTER INSERT OR UPDATE ON inference_services
              DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION inference_services_holder_check();
            """,
            "DROP TRIGGER IF EXISTS inference_services_holder ON inference_services"
  end
end
