defmodule DevilsDictionary.Repo.Migrations.CreateRoutingFoundation do
  @moduledoc """
  Issue #194 Stage 1: the durable routing foundation of ADR 0004 §5.

  Six additive tables. Nothing existing is altered, so every current reader —
  `/words/:id/:slug`, `/define/:slug`, `/entities/:id/:slug` — is untouched, and
  nothing here allocates a path or publishes a page. Backfill, reader
  integration, On editing and publication are later stages
  (`docs/routing/stage-1-foundation.md`).

  Four things stay separate, as the ADR requires:

    * **page identity** (`pages`) — never an `objects` kind, never an alias of a
      label;
    * **editorial state** (`page_revisions`, `page_memberships`) — immutable
      revisions, each carrying its ordered membership;
    * **classification** (`classification_decisions`) — versioned evidence and
      overrides with no foreign key to any path, so a new decision cannot move
      an address;
    * **addresses** (`public_paths`, `route_changes`) — one uniqueness domain for
      canonical, alias and tombstone paths, and an append-only ledger.

  ## How the database keeps the ledger honest

  Every change to where a path points, and to a page's canonical pointer or
  lifecycle, must name a new `route_changes` row whose before and after states
  equal the old and new rows. The BEFORE triggers check that immediately, so a
  raw `UPDATE` that skips the ledger fails at the statement. The ledger row is
  written first; its `path_id` foreign key is deferred because the path it
  describes is inserted after it.

  The cross-row rules — a page's canonical pointer and its canonical path agree,
  a published page has one, a path only ever serves its original owner or that
  owner's merge successor — are deferred constraint triggers, because a move or
  merge is legitimately inconsistent between its statements.

  Conventions as elsewhere: bigint ids, `utc_datetime_usec`, enum-like strings
  with CHECKs, never Postgres enums; nothing is deleted.
  """

  use Ecto.Migration

  @families ~w(people organizations places events works concepts nature subjects)

  def change do
    pages()
    page_revisions()
    page_memberships()
    public_paths()
    classification_decisions()
    route_changes()
    cross_table_keys()
    immutability()
    ledger_guards()
    consistency()
  end

  # ── pages ────────────────────────────────────────────────────────────────
  defp pages do
    create table(:pages) do
      add :role, :string, null: false
      # A page's locale, not its subject's language or a source's language.
      add :locale, :string, null: false, default: "en"
      add :target_object_id, references(:objects, on_delete: :restrict)
      add :publication_state, :string, null: false, default: "draft"
      add :lifecycle_state, :string, null: false, default: "active"
      add :merged_into_page_id, references(:pages, on_delete: :restrict)
      # Foreign keys for these three are added once their tables exist.
      add :current_revision_id, :bigint
      add :canonical_path_id, :bigint
      add :last_route_change_id, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:pages, :pages_role,
             check: "role IN ('subject','edition','lexeme','overview','collection','choice')"
           )

    create constraint(:pages, :pages_locale, check: "locale ~ '^[a-z]{2,3}(-[a-z0-9]{2,8})*$'")

    create constraint(:pages, :pages_publication_state,
             check: "publication_state IN ('draft','published','withdrawn')"
           )

    create constraint(:pages, :pages_lifecycle_state,
             check: "lifecycle_state IN ('active','merged','split','retired')"
           )

    # Subject, edition and lexeme pages are *about* one registry object; an On
    # overview, a collection and a choice page are editorial and are not.
    create constraint(:pages, :pages_target_by_role,
             check: "(role IN ('subject','edition','lexeme')) = (target_object_id IS NOT NULL)"
           )

    create constraint(:pages, :pages_merged_into,
             check:
               "(lifecycle_state = 'merged') = (merged_into_page_id IS NOT NULL) AND merged_into_page_id <> id"
           )

    create constraint(:pages, :pages_gone_has_no_canonical,
             check: "lifecycle_state IN ('active','split') OR canonical_path_id IS NULL"
           )

    # ADR §5: subject and edition pages share one target + locale domain; a
    # lexeme page has its own.
    create unique_index(:pages, [:target_object_id, :locale],
             name: :pages_subject_target_locale_index,
             where: "role IN ('subject','edition')"
           )

    create unique_index(:pages, [:target_object_id, :locale],
             name: :pages_lexeme_target_locale_index,
             where: "role = 'lexeme'"
           )

    create index(:pages, [:merged_into_page_id])
  end

  # ── page_revisions ───────────────────────────────────────────────────────
  defp page_revisions do
    create table(:page_revisions) do
      add :page_id, references(:pages, on_delete: :restrict), null: false
      add :revision_number, :integer, null: false
      add :title, :text
      add :body, :text
      add :body_format, :string, null: false, default: "markdown"
      add :author_actor_id, references(:actors, on_delete: :restrict), null: false
      add :reviewer_actor_id, references(:actors, on_delete: :restrict)
      add :evidence, :map, null: false, default: %{}
      # Seals the revision's membership: exactly this many rows, at positions
      # 1..n, all written with the revision (checked at commit).
      add :membership_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:page_revisions, :page_revisions_number, check: "revision_number > 0")

    create constraint(:page_revisions, :page_revisions_membership_count,
             check: "membership_count >= 0"
           )

    create constraint(:page_revisions, :page_revisions_body_format,
             check: "body_format IN ('markdown','text')"
           )

    create unique_index(:page_revisions, [:page_id, :revision_number])
    # The composite key the page's current-revision pointer and every
    # membership row hang off, so neither can name another page's revision.
    create unique_index(:page_revisions, [:page_id, :id])
  end

  # ── page_memberships ─────────────────────────────────────────────────────
  defp page_memberships do
    create table(:page_memberships) do
      add :page_id, :bigint, null: false
      add :page_revision_id, :bigint, null: false
      add :position, :integer, null: false
      add :relationship, :string, null: false
      add :target_object_id, references(:objects, on_delete: :restrict)
      add :target_page_id, references(:pages, on_delete: :restrict)
      add :rationale, :text
      add :evidence, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute """
            ALTER TABLE page_memberships
              ADD CONSTRAINT page_memberships_revision_fkey
              FOREIGN KEY (page_id, page_revision_id)
              REFERENCES page_revisions (page_id, id) ON DELETE RESTRICT
            """,
            "ALTER TABLE page_memberships DROP CONSTRAINT page_memberships_revision_fkey"

    # Membership is typed and is never an identity assertion: Putin/poutine is
    # an editorial association, not a synonym.
    create constraint(:page_memberships, :page_memberships_relationship,
             check: """
             relationship IN ('supplies_lexical_material','discusses_subject',
                              'editorial_association','choice_option','split_successor')
             """
           )

    create constraint(:page_memberships, :page_memberships_one_target,
             check: "(target_object_id IS NULL) <> (target_page_id IS NULL)"
           )

    create constraint(:page_memberships, :page_memberships_target_shape,
             check: """
             (relationship NOT IN ('choice_option','split_successor') OR target_page_id IS NOT NULL)
             AND (relationship <> 'supplies_lexical_material' OR target_object_id IS NOT NULL)
             """
           )

    create constraint(:page_memberships, :page_memberships_not_self,
             check: "target_page_id IS NULL OR target_page_id <> page_id"
           )

    create constraint(:page_memberships, :page_memberships_position, check: "position > 0")

    create unique_index(:page_memberships, [:page_revision_id, :position])

    create unique_index(:page_memberships, [:page_revision_id, :relationship, :target_object_id],
             name: :page_memberships_object_once_index,
             where: "target_object_id IS NOT NULL"
           )

    create unique_index(:page_memberships, [:page_revision_id, :relationship, :target_page_id],
             name: :page_memberships_page_once_index,
             where: "target_page_id IS NOT NULL"
           )

    create index(:page_memberships, [:target_object_id])
    create index(:page_memberships, [:target_page_id])
  end

  # ── public_paths ─────────────────────────────────────────────────────────
  defp public_paths do
    create table(:public_paths) do
      # Normalized and stored decoded: `/people/voltaire`, `/concepts/c-plus-plus`.
      add :path, :text, null: false
      add :kind, :string, null: false
      # Immutable: who this address was allocated for.
      add :original_page_id, references(:pages, on_delete: :restrict), null: false
      # Where it resolves now: the owner, or its approved merge successor.
      add :destination_page_id, references(:pages, on_delete: :restrict), null: false
      add :last_route_change_id, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:public_paths, :public_paths_kind,
             check: "kind IN ('canonical','alias','tombstone')"
           )

    # A registered namespace and one slug (or the reserved locale form), NFC
    # and lowercase, with no percent-encoding, query, fragment, backslash,
    # whitespace, control character or dot segment. The slug's character rules
    # are `Routing.Address`'s; this keeps a raw writer inside the registry.
    namespaces = Enum.join(@families ++ ["on"], "|")

    create constraint(:public_paths, :public_paths_shape,
             check: ~s"""
             (path ~ '^/(#{namespaces})/[^/]+$'
              OR path ~ '^/l/[a-z]{2,3}(-[a-z0-9]{2,8})*/(#{namespaces})/[^/]+$')
             AND path !~ '[[:space:][:cntrl:]?#%\\\\]'
             AND path !~ '/\\.\\.?(/|$)'
             AND path IS NFC NORMALIZED
             AND path = lower(path)
             AND octet_length(path) <= 512
             """
           )

    # The slug's ASCII: lowercase letters, digits and single inner hyphens —
    # no `+`, `'`, `_` or `.`, which a request could never name. Non-ASCII
    # letters, marks and numbers are `Routing.Address`'s to check.
    create constraint(:public_paths, :public_paths_slug_characters,
             check: ~S"""
             path ~ '^[/a-z0-9\u0080-\U0010FFFF-]+$' AND path !~ '(/-|-/|--|-$)'
             """
           )

    # One uniqueness domain for current, historical and reserved addresses.
    create unique_index(:public_paths, [:path])

    # At most one canonical per page (and so per page locale). The page's
    # pointer agreeing with it is the deferred check below.
    create unique_index(:public_paths, [:destination_page_id],
             name: :public_paths_one_canonical_index,
             where: "kind = 'canonical'"
           )

    # Every path serving a page: merge, retire and the commit-time checks.
    create index(:public_paths, [:destination_page_id])
    create index(:public_paths, [:original_page_id])
  end

  # ── classification_decisions ─────────────────────────────────────────────
  defp classification_decisions do
    families = Enum.map_join(@families, ",", &"'#{&1}'")

    create table(:classification_decisions) do
      add :object_id, references(:entities, column: :object_id, on_delete: :restrict), null: false

      add :origin, :string, null: false
      add :status, :string, null: false
      add :family, :string
      add :candidate_families, {:array, :string}, null: false, default: []
      add :rule_ids, {:array, :string}, null: false, default: []
      add :reasons, {:array, :string}, null: false, default: []
      add :warnings, {:array, :string}, null: false, default: []
      add :policy_version, :string, null: false
      add :evidence_fingerprint, :string, null: false
      add :source_pins, {:array, :map}, null: false, default: []
      add :reviewer_actor_id, references(:actors, on_delete: :restrict)
      add :reason, :text
      add :supersedes_id, references(:classification_decisions, on_delete: :restrict)
      add :is_current, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:classification_decisions, :classification_decisions_origin,
             check: "origin IN ('evaluator','override')"
           )

    create constraint(:classification_decisions, :classification_decisions_status,
             check: "status IN ('mapped','needs_review','excluded_source_page','identity_review')"
           )

    # A family is selected only by a mapping. Review, exclusion and identity
    # review keep their candidates visible and select nothing — there is no
    # silent Subjects fallback.
    create constraint(:classification_decisions, :classification_decisions_family,
             check: """
             (status = 'mapped') = (family IS NOT NULL)
             AND (family IS NULL OR family IN (#{families}))
             AND candidate_families <@ ARRAY[#{families}]::varchar[]
             """
           )

    create constraint(:classification_decisions, :classification_decisions_override,
             check: """
             origin <> 'override'
             OR (reviewer_actor_id IS NOT NULL AND reason IS NOT NULL AND btrim(reason) <> '')
             """
           )

    create constraint(:classification_decisions, :classification_decisions_fingerprint,
             check: "evidence_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create unique_index(:classification_decisions, [:object_id],
             name: :classification_decisions_one_current_index,
             where: "is_current"
           )

    create index(:classification_decisions, [:object_id, :inserted_at])
  end

  # ── route_changes ────────────────────────────────────────────────────────
  defp route_changes do
    create table(:route_changes) do
      add :operation_id, :uuid, null: false
      add :sequence, :integer, null: false
      add :operation, :string, null: false

      # A path transition. `before_kind` is NULL when the path was created.
      add :path_id, :bigint
      add :before_kind, :string
      add :after_kind, :string
      add :before_destination_id, references(:pages, on_delete: :restrict)
      add :after_destination_id, references(:pages, on_delete: :restrict)

      # A page transition: the routing columns before and after, which is also
      # what a rollback restores.
      add :page_id, references(:pages, on_delete: :restrict)
      add :before_lifecycle, :string
      add :after_lifecycle, :string
      add :before_canonical_path_id, :bigint
      add :after_canonical_path_id, :bigint
      add :before_merged_into_id, references(:pages, on_delete: :restrict)
      add :after_merged_into_id, references(:pages, on_delete: :restrict)
      add :before_revision_id, references(:page_revisions, on_delete: :restrict)
      add :after_revision_id, references(:page_revisions, on_delete: :restrict)

      add :classification_decision_id,
          references(:classification_decisions, on_delete: :restrict)

      add :policy_version, :string
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :reverts_operation_id, :uuid
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:route_changes, :route_changes_operation,
             check:
               "operation IN ('allocate','move','merge','split','retire','restore','rollback')"
           )

    create constraint(:route_changes, :route_changes_subject,
             check: """
             (path_id IS NOT NULL OR page_id IS NOT NULL)
             AND (path_id IS NULL) = (after_kind IS NULL)
             AND (path_id IS NULL) = (after_destination_id IS NULL)
             AND (before_kind IS NULL) = (before_destination_id IS NULL)
             AND (page_id IS NULL) = (after_lifecycle IS NULL)
             AND (page_id IS NULL) = (before_lifecycle IS NULL)
             """
           )

    create constraint(:route_changes, :route_changes_kinds,
             check: """
             (before_kind IS NULL OR before_kind IN ('canonical','alias','tombstone'))
             AND (after_kind IS NULL OR after_kind IN ('canonical','alias','tombstone'))
             """
           )

    # A row records a change, never a no-op a writer could slip in unapplied.
    # A page row changes its route; a revision alone is editorial, and a
    # revision-only row is exactly the phantom the continuity check cannot see.
    create constraint(:route_changes, :route_changes_changes_something,
             check: """
             (path_id IS NULL OR before_kind IS NULL OR before_kind <> after_kind
               OR before_destination_id <> after_destination_id)
             AND (page_id IS NULL OR before_lifecycle <> after_lifecycle
               OR before_canonical_path_id IS DISTINCT FROM after_canonical_path_id
               OR before_merged_into_id IS DISTINCT FROM after_merged_into_id)
             """
           )

    # What an allocation may do, whoever writes it: create a canonical, or
    # reclaim its own page's alias, and point an active page's empty canonical
    # at it. A tombstone is a deliberate removal: bringing one back is a
    # human's `restore`, like retiring, re-pointing or merging, and naming it
    # `allocate` does not make it one.
    create constraint(:route_changes, :route_changes_allocate_shape,
             check: """
             operation <> 'allocate' OR (
               (path_id IS NULL OR (after_kind = 'canonical'
                 AND (before_kind IS NULL OR (before_kind = 'alias'
                   AND before_destination_id = after_destination_id))))
               AND (page_id IS NULL OR (before_lifecycle = 'active' AND after_lifecycle = 'active'
                 AND before_canonical_path_id IS NULL AND after_canonical_path_id IS NOT NULL
                 AND before_merged_into_id IS NULL AND after_merged_into_id IS NULL
                 AND before_revision_id IS NOT DISTINCT FROM after_revision_id)))
             """
           )

    create constraint(:route_changes, :route_changes_reason, check: "btrim(reason) <> ''")

    create constraint(:route_changes, :route_changes_rollback,
             check: "(operation = 'rollback') = (reverts_operation_id IS NOT NULL)"
           )

    create unique_index(:route_changes, [:operation_id, :sequence])
    create index(:route_changes, [:path_id])
    create index(:route_changes, [:page_id])
    create index(:route_changes, [:before_destination_id])
    create index(:route_changes, [:after_destination_id])
    create index(:route_changes, [:reverts_operation_id])
  end

  # ── keys between the tables above ────────────────────────────────────────
  defp cross_table_keys do
    # The current revision must be one of this page's revisions.
    execute """
            ALTER TABLE pages
              ADD CONSTRAINT pages_current_revision_fkey
              FOREIGN KEY (id, current_revision_id)
              REFERENCES page_revisions (page_id, id) ON DELETE RESTRICT
            """,
            "ALTER TABLE pages DROP CONSTRAINT pages_current_revision_fkey"

    execute """
            ALTER TABLE pages
              ADD CONSTRAINT pages_canonical_path_fkey
              FOREIGN KEY (canonical_path_id) REFERENCES public_paths (id)
              ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
            """,
            "ALTER TABLE pages DROP CONSTRAINT pages_canonical_path_fkey"

    execute """
            ALTER TABLE pages
              ADD CONSTRAINT pages_last_route_change_fkey
              FOREIGN KEY (last_route_change_id) REFERENCES route_changes (id) ON DELETE RESTRICT
            """,
            "ALTER TABLE pages DROP CONSTRAINT pages_last_route_change_fkey"

    execute """
            ALTER TABLE public_paths
              ADD CONSTRAINT public_paths_last_route_change_fkey
              FOREIGN KEY (last_route_change_id) REFERENCES route_changes (id) ON DELETE RESTRICT
            """,
            "ALTER TABLE public_paths DROP CONSTRAINT public_paths_last_route_change_fkey"

    # Deferred: the ledger row describing a new path is written before it.
    for column <- ~w(path_id before_canonical_path_id after_canonical_path_id) do
      execute """
              ALTER TABLE route_changes
                ADD CONSTRAINT route_changes_#{column}_fkey
                FOREIGN KEY (#{column}) REFERENCES public_paths (id)
                ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
              """,
              "ALTER TABLE route_changes DROP CONSTRAINT route_changes_#{column}_fkey"
    end
  end

  # ── nothing here is deleted; history is never edited ────────────────────
  defp immutability do
    execute """
            CREATE FUNCTION routing_refuse_change() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION '% rows cannot be %d (%)', TG_TABLE_NAME, lower(TG_OP), TG_ARGV[0]
                USING ERRCODE = 'integrity_constraint_violation';
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_refuse_change()"

    for {table, ops, why} <- [
          {"pages", "DELETE", "retire a page instead"},
          {"public_paths", "DELETE", "a path reservation is permanent"},
          {"page_revisions", "UPDATE OR DELETE", "revisions are immutable"},
          {"page_memberships", "UPDATE OR DELETE", "membership belongs to an immutable revision"},
          {"classification_decisions", "DELETE", "decision history is retained"},
          {"route_changes", "UPDATE OR DELETE", "the route ledger is append-only"}
        ] do
      execute """
              CREATE TRIGGER #{table}_refuse_change BEFORE #{ops} ON #{table}
                FOR EACH ROW EXECUTE FUNCTION routing_refuse_change('#{why}');
              """,
              "DROP TRIGGER #{table}_refuse_change ON #{table}"
    end

    # Row triggers do not see TRUNCATE, including one that cascades from
    # `objects`. Only an explicit, transaction-local opt-in — the test
    # suite's reset — may empty these tables.
    execute """
            CREATE FUNCTION routing_refuse_truncate() RETURNS trigger AS $$
            BEGIN
              IF current_setting('dictionary.allow_routing_truncate', true) IS DISTINCT FROM 'on' THEN
                RAISE EXCEPTION '% cannot be truncated: routing history is permanent', TG_TABLE_NAME
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_refuse_truncate()"

    for table <-
          ~w(pages page_revisions page_memberships public_paths classification_decisions route_changes) do
      execute """
              CREATE TRIGGER #{table}_refuse_truncate BEFORE TRUNCATE ON #{table}
                FOR EACH STATEMENT EXECUTE FUNCTION routing_refuse_truncate();
              """,
              "DROP TRIGGER #{table}_refuse_truncate ON #{table}"
    end

    # Membership is sealed by its revision: a row may only fill one of the
    # positions 1..membership_count the immutable revision declared, and at
    # commit every position is filled. A later insert has nowhere to go.
    execute """
            CREATE FUNCTION routing_membership_sealed() RETURNS trigger AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM page_revisions
                 WHERE id = NEW.page_revision_id AND NEW.position <= membership_count
              ) THEN
                RAISE EXCEPTION 'page revision % declares no membership position %',
                  NEW.page_revision_id, NEW.position USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_membership_sealed()"

    execute """
            CREATE TRIGGER page_memberships_sealed BEFORE INSERT ON page_memberships
              FOR EACH ROW EXECUTE FUNCTION routing_membership_sealed();
            """,
            "DROP TRIGGER page_memberships_sealed ON page_memberships"

    execute """
            CREATE FUNCTION routing_membership_complete() RETURNS trigger AS $$
            DECLARE written integer;
            BEGIN
              SELECT count(*) INTO written FROM page_memberships WHERE page_revision_id = NEW.id;
              IF written <> NEW.membership_count THEN
                RAISE EXCEPTION 'page revision % declares % memberships and has %',
                  NEW.id, NEW.membership_count, written USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_membership_complete()"

    execute """
            CREATE CONSTRAINT TRIGGER page_revisions_membership_complete
              AFTER INSERT ON page_revisions DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION routing_membership_complete();
            """,
            "DROP TRIGGER page_revisions_membership_complete ON page_revisions"

    # A decision is immutable except for losing currency, and an override is
    # a human reviewer's: provider payloads and importers cannot write one.
    execute """
            CREATE FUNCTION routing_decision_guard() RETURNS trigger AS $$
            BEGIN
              IF TG_OP = 'UPDATE' THEN
                IF (to_jsonb(NEW) - 'is_current') IS DISTINCT FROM (to_jsonb(OLD) - 'is_current')
                   OR (NEW.is_current AND NOT OLD.is_current) THEN
                  RAISE EXCEPTION 'classification decision % is immutable; supersede it', OLD.id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              ELSIF NEW.origin = 'override' AND NOT EXISTS (
                SELECT 1 FROM actors WHERE id = NEW.reviewer_actor_id AND actor_kind = 'user'
              ) THEN
                RAISE EXCEPTION 'an override needs a human reviewer, not actor %', NEW.reviewer_actor_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_decision_guard()"

    execute """
            CREATE TRIGGER classification_decisions_guard
              BEFORE INSERT OR UPDATE ON classification_decisions
              FOR EACH ROW EXECUTE FUNCTION routing_decision_guard();
            """,
            "DROP TRIGGER classification_decisions_guard ON classification_decisions"
  end

  # ── no routing mutation without its ledger row, checked per statement ───
  defp ledger_guards do
    # Allocation may be a batch job's; moving, merging, splitting, retiring or
    # rolling back an address is an approved human decision.
    execute """
            CREATE FUNCTION routing_route_change_guard() RETURNS trigger AS $$
            BEGIN
              IF NEW.operation <> 'allocate' AND NOT EXISTS (
                SELECT 1 FROM actors WHERE id = NEW.actor_id AND actor_kind = 'user'
              ) THEN
                RAISE EXCEPTION 'route % needs a human actor, not actor %', NEW.operation, NEW.actor_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF NEW.operation = 'rollback' AND (NEW.reverts_operation_id = NEW.operation_id
                 OR NOT EXISTS (SELECT 1 FROM route_changes WHERE operation_id = NEW.reverts_operation_id)) THEN
                RAISE EXCEPTION 'a rollback reverts an earlier operation, not %', NEW.reverts_operation_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_route_change_guard()"

    execute """
            CREATE TRIGGER route_changes_guard BEFORE INSERT ON route_changes
              FOR EACH ROW EXECUTE FUNCTION routing_route_change_guard();
            """,
            "DROP TRIGGER route_changes_guard ON route_changes"

    execute """
            CREATE FUNCTION routing_path_guard() RETURNS trigger AS $$
            DECLARE rc route_changes%ROWTYPE;
            BEGIN
              IF TG_OP = 'UPDATE' THEN
                IF NEW.id <> OLD.id OR NEW.path <> OLD.path
                   OR NEW.original_page_id <> OLD.original_page_id THEN
                  RAISE EXCEPTION 'public path % keeps its spelling and original owner forever', OLD.id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;

                IF NEW.kind = OLD.kind AND NEW.destination_page_id = OLD.destination_page_id
                   AND NEW.last_route_change_id = OLD.last_route_change_id THEN
                  RETURN NEW;
                END IF;

                IF NEW.last_route_change_id <= OLD.last_route_change_id THEN
                  RAISE EXCEPTION 'public path % changed without a new route change', OLD.id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              ELSIF NEW.destination_page_id <> NEW.original_page_id THEN
                RAISE EXCEPTION 'a new path is allocated to its own page, not page %', NEW.destination_page_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              SELECT * INTO rc FROM route_changes WHERE id = NEW.last_route_change_id;

              IF NOT FOUND OR rc.path_id IS DISTINCT FROM NEW.id
                 OR rc.after_kind IS DISTINCT FROM NEW.kind
                 OR rc.after_destination_id IS DISTINCT FROM NEW.destination_page_id
                 OR (TG_OP = 'INSERT' AND rc.before_kind IS NOT NULL)
                 OR (TG_OP = 'UPDATE' AND (rc.before_kind IS DISTINCT FROM OLD.kind
                     OR rc.before_destination_id IS DISTINCT FROM OLD.destination_page_id)) THEN
                RAISE EXCEPTION 'route change % does not record public path % as it changed',
                  NEW.last_route_change_id, NEW.id USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_path_guard()"

    execute """
            CREATE TRIGGER public_paths_guard BEFORE INSERT OR UPDATE ON public_paths
              FOR EACH ROW EXECUTE FUNCTION routing_path_guard();
            """,
            "DROP TRIGGER public_paths_guard ON public_paths"

    execute """
            CREATE FUNCTION routing_page_guard() RETURNS trigger AS $$
            DECLARE rc route_changes%ROWTYPE;
            BEGIN
              IF TG_OP = 'INSERT' THEN
                IF NEW.lifecycle_state <> 'active' OR NEW.canonical_path_id IS NOT NULL
                   OR NEW.merged_into_page_id IS NOT NULL OR NEW.last_route_change_id IS NOT NULL THEN
                  RAISE EXCEPTION 'a page is created active and unrouted; allocation is a route change'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
                RETURN NEW;
              END IF;

              IF NEW.role <> OLD.role OR NEW.locale <> OLD.locale
                 OR NEW.target_object_id IS DISTINCT FROM OLD.target_object_id THEN
                RAISE EXCEPTION 'page % keeps its role, locale and target', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              -- An active page's revision is editorial. A split page's revision
              -- holds its successors, so for any other lifecycle it is routing.
              IF NEW.lifecycle_state = OLD.lifecycle_state
                 AND NEW.canonical_path_id IS NOT DISTINCT FROM OLD.canonical_path_id
                 AND NEW.merged_into_page_id IS NOT DISTINCT FROM OLD.merged_into_page_id
                 AND NEW.last_route_change_id IS NOT DISTINCT FROM OLD.last_route_change_id
                 AND (OLD.lifecycle_state = 'active'
                      OR NEW.current_revision_id IS NOT DISTINCT FROM OLD.current_revision_id) THEN
                RETURN NEW;
              END IF;

              IF NEW.last_route_change_id IS NULL
                 OR NEW.last_route_change_id <= coalesce(OLD.last_route_change_id, 0) THEN
                RAISE EXCEPTION 'page % changed its route without a new route change', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              SELECT * INTO rc FROM route_changes WHERE id = NEW.last_route_change_id;

              IF NOT FOUND OR rc.page_id IS DISTINCT FROM NEW.id
                 OR rc.before_lifecycle IS DISTINCT FROM OLD.lifecycle_state
                 OR rc.after_lifecycle IS DISTINCT FROM NEW.lifecycle_state
                 OR rc.before_canonical_path_id IS DISTINCT FROM OLD.canonical_path_id
                 OR rc.after_canonical_path_id IS DISTINCT FROM NEW.canonical_path_id
                 OR rc.before_merged_into_id IS DISTINCT FROM OLD.merged_into_page_id
                 OR rc.after_merged_into_id IS DISTINCT FROM NEW.merged_into_page_id
                 OR rc.before_revision_id IS DISTINCT FROM OLD.current_revision_id
                 OR rc.after_revision_id IS DISTINCT FROM NEW.current_revision_id THEN
                RAISE EXCEPTION 'route change % does not record page % as it changed',
                  NEW.last_route_change_id, NEW.id USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_page_guard()"

    execute """
            CREATE TRIGGER pages_guard BEFORE INSERT OR UPDATE ON pages
              FOR EACH ROW EXECUTE FUNCTION routing_page_guard();
            """,
            "DROP TRIGGER pages_guard ON pages"
  end

  # ── cross-row rules, checked at commit ───────────────────────────────────
  defp consistency do
    # The registry's own reading of a merge (`Registry.resolve/1`): follow the
    # latest merge event from each merged object to its output.
    execute """
            CREATE FUNCTION routing_identity_survivor(start bigint) RETURNS bigint AS $$
            DECLARE
              current bigint := start;
              next_id bigint;
              seen bigint[] := ARRAY[start];
              final_state text;
            BEGIN
              LOOP
                SELECT output.object_id INTO next_id
                  FROM objects o
                  JOIN identity_event_members input
                    ON input.object_id = o.id AND input.role = 'input'
                  JOIN identity_events e ON e.id = input.event_id AND e.operation = 'merge'
                  JOIN identity_event_members output
                    ON output.event_id = e.id AND output.role = 'output'
                 WHERE o.id = current AND o.lifecycle_state = 'merged'
                 ORDER BY e.id DESC
                 LIMIT 1;

                EXIT WHEN next_id IS NULL;
                -- A cycle or an over-long chain has no survivor but the start.
                IF next_id = ANY(seen) OR array_length(seen, 1) > 64 THEN
                  RETURN start;
                END IF;
                current := next_id;
                seen := seen || next_id;
                next_id := NULL;
              END LOOP;

              -- As `Registry.canonical_id/1`: a chain ending in a split has no
              -- single survivor, so the identity is its own.
              SELECT lifecycle_state INTO final_state FROM objects WHERE id = current;
              IF current <> start AND final_state = 'split' THEN
                RETURN start;
              END IF;
              RETURN current;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_identity_survivor(bigint)"

    execute """
            CREATE FUNCTION routing_check_page(target bigint) RETURNS void AS $$
            DECLARE
              p pages%ROWTYPE;
              c public_paths%ROWTYPE;
              held bigint;
              object_kind text;
              entity_kind text;
            BEGIN
              SELECT * INTO p FROM pages WHERE id = target;

              IF p.role IN ('subject','edition','lexeme') THEN
                SELECT o.kind, e.entity_kind INTO object_kind, entity_kind
                  FROM objects o LEFT JOIN entities e ON e.object_id = o.id
                 WHERE o.id = p.target_object_id;

                IF ((p.role = 'lexeme' AND object_kind = 'lexeme')
                     OR (p.role = 'subject' AND object_kind = 'entity' AND entity_kind <> 'edition')
                     OR (p.role = 'edition' AND entity_kind = 'edition')) IS NOT TRUE THEN
                  RAISE EXCEPTION 'a % page cannot target % object %', p.role,
                    coalesce(entity_kind, object_kind), p.target_object_id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;

              IF p.canonical_path_id IS NOT NULL THEN
                SELECT * INTO c FROM public_paths WHERE id = p.canonical_path_id;
                IF c.kind <> 'canonical' OR c.destination_page_id <> p.id THEN
                  RAISE EXCEPTION 'page % points at path % (%), which is not its canonical',
                    p.id, c.id, c.kind USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;

              SELECT id INTO held FROM public_paths WHERE destination_page_id = p.id AND kind = 'canonical';
              IF held IS DISTINCT FROM p.canonical_path_id AND held IS NOT NULL THEN
                RAISE EXCEPTION 'path % is canonical for page %, which points at %',
                  held, p.id, p.canonical_path_id USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF p.publication_state = 'published' AND p.lifecycle_state IN ('active','split')
                 AND p.canonical_path_id IS NULL THEN
                RAISE EXCEPTION 'published page % has no canonical path', p.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF p.lifecycle_state = 'merged'
                 AND EXISTS (SELECT 1 FROM public_paths WHERE destination_page_id = p.id) THEN
                RAISE EXCEPTION 'merged page % still receives paths', p.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF p.lifecycle_state = 'retired' AND EXISTS (
                SELECT 1 FROM public_paths WHERE destination_page_id = p.id AND kind <> 'tombstone'
              ) THEN
                RAISE EXCEPTION 'retired page % still serves a live path', p.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF p.merged_into_page_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pages s
                 WHERE s.id = p.merged_into_page_id AND s.role = p.role AND s.locale = p.locale
              ) THEN
                RAISE EXCEPTION 'page % merged into a page of another role or locale', p.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF p.lifecycle_state = 'split' AND p.target_object_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM objects o WHERE o.id = p.target_object_id AND o.lifecycle_state = 'split'
              ) THEN
                RAISE EXCEPTION 'page % is split but its identity % is not', p.id, p.target_object_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              -- A page about a registry object merges only where the registry
              -- merged that object: into a page about the same surviving identity.
              IF p.merged_into_page_id IS NOT NULL AND p.target_object_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pages s JOIN objects o ON o.id = p.target_object_id
                 WHERE s.id = p.merged_into_page_id AND o.lifecycle_state = 'merged'
                   AND routing_identity_survivor(p.target_object_id)
                       = routing_identity_survivor(s.target_object_id)
              ) THEN
                RAISE EXCEPTION 'page % merged into a page about a different identity', p.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_check_page(bigint)"

    # A path serves its original owner or, after an approved merge, that
    # owner's successor — never an unrelated page. Its locale prefix matches.
    execute """
            CREATE FUNCTION routing_check_path(target bigint) RETURNS void AS $$
            DECLARE
              x public_paths%ROWTYPE;
              served bigint;
              hops integer := 0;
              page_locale text;
            BEGIN
              SELECT * INTO x FROM public_paths WHERE id = target;
              served := x.original_page_id;

              WHILE served <> x.destination_page_id LOOP
                SELECT merged_into_page_id INTO served FROM pages WHERE id = served;
                hops := hops + 1;
                IF served IS NULL OR hops > 64 THEN
                  RAISE EXCEPTION 'path % (%) was repurposed: page % is not page % or its merge successor',
                    x.id, x.path, x.destination_page_id, x.original_page_id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END LOOP;

              SELECT locale INTO page_locale FROM pages WHERE id = x.destination_page_id;
              IF (page_locale = 'en') <> (x.path NOT LIKE '/l/%')
                 OR (page_locale <> 'en' AND x.path NOT LIKE '/l/' || page_locale || '/%') THEN
                RAISE EXCEPTION 'path % does not carry the locale of page %', x.path, x.destination_page_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              PERFORM routing_check_page(x.destination_page_id);
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_check_path(bigint)"

    execute """
            CREATE FUNCTION routing_consistent() RETURNS trigger AS $$
            DECLARE routed bigint;
            BEGIN
              IF TG_TABLE_NAME = 'pages' THEN
                PERFORM routing_check_page(NEW.id);

                -- Un-merging or re-pointing a page must not strand a path that
                -- reached its destination through it: re-check every path whose
                -- original owner merged, directly or not, into this page.
                IF TG_OP = 'UPDATE' AND (OLD.lifecycle_state <> NEW.lifecycle_state
                   OR OLD.merged_into_page_id IS DISTINCT FROM NEW.merged_into_page_id) THEN
                  FOR routed IN
                    WITH RECURSIVE feeders(id) AS (
                      SELECT NEW.id
                      UNION
                      SELECT p.id FROM pages p JOIN feeders f ON p.merged_into_page_id = f.id
                    )
                    SELECT x.id FROM public_paths x WHERE x.original_page_id IN (SELECT id FROM feeders)
                  LOOP
                    PERFORM routing_check_path(routed);
                  END LOOP;
                END IF;
              ELSE
                PERFORM routing_check_path(NEW.id);
                IF TG_OP = 'UPDATE' AND OLD.destination_page_id <> NEW.destination_page_id THEN
                  PERFORM routing_check_page(OLD.destination_page_id);
                END IF;
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_consistent()"

    # Every ledger row was applied and continues the one before it for the
    # same path or page, so the ledger is a chain with no invented links.
    execute """
            CREATE FUNCTION routing_check_change() RETURNS trigger AS $$
            DECLARE
              prev route_changes%ROWTYPE;
              applied bigint;
            BEGIN
              IF NEW.path_id IS NOT NULL THEN
                SELECT * INTO prev FROM route_changes
                 WHERE path_id = NEW.path_id AND id < NEW.id ORDER BY id DESC LIMIT 1;

                IF (NOT FOUND AND NEW.before_kind IS NOT NULL)
                   OR (FOUND AND (NEW.before_kind IS NULL OR prev.after_kind <> NEW.before_kind
                       OR prev.after_destination_id <> NEW.before_destination_id)) THEN
                  RAISE EXCEPTION 'route change % does not continue the history of path %',
                    NEW.id, NEW.path_id USING ERRCODE = 'integrity_constraint_violation';
                END IF;

                SELECT last_route_change_id INTO applied FROM public_paths WHERE id = NEW.path_id;
                IF applied IS NULL OR applied < NEW.id THEN
                  RAISE EXCEPTION 'route change % was never applied to path %', NEW.id, NEW.path_id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;

              IF NEW.page_id IS NOT NULL THEN
                SELECT * INTO prev FROM route_changes
                 WHERE page_id = NEW.page_id AND id < NEW.id ORDER BY id DESC LIMIT 1;

                IF (NOT FOUND AND (NEW.before_lifecycle <> 'active'
                      OR NEW.before_canonical_path_id IS NOT NULL
                      OR NEW.before_merged_into_id IS NOT NULL))
                   OR (FOUND AND (prev.after_lifecycle <> NEW.before_lifecycle
                      OR prev.after_canonical_path_id IS DISTINCT FROM NEW.before_canonical_path_id
                      OR prev.after_merged_into_id IS DISTINCT FROM NEW.before_merged_into_id)) THEN
                  RAISE EXCEPTION 'route change % does not continue the history of page %',
                    NEW.id, NEW.page_id USING ERRCODE = 'integrity_constraint_violation';
                END IF;

                SELECT last_route_change_id INTO applied FROM pages WHERE id = NEW.page_id;
                IF applied IS NULL OR applied < NEW.id THEN
                  RAISE EXCEPTION 'route change % was never applied to page %', NEW.id, NEW.page_id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;

              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION routing_check_change()"

    execute """
            CREATE CONSTRAINT TRIGGER route_changes_applied
              AFTER INSERT ON route_changes DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION routing_check_change();
            """,
            "DROP TRIGGER route_changes_applied ON route_changes"

    for table <- ~w(pages public_paths) do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_consistent
                AFTER INSERT OR UPDATE ON #{table} DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION routing_consistent();
              """,
              "DROP TRIGGER #{table}_consistent ON #{table}"
    end
  end
end
