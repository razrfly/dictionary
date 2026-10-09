defmodule DevilsDictionary.Repo.Migrations.CreatePagePublications do
  @moduledoc """
  #237 (Stage 5 of #194): the publication record.

  One additive table, `page_publications`: every change of a page's
  `publication_state` is a receipt — publish or withdraw, the states before
  and after, the launch manifest and standing review rule it was made under,
  the gates checked and what each found, the human actor, the reason, and
  when. Append-only, like the route ledger, and refusing TRUNCATE like every
  routing table.

  `pages` gains no column. Its `publication_state` changes only when the
  page's newest receipt records exactly that change (a BEFORE trigger, so a
  raw `UPDATE` from a console fails at the statement), and at commit every
  receipt continues the one before it for its page and the newest has been
  applied (a deferred trigger). So the receipts are a verified chain, as the
  route ledger is: no gap, no phantom, no unrecorded change. A page is born
  a draft. Publication is not a route change; `route_changes` is untouched.

  Two things the database checks loosely, by design: the actor must be a
  human (`actor_kind = 'user'`), as route operations require, while the
  reviewer role is the service's gate (`Routing.Publications`, approval);
  and because the BEFORE trigger reads only the page's newest receipt, two
  receipts for one page in one transaction must each be followed by their
  page update before the next is written (the service writes one receipt
  per transaction).

  This migration is numbered above the standing review rule's signatures
  migration so that a rollback of the stacked schema meets its refusal
  first and drops nothing before refusing.
  """

  use Ecto.Migration

  @gates ~w(identity decision canonical content display approval metadata integrity)

  def change do
    create table(:page_publications) do
      add :page_id, references(:pages, on_delete: :restrict), null: false
      add :action, :string, null: false
      add :before_state, :string, null: false
      add :after_state, :string, null: false
      # The launch manifest a publication was made from, and the standing
      # review rule it was made under (null: a reviewer's own decision).
      add :manifest_sha256, :string
      add :rule_sha256, :string
      add :gates, :map, null: false, default: %{}
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :committed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:page_publications, :page_publications_action,
             check: "action IN ('publish','withdraw')"
           )

    # Publishing takes a draft or a withdrawn page to published, from a
    # manifest, with every gate recorded; withdrawing takes a published page
    # to withdrawn. Nothing returns a page to draft.
    gates = Enum.map_join(@gates, ",", &"'#{&1}'")

    create constraint(:page_publications, :page_publications_transition,
             check: """
             (action = 'publish' AND before_state IN ('draft','withdrawn')
               AND after_state = 'published'
               AND manifest_sha256 ~ '^[0-9a-f]{64}$'
               AND jsonb_typeof(gates) = 'object' AND gates ?& ARRAY[#{gates}])
             OR (action = 'withdraw' AND before_state = 'published' AND after_state = 'withdrawn')
             """
           )

    create constraint(:page_publications, :page_publications_rule,
             check: "rule_sha256 IS NULL OR rule_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:page_publications, :page_publications_reason, check: "btrim(reason) <> ''")

    create index(:page_publications, [:page_id, :id])

    execute(
      """
      CREATE TRIGGER page_publications_refuse_change BEFORE UPDATE OR DELETE ON page_publications
        FOR EACH ROW EXECUTE FUNCTION routing_refuse_change('publication receipts are append-only');
      """,
      "DROP TRIGGER page_publications_refuse_change ON page_publications"
    )

    execute(
      """
      CREATE TRIGGER page_publications_refuse_truncate BEFORE TRUNCATE ON page_publications
        FOR EACH STATEMENT EXECUTE FUNCTION routing_refuse_truncate();
      """,
      "DROP TRIGGER page_publications_refuse_truncate ON page_publications"
    )

    # Publication authority is a human's (D3): the reviewer whose signed
    # standing rule decided it, or a reviewer acting alone. Checked as route
    # operations check their actor.
    execute(
      """
      CREATE FUNCTION routing_publication_actor() RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM actors WHERE id = NEW.actor_id AND actor_kind = 'user') THEN
          RAISE EXCEPTION 'a publication needs a human actor, not actor %', NEW.actor_id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION routing_publication_actor()"
    )

    execute(
      """
      CREATE TRIGGER page_publications_actor BEFORE INSERT ON page_publications
        FOR EACH ROW EXECUTE FUNCTION routing_publication_actor();
      """,
      "DROP TRIGGER page_publications_actor ON page_publications"
    )

    # A page is born a draft, and its publication state changes only as its
    # newest receipt says.
    execute(
      """
      CREATE FUNCTION routing_publication_guard() RETURNS trigger AS $$
      DECLARE r page_publications%ROWTYPE;
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.publication_state <> 'draft' THEN
            RAISE EXCEPTION 'a page is created a draft; publication is a receipt'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          RETURN NEW;
        END IF;

        IF NEW.publication_state IS NOT DISTINCT FROM OLD.publication_state THEN
          RETURN NEW;
        END IF;

        SELECT * INTO r FROM page_publications WHERE page_id = NEW.id ORDER BY id DESC LIMIT 1;

        IF NOT FOUND OR r.before_state <> OLD.publication_state
           OR r.after_state <> NEW.publication_state THEN
          RAISE EXCEPTION 'page % changed from % to % without a publication receipt recording it',
            NEW.id, OLD.publication_state, NEW.publication_state
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION routing_publication_guard()"
    )

    execute(
      """
      CREATE TRIGGER pages_publication_guard BEFORE INSERT OR UPDATE OF publication_state ON pages
        FOR EACH ROW EXECUTE FUNCTION routing_publication_guard();
      """,
      "DROP TRIGGER pages_publication_guard ON pages"
    )

    # At commit: each receipt continues the one before it for its page (the
    # first starts from a draft), and the newest was applied.
    execute(
      """
      CREATE FUNCTION routing_check_publication() RETURNS trigger AS $$
      DECLARE
        prev page_publications%ROWTYPE;
        newest bigint;
        state text;
      BEGIN
        SELECT * INTO prev FROM page_publications
         WHERE page_id = NEW.page_id AND id < NEW.id ORDER BY id DESC LIMIT 1;

        IF (NOT FOUND AND NEW.before_state <> 'draft')
           OR (FOUND AND prev.after_state <> NEW.before_state) THEN
          RAISE EXCEPTION 'publication receipt % does not continue the history of page %',
            NEW.id, NEW.page_id USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        SELECT max(id) INTO newest FROM page_publications WHERE page_id = NEW.page_id;
        SELECT publication_state INTO state FROM pages WHERE id = NEW.page_id;

        IF newest = NEW.id AND state IS DISTINCT FROM NEW.after_state THEN
          RAISE EXCEPTION 'publication receipt % was never applied to page %', NEW.id, NEW.page_id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION routing_check_publication()"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER page_publications_applied
        AFTER INSERT ON page_publications DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION routing_check_publication();
      """,
      "DROP TRIGGER page_publications_applied ON page_publications"
    )

    # Last, so that on rollback it runs first: receipts cannot be
    # regenerated, so the rollback refuses while any exists.
    execute(
      "SELECT 1",
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM page_publications) THEN
          RAISE EXCEPTION 'refusing to roll back page_publications: it holds publication receipts, which cannot be regenerated (docs/routing/recovery.md). Snapshot it, then empty it deliberately, before rolling back.'
            USING ERRCODE = 'object_in_use';
        END IF;
      END
      $$
      """
    )
  end
end
