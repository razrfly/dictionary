defmodule DevilsDictionary.Repo.Migrations.AddComparisonAttempts do
  @moduledoc """
  Matched comparison attempts (#298 C1, C2, C9). Additive:

    * `inference_attempts.evidence_fingerprint`, the digest of the evidence a
      packet shows (`Packet.evidence_fingerprint/1`), stored beside
      `packet_hash` and `prompt_sha256` on every attempt from now on;
    * a fourth `purpose`, `comparison`, with its `arm` label, its case
      (`batch:page:n`) and the sha256 of the page snapshot it was cut from.
      A comparison attempt carries all four; no other attempt carries an arm,
      a case or a snapshot;
    * the four columns are part of an attempt's identity: once written they
      never change;
    * a comparison attempt never becomes a composition version or an item
      basis (a citation's chooser record): a guard on each table refuses a
      row that names it. A proposal is always of a model composition
      version, so it cannot name one either.

  The configuration CHECK, the author guard and persona admission are
  untouched: no comparison instruction can be bound or published.

  Old code keeps working: it never writes `comparison`, and every new column
  is nullable for its purposes.

  **Rollback of the code.** Code from before this PR (`d33a655`) runs on
  this schema: it never names the new columns and reads attempts that carry
  a fingerprint without trouble. It is safe to roll the code back only until
  the first comparison attempt exists. That code's `Attempt` purpose enum has
  no `:comparison`, so once one exists any old read that loads it fails (the
  ops health card's newest attempt of any purpose, for one). After the
  first comparison attempt, roll forward only.

  **Rollback of the schema.** `down` refuses once any comparison attempt or
  any recorded evidence fingerprint exists, because it would drop that
  history: the comparison identities and every fingerprint recorded since.
  Disable the editor and roll forward instead.
  """
  use Ecto.Migration

  @terminal "('completed', 'failed_pre_dispatch', 'ended_by_restart', 'released')"
  @guarded ~w(editorial_composition_versions curation_item_bases)

  # The original `inference_attempts_shape` (migration 20260927114948), with
  # the purposes as a parameter.
  defp shape(purposes) do
    """
    purpose IN #{purposes} AND
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
  end

  def up do
    alter table(:inference_attempts) do
      add :evidence_fingerprint, :text
      add :arm, :text
      add :comparison_case, :text
      add :comparison_snapshot, :text
    end

    drop constraint(:inference_attempts, :inference_attempts_shape)

    create constraint(:inference_attempts, :inference_attempts_shape,
             check: shape("('request', 'readiness_smoke', 'benchmark', 'comparison')")
           )

    create constraint(:inference_attempts, :inference_attempts_comparison_shape,
             check: """
             (evidence_fingerprint IS NULL OR evidence_fingerprint ~ '^[0-9a-f]{64}$') AND
             (purpose = 'comparison') = (arm IS NOT NULL) AND
             (purpose = 'comparison') = (comparison_case IS NOT NULL) AND
             (purpose = 'comparison') = (comparison_snapshot IS NOT NULL) AND
             (purpose <> 'comparison' OR evidence_fingerprint IS NOT NULL) AND
             (arm IS NULL OR arm ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') AND
             (comparison_case IS NULL OR comparison_case ~ '^[a-z0-9][a-z0-9._-]{2,63}:[a-z][a-z0-9-]{0,63}:[12]$') AND
             (comparison_snapshot IS NULL OR comparison_snapshot ~ '^[0-9a-f]{64}$')
             """
           )

    create index(:inference_attempts, [:comparison_case],
             where: "comparison_case IS NOT NULL",
             name: :inference_attempts_comparison_case_index
           )

    execute """
    CREATE FUNCTION inference_attempts_comparison_identity() RETURNS trigger AS $$
    BEGIN
      IF (NEW.evidence_fingerprint, NEW.arm, NEW.comparison_case, NEW.comparison_snapshot)
         IS DISTINCT FROM
         (OLD.evidence_fingerprint, OLD.arm, OLD.comparison_case, OLD.comparison_snapshot) THEN
        RAISE EXCEPTION 'attempt % evidence and comparison identity cannot change', OLD.id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER inference_attempts_comparison_identity BEFORE UPDATE ON inference_attempts
      FOR EACH ROW EXECUTE FUNCTION inference_attempts_comparison_identity();
    """

    execute """
    CREATE FUNCTION curation_refuses_comparison_attempt() RETURNS trigger AS $$
    BEGIN
      IF NEW.attempt_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM inference_attempts a WHERE a.id = NEW.attempt_id AND a.purpose = 'comparison'
      ) THEN
        RAISE EXCEPTION '% cannot come from comparison attempt %: comparisons never publish',
          TG_TABLE_NAME, NEW.attempt_id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Named to fire before each table's own BEFORE triggers.
    for table <- @guarded do
      execute """
      CREATE TRIGGER comparison_attempt_guard BEFORE INSERT OR UPDATE OF attempt_id ON #{table}
        FOR EACH ROW EXECUTE FUNCTION curation_refuses_comparison_attempt();
      """
    end
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM inference_attempts
                  WHERE purpose = 'comparison' OR evidence_fingerprint IS NOT NULL) THEN
        RAISE EXCEPTION 'comparison or evidence-fingerprint history exists; disable the editor and roll forward';
      END IF;
    END $$;
    """

    for table <- @guarded do
      execute "DROP TRIGGER comparison_attempt_guard ON #{table}"
    end

    execute "DROP FUNCTION curation_refuses_comparison_attempt()"
    execute "DROP TRIGGER inference_attempts_comparison_identity ON inference_attempts"
    execute "DROP FUNCTION inference_attempts_comparison_identity()"

    drop index(:inference_attempts, [:comparison_case],
           name: :inference_attempts_comparison_case_index
         )

    drop constraint(:inference_attempts, :inference_attempts_comparison_shape)
    drop constraint(:inference_attempts, :inference_attempts_shape)

    create constraint(:inference_attempts, :inference_attempts_shape,
             check: shape("('request', 'readiness_smoke', 'benchmark')")
           )

    alter table(:inference_attempts) do
      remove :comparison_snapshot
      remove :comparison_case
      remove :arm
      remove :evidence_fingerprint
    end
  end
end
