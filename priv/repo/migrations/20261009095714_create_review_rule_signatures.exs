defmodule DevilsDictionary.Repo.Migrations.CreateReviewRuleSignatures do
  @moduledoc """
  #237 Part A′: the standing review rule's signature is attested in the
  database, not only in the rule file.

  `review_rule_signatures` holds one row per signed rule digest, written by
  `mix dd.routing.rule --sign` after the signer's password is checked: the
  digest signed, the signing user, the time, the method and the attestation.
  Loading a rule requires the row that matches its file signature, so
  editing the file alone cannot make a rule usable: forging a signature
  needs write access to the repository and to this table. The signer must
  hold the reviewer role when the row is written. The table is append-only
  and refuses TRUNCATE, like every routing table.

  `routing_backfill_runs.rule_sha256` records the standing rule a run was
  decided by, so the run row alone says whether a review file or the rule
  decided it: `reviews_sha256` stays the review file's digest and is null
  for a rule run.
  """
  use Ecto.Migration

  def up do
    create table(:review_rule_signatures) do
      add :rule_sha256, :text, null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :signed_at, :utc_datetime, null: false
      add :method, :text, null: false
      add :attestation, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:review_rule_signatures, [:rule_sha256])

    create constraint(:review_rule_signatures, :review_rule_signatures_digest,
             check: "rule_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:review_rule_signatures, :review_rule_signatures_text,
             check: "btrim(method) <> '' AND btrim(attestation) <> ''"
           )

    # Only an account holding the reviewer role signs (D3): checked by the
    # database too, as route operations check their actor.
    execute """
    CREATE FUNCTION review_rule_signature_guard() RETURNS trigger AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND reviewer) THEN
        RAISE EXCEPTION 'a rule signature needs a reviewer account, not user %', NEW.user_id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER review_rule_signatures_guard BEFORE INSERT ON review_rule_signatures
      FOR EACH ROW EXECUTE FUNCTION review_rule_signature_guard()
    """

    execute """
    CREATE TRIGGER review_rule_signatures_refuse_change BEFORE UPDATE OR DELETE ON review_rule_signatures
      FOR EACH ROW EXECUTE FUNCTION routing_refuse_change('a rule signature is permanent')
    """

    execute """
    CREATE TRIGGER review_rule_signatures_refuse_truncate BEFORE TRUNCATE ON review_rule_signatures
      FOR EACH STATEMENT EXECUTE FUNCTION routing_refuse_truncate()
    """

    alter table(:routing_backfill_runs) do
      add :rule_sha256, :text
    end

    create constraint(:routing_backfill_runs, :routing_backfill_runs_rule,
             check: "rule_sha256 IS NULL OR rule_sha256 ~ '^[0-9a-f]{64}$'"
           )
  end

  def down do
    # A recorded signing is permanent: the rollback refuses while any exists,
    # before anything is dropped, as the receipts' migration refuses while a
    # receipt exists.
    execute """
    DO $$
    DECLARE n bigint;
    BEGIN
      SELECT count(*) INTO n FROM review_rule_signatures;
      IF n > 0 THEN
        RAISE EXCEPTION 'refusing to roll back review_rule_signatures: % recorded signing(s) are permanent', n
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END $$;
    """

    drop constraint(:routing_backfill_runs, :routing_backfill_runs_rule)

    alter table(:routing_backfill_runs) do
      remove :rule_sha256
    end

    drop table(:review_rule_signatures)
    execute "DROP FUNCTION review_rule_signature_guard()"
  end
end
