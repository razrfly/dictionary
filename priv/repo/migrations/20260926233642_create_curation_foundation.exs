defmodule DevilsDictionary.Repo.Migrations.CreateCurationFoundation do
  @moduledoc """
  Curation persistence, slice 1 (#196, #201): configuration and profile
  identities, and the manual composition → review → publication path.

  Read `docs/curation/persistence-slice-1.md` first. Every constraint here is a
  row in its invariant map (C1–C8, K1–K10, R1–R7), and that document lists the
  reconciliations with the #196 draft. In short:

    * no model table and no model column (a configuration version is
      manual-only until a validated model exists);
    * profiles are identities without dossiers;
    * nothing is activated, approved or published by this migration;
    * nothing here writes a claim, a run or a page.

  Three kinds of enforcement:

    * **composite foreign keys** for ownership — a pointer, parent, review or
      revision must belong to the same configuration, composition or object;
    * **immutability triggers** — versions, rosters, items, decisions and
      receipts are never updated or deleted. The one exception: an item's
      reference to a source row may be nulled by `ON DELETE SET NULL`, so a
      mandatory source deletion is never blocked;
    * **deferred constraint triggers**, checked at COMMIT against the rows as
      committed then:
        - a pointer moves only with a receipt;
        - each receipt continues the one before it, so two racing writers
          cannot both win;
        - a roster, an arrangement or a scope cannot be extended after the
          transaction that created it.
  """
  use Ecto.Migration

  def change do
    require_postgresql_15()
    profiles()
    configurations()
    revision_ownership_indexes()
    compositions()
    triggers()
  end

  # Column-list referential actions (`ON DELETE SET NULL (column)`, R7) arrived
  # in PostgreSQL 15. On an older server the migration would fail halfway
  # through with a syntax error; it says why instead.
  defp require_postgresql_15 do
    execute """
            DO $$
            BEGIN
              IF current_setting('server_version_num')::int < 150000 THEN
                RAISE EXCEPTION 'the curation foundation needs PostgreSQL 15 or newer (column-list ON DELETE SET NULL); this server is %',
                  current_setting('server_version');
              END IF;
            END
            $$;
            """,
            "SELECT 1"
  end

  # ── profiles (#196 curator_profiles, curator_profile_versions) ──────────────

  defp profiles do
    create table(:curator_profiles) do
      add :slug, :text, null: false
      add :label, :text, null: false
      add :subject_label, :text, null: false
      add :state, :text, null: false, default: "proposed"
      add :bot_actor_id, references(:actors, on_delete: :restrict)
      add :admitted_by_actor_id, references(:actors, on_delete: :restrict)
      add :admitted_at, :utc_datetime_usec
      add :admission_reason, :text
      add :current_version_id, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:curator_profiles, [:slug])

    create unique_index(:curator_profiles, [:bot_actor_id],
             where: "bot_actor_id IS NOT NULL",
             name: :curator_profiles_bot_actor_index
           )

    create constraint(:curator_profiles, :curator_profiles_state,
             check: "state IN ('proposed', 'admitted', 'retired')"
           )

    # C6: an admitted profile is a sourced, human-admitted one. The sources and
    # the admitter's kind live in other rows, so a trigger checks them.
    create constraint(:curator_profiles, :curator_profiles_admission,
             check: """
             state <> 'admitted' OR (
               current_version_id IS NOT NULL AND bot_actor_id IS NOT NULL AND
               admitted_by_actor_id IS NOT NULL AND admitted_at IS NOT NULL AND
               admission_reason IS NOT NULL AND btrim(admission_reason) <> ''
             )
             """
           )

    create table(:curator_profile_versions) do
      add :profile_id, references(:curator_profiles, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :manifest_hash, :text, null: false
      add :dossier, :map, null: false, default: %{}
      add :source_refs, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :deceased_evidence_refs, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :template_version, :text, null: false
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :change_reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:curator_profile_versions, [:profile_id, :version])
    create unique_index(:curator_profile_versions, [:profile_id, :manifest_hash])
    create unique_index(:curator_profile_versions, [:id, :profile_id])

    create constraint(:curator_profile_versions, :curator_profile_versions_shape,
             check: "version >= 1 AND btrim(change_reason) <> ''"
           )

    execute """
            ALTER TABLE curator_profiles
              ADD CONSTRAINT curator_profiles_current_version_fkey
              FOREIGN KEY (current_version_id, id)
              REFERENCES curator_profile_versions (id, profile_id)
            """,
            "ALTER TABLE curator_profiles DROP CONSTRAINT IF EXISTS curator_profiles_current_version_fkey"
  end

  # ── configurations (#201) ─────────────────────────────────────────────────

  defp configurations do
    create table(:curation_configurations) do
      add :slug, :text, null: false
      add :name, :text, null: false
      add :ownership_kind, :text, null: false, default: "system"
      add :role, :text, null: false
      add :state, :text, null: false, default: "draft"
      add :current_version_id, :bigint
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:curation_configurations, [:slug])

    # C1: at most one *enabled* global default.
    create unique_index(:curation_configurations, [:role],
             where: "role = 'global_default' AND state = 'enabled'",
             name: :curation_configurations_one_enabled_global_default
           )

    create constraint(:curation_configurations, :curation_configurations_shape,
             check: """
             ownership_kind = 'system' AND
             role IN ('global_default', 'internal_test') AND
             state IN ('draft', 'enabled', 'disabled') AND
             (state = 'draft') = (current_version_id IS NULL)
             """
           )

    create table(:curation_configuration_versions) do
      add :configuration_id, references(:curation_configurations, on_delete: :restrict),
        null: false

      add :version, :integer, null: false
      add :manifest_hash, :text, null: false
      add :manifest, :map, null: false
      add :lead_policy, :text, null: false
      add :max_highlights, :integer, null: false, default: 3
      add :roster_hash, :text, null: false
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :change_reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:curation_configuration_versions, [:configuration_id, :version])
    create unique_index(:curation_configuration_versions, [:configuration_id, :manifest_hash])
    create unique_index(:curation_configuration_versions, [:id, :configuration_id])

    create constraint(:curation_configuration_versions, :curation_configuration_versions_shape,
             check: """
             version >= 1 AND max_highlights BETWEEN 0 AND 3 AND
             lead_policy IN ('bierce_first_v1') AND btrim(change_reason) <> ''
             """
           )

    # C2: the current version belongs to this configuration.
    execute """
            ALTER TABLE curation_configurations
              ADD CONSTRAINT curation_configurations_current_version_fkey
              FOREIGN KEY (current_version_id, id)
              REFERENCES curation_configuration_versions (id, configuration_id)
            """,
            "ALTER TABLE curation_configurations DROP CONSTRAINT IF EXISTS curation_configurations_current_version_fkey"

    create table(:curation_configuration_members) do
      add :configuration_version_id,
          references(:curation_configuration_versions, on_delete: :restrict),
          null: false

      add :profile_id, references(:curator_profiles, on_delete: :restrict), null: false
      add :profile_version_id, :bigint, null: false
      add :slot, :integer, null: false
      add :voting_weight, :integer, null: false, default: 1
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # C5: one profile and one slot per version; weight 1; the exact profile version.
    create unique_index(:curation_configuration_members, [:configuration_version_id, :profile_id])
    create unique_index(:curation_configuration_members, [:configuration_version_id, :slot])

    create constraint(:curation_configuration_members, :curation_configuration_members_shape,
             check: "slot >= 1 AND voting_weight = 1"
           )

    execute """
            ALTER TABLE curation_configuration_members
              ADD CONSTRAINT curation_configuration_members_profile_version_fkey
              FOREIGN KEY (profile_version_id, profile_id)
              REFERENCES curator_profile_versions (id, profile_id)
            """,
            "ALTER TABLE curation_configuration_members DROP CONSTRAINT IF EXISTS curation_configuration_members_profile_version_fkey"

    # C3: the only way a configuration's pointer or state moves.
    create table(:curation_configuration_activations) do
      add :configuration_id, references(:curation_configurations, on_delete: :restrict),
        null: false

      add :action, :text, null: false
      add :configuration_version_id, :bigint, null: false
      add :previous_version_id, :bigint
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :idempotency_key, :text, null: false
      add :committed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:curation_configuration_activations, [:idempotency_key])
    create index(:curation_configuration_activations, [:configuration_id, :id])

    create constraint(
             :curation_configuration_activations,
             :curation_configuration_activations_shape,
             check: "action IN ('activate', 'disable') AND btrim(reason) <> ''"
           )

    for column <- ~w(configuration_version_id previous_version_id) do
      execute """
              ALTER TABLE curation_configuration_activations
                ADD CONSTRAINT curation_configuration_activations_#{column}_fkey
                FOREIGN KEY (#{column}, configuration_id)
                REFERENCES curation_configuration_versions (id, configuration_id)
              """,
              "ALTER TABLE curation_configuration_activations DROP CONSTRAINT IF EXISTS curation_configuration_activations_#{column}_fkey"
    end
  end

  # ── compositions (#196) ───────────────────────────────────────────────────

  defp compositions do
    create table(:editorial_compositions) do
      add :curation_configuration_id,
          references(:curation_configurations, on_delete: :restrict),
          null: false

      add :scope_kind, :text, null: false
      add :language_tag, :text, null: false
      add :scope_signature, :text, null: false
      add :state, :text, null: false, default: "active"
      add :current_published_version_id, :bigint
      add :lock_version, :integer, null: false, default: 1
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    # K1: the identity is (scope kind, signature, language, configuration). The
    # configuration *version* is deliberately not part of it.
    create unique_index(
             :editorial_compositions,
             [:scope_kind, :scope_signature, :language_tag, :curation_configuration_id],
             where: "state = 'active'",
             name: :editorial_compositions_active_scope_index
           )

    create unique_index(:editorial_compositions, [:id, :curation_configuration_id])

    create constraint(:editorial_compositions, :editorial_compositions_shape,
             check: """
             scope_kind IN ('lexical_page', 'lexeme') AND state IN ('active', 'retired') AND
             btrim(language_tag) <> ''
             """
           )

    # A lexeme in a curated scope is not deleted from under it: the scope is
    # changed or retired first (K3). Lexemes hold no source text, so R7 is not
    # at stake here.
    create table(:editorial_composition_memberships) do
      add :composition_id, references(:editorial_compositions, on_delete: :restrict), null: false
      add :object_id, references(:objects, on_delete: :restrict), null: false
      add :role, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:editorial_composition_memberships, [:composition_id, :object_id, :role])
    create index(:editorial_composition_memberships, [:object_id])

    create constraint(:editorial_composition_memberships, :editorial_composition_memberships_role,
             check: "role IN ('lexeme')"
           )

    create table(:editorial_composition_scope_changes) do
      add :composition_id, references(:editorial_compositions, on_delete: :restrict), null: false
      add :previous_signature, :text
      add :scope_signature, :text, null: false
      add :members, :jsonb, null: false
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :changed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:editorial_composition_scope_changes, [:composition_id, :id])

    create constraint(
             :editorial_composition_scope_changes,
             :editorial_composition_scope_changes_reason,
             check: "btrim(reason) <> ''"
           )

    create table(:editorial_composition_versions) do
      add :composition_id, :bigint, null: false
      add :curation_configuration_id, :bigint, null: false
      add :configuration_version_id, :bigint, null: false
      add :version, :integer, null: false
      add :parent_version_id, :bigint
      add :origin, :text, null: false, default: "manual"
      add :change_reason, :text, null: false
      add :created_by_actor_id, references(:actors, on_delete: :restrict), null: false
      add :scope_signature, :text, null: false
      add :scope_members, :jsonb, null: false
      add :resolution, :map, null: false
      add :lead_policy, :text, null: false
      add :arrangement_hash, :text, null: false
      add :eligibility_fingerprint, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:editorial_composition_versions, [:composition_id, :version])

    create unique_index(:editorial_composition_versions, [
             :composition_id,
             :arrangement_hash,
             :eligibility_fingerprint
           ])

    create unique_index(:editorial_composition_versions, [:id, :composition_id])

    # K9: manual only in this slice. A first version has no parent; every later
    # one does.
    create constraint(:editorial_composition_versions, :editorial_composition_versions_shape,
             check: """
             version >= 1 AND origin = 'manual' AND btrim(change_reason) <> '' AND
             lead_policy IN ('bierce_first_v1') AND
             (version = 1) = (parent_version_id IS NULL)
             """
           )

    # K4: the same configuration and the same composition throughout.
    execute """
            ALTER TABLE editorial_composition_versions
              ADD CONSTRAINT editorial_composition_versions_composition_fkey
              FOREIGN KEY (composition_id, curation_configuration_id)
              REFERENCES editorial_compositions (id, curation_configuration_id),
              ADD CONSTRAINT editorial_composition_versions_configuration_version_fkey
              FOREIGN KEY (configuration_version_id, curation_configuration_id)
              REFERENCES curation_configuration_versions (id, configuration_id),
              ADD CONSTRAINT editorial_composition_versions_parent_fkey
              FOREIGN KEY (parent_version_id, composition_id)
              REFERENCES editorial_composition_versions (id, composition_id)
            """,
            """
            ALTER TABLE editorial_composition_versions
              DROP CONSTRAINT IF EXISTS editorial_composition_versions_composition_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_versions_configuration_version_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_versions_parent_fkey
            """

    execute """
            ALTER TABLE editorial_compositions
              ADD CONSTRAINT editorial_compositions_published_version_fkey
              FOREIGN KEY (current_published_version_id, id)
              REFERENCES editorial_composition_versions (id, composition_id)
            """,
            "ALTER TABLE editorial_compositions DROP CONSTRAINT IF EXISTS editorial_compositions_published_version_fkey"

    # Items store ids, hashes and locators, never source text (R7). Every
    # reference to a source row yields to that row's deletion by nulling
    # itself; the reader then withholds the item.
    create table(:editorial_composition_items) do
      add :composition_version_id,
          references(:editorial_composition_versions, on_delete: :restrict),
          null: false

      add :role, :text, null: false
      add :position, :integer, null: false
      add :item_kind, :text, null: false
      add :item_object_id, :bigint
      add :content_revision_id, :bigint
      add :sense_revision_id, :bigint
      add :source_record_revision_id, :bigint
      add :catalog_manifest, :text
      add :catalog_checksum, :text
      add :catalog_identity, :text
      add :locator, :text
      add :words_sha256, :text
      add :meaning_sense_revision_id, :bigint
      add :meaning_lexeme_id, references(:lexemes, column: :object_id, on_delete: :restrict)
      add :assertion_revision_id, :bigint
      add :selection_origin, :text, null: false, default: "manual"
      add :note, :text
      add :note_author_kind, :text
      add :note_author_label, :text
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # K6: one lead at position 1, highlights at 1–3, one row per slot.
    create unique_index(:editorial_composition_items, [:composition_version_id, :role, :position],
             name: :editorial_composition_items_slot_index
           )

    create constraint(:editorial_composition_items, :editorial_composition_items_shape,
             check: """
             role IN ('lead', 'highlight') AND
             item_kind IN ('content', 'sense_quotation', 'work') AND
             selection_origin = 'manual' AND
             (role <> 'lead' OR (position = 1 AND item_kind = 'content')) AND
             (role <> 'highlight' OR position BETWEEN 1 AND 3) AND
             (item_kind = 'content' OR content_revision_id IS NULL) AND
             (item_kind = 'sense_quotation' OR (sense_revision_id IS NULL AND locator IS NULL
                                                AND words_sha256 IS NULL)) AND
             (item_kind = 'work' OR (catalog_manifest IS NULL AND catalog_checksum IS NULL
                                     AND catalog_identity IS NULL AND source_record_revision_id IS NULL)) AND
             (item_kind <> 'sense_quotation' OR locator ~ '^quotation:[0-9]+$') AND
             ((meaning_sense_revision_id IS NOT NULL)::int + (meaning_lexeme_id IS NOT NULL)::int) <= 1 AND
             ((note IS NULL AND note_author_kind IS NULL AND note_author_label IS NULL) OR
              (btrim(note) <> '' AND note_author_kind IN ('human', 'model') AND
               btrim(note_author_label) <> ''))
             """
           )

    # K7 and R7: an exact revision belongs to its item's object, and every
    # source reference nulls only its own column when its target is deleted.
    execute """
            ALTER TABLE editorial_composition_items
              ADD CONSTRAINT editorial_composition_items_object_fkey
              FOREIGN KEY (item_object_id) REFERENCES objects (id) ON DELETE SET NULL,
              ADD CONSTRAINT editorial_composition_items_content_revision_fkey
              FOREIGN KEY (content_revision_id, item_object_id)
              REFERENCES content_revisions (id, content_id)
              ON DELETE SET NULL (content_revision_id),
              ADD CONSTRAINT editorial_composition_items_sense_revision_fkey
              FOREIGN KEY (sense_revision_id, item_object_id)
              REFERENCES sense_revisions (id, sense_id)
              ON DELETE SET NULL (sense_revision_id),
              ADD CONSTRAINT editorial_composition_items_source_record_revision_fkey
              FOREIGN KEY (source_record_revision_id)
              REFERENCES source_record_revisions (id) ON DELETE SET NULL,
              ADD CONSTRAINT editorial_composition_items_meaning_sense_revision_fkey
              FOREIGN KEY (meaning_sense_revision_id)
              REFERENCES sense_revisions (id) ON DELETE SET NULL,
              ADD CONSTRAINT editorial_composition_items_assertion_revision_fkey
              FOREIGN KEY (assertion_revision_id)
              REFERENCES assertion_revisions (id) ON DELETE SET NULL
            """,
            """
            ALTER TABLE editorial_composition_items
              DROP CONSTRAINT IF EXISTS editorial_composition_items_object_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_items_content_revision_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_items_sense_revision_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_items_source_record_revision_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_items_meaning_sense_revision_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_items_assertion_revision_fkey
            """

    create table(:editorial_composition_reviews) do
      add :composition_id, :bigint, null: false
      add :composition_version_id, :bigint, null: false
      add :reviewer_actor_id, references(:actors, on_delete: :restrict), null: false
      add :decision, :text, null: false
      add :reason, :text, null: false
      add :reviewed_eligibility_fingerprint, :text, null: false
      add :idempotency_key, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:editorial_composition_reviews, [:idempotency_key])
    create unique_index(:editorial_composition_reviews, [:id, :composition_version_id])
    create index(:editorial_composition_reviews, [:composition_version_id, :id])

    create constraint(:editorial_composition_reviews, :editorial_composition_reviews_shape,
             check: """
             decision IN ('accepted', 'rejected', 'withdrawn', 'needs_review') AND
             btrim(reason) <> ''
             """
           )

    execute """
            ALTER TABLE editorial_composition_reviews
              ADD CONSTRAINT editorial_composition_reviews_version_fkey
              FOREIGN KEY (composition_version_id, composition_id)
              REFERENCES editorial_composition_versions (id, composition_id)
            """,
            "ALTER TABLE editorial_composition_reviews DROP CONSTRAINT IF EXISTS editorial_composition_reviews_version_fkey"

    # R3, R4: the authoritative receipt, written in the pointer's transaction.
    create table(:editorial_composition_publications) do
      add :composition_id, references(:editorial_compositions, on_delete: :restrict), null: false
      add :action, :text, null: false
      add :previous_version_id, :bigint
      add :published_version_id, :bigint
      add :authorizing_review_id, :bigint
      add :actor_id, references(:actors, on_delete: :restrict), null: false
      add :reason, :text, null: false
      add :eligibility_fingerprint, :text
      add :idempotency_key, :text, null: false
      add :committed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:editorial_composition_publications, [:idempotency_key])
    create index(:editorial_composition_publications, [:composition_id, :id])

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_shape,
             check: """
             btrim(reason) <> '' AND (
               (action = 'publish' AND published_version_id IS NOT NULL AND
                authorizing_review_id IS NOT NULL AND eligibility_fingerprint IS NOT NULL) OR
               (action = 'withdraw' AND previous_version_id IS NOT NULL AND
                published_version_id IS NULL AND authorizing_review_id IS NULL AND
                eligibility_fingerprint IS NULL)
             )
             """
           )

    execute """
            ALTER TABLE editorial_composition_publications
              ADD CONSTRAINT editorial_composition_publications_previous_fkey
              FOREIGN KEY (previous_version_id, composition_id)
              REFERENCES editorial_composition_versions (id, composition_id),
              ADD CONSTRAINT editorial_composition_publications_published_fkey
              FOREIGN KEY (published_version_id, composition_id)
              REFERENCES editorial_composition_versions (id, composition_id),
              ADD CONSTRAINT editorial_composition_publications_review_fkey
              FOREIGN KEY (authorizing_review_id, published_version_id)
              REFERENCES editorial_composition_reviews (id, composition_version_id)
            """,
            """
            ALTER TABLE editorial_composition_publications
              DROP CONSTRAINT IF EXISTS editorial_composition_publications_previous_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_publications_published_fkey,
              DROP CONSTRAINT IF EXISTS editorial_composition_publications_review_fkey
            """
  end

  # The targets of K7's composite foreign keys. `id` is already unique; these
  # let an item name (revision, object) and have the database check the pair.
  defp revision_ownership_indexes do
    create unique_index(:content_revisions, [:id, :content_id],
             name: :content_revisions_id_content_index
           )

    create unique_index(:sense_revisions, [:id, :sense_id], name: :sense_revisions_id_sense_index)
  end

  # ── triggers ──────────────────────────────────────────────────────────────

  @immutable ~w(curator_profile_versions curation_configuration_versions
                curation_configuration_members curation_configuration_activations
                editorial_composition_scope_changes editorial_composition_versions
                editorial_composition_reviews editorial_composition_publications)

  defp triggers do
    immutability()
    human_actor_checks()
    insert_checks()
    commit_checks()
  end

  # C4, K5, R1, R3: history is appended, never edited.
  defp immutability do
    execute """
            CREATE FUNCTION curation_row_is_immutable() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION '% rows are immutable (% on id %)', TG_TABLE_NAME, TG_OP, OLD.id
                USING ERRCODE = 'integrity_constraint_violation';
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS curation_row_is_immutable() CASCADE"

    for table <- @immutable do
      execute """
              CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table}
                FOR EACH ROW EXECUTE FUNCTION curation_row_is_immutable();
              """,
              "DROP TRIGGER IF EXISTS #{table}_immutable ON #{table}"
    end

    # R7: an item never changes, except that a source reference may become
    # NULL when its target is deleted. Nothing else about the row may move, and
    # no reference may be set or repointed.
    execute """
            CREATE FUNCTION editorial_composition_items_guard() RETURNS trigger AS $$
            DECLARE
              refs text[] := ARRAY['item_object_id', 'content_revision_id', 'sense_revision_id',
                'source_record_revision_id', 'meaning_sense_revision_id', 'assertion_revision_id'];
              ref text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                RAISE EXCEPTION 'editorial_composition_items rows are immutable (DELETE on id %)', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF (to_jsonb(NEW) - refs) IS DISTINCT FROM (to_jsonb(OLD) - refs) THEN
                RAISE EXCEPTION 'editorial_composition_items rows are immutable (UPDATE on id %)', OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              FOREACH ref IN ARRAY refs LOOP
                IF to_jsonb(NEW) -> ref <> 'null'::jsonb AND
                   (to_jsonb(NEW) -> ref) IS DISTINCT FROM (to_jsonb(OLD) -> ref) THEN
                  RAISE EXCEPTION 'editorial_composition_items.% may only be nulled by a deletion (id %)', ref, OLD.id
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END LOOP;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_items_guard() CASCADE"

    execute """
            CREATE TRIGGER editorial_composition_items_guard BEFORE UPDATE OR DELETE
              ON editorial_composition_items
              FOR EACH ROW EXECUTE FUNCTION editorial_composition_items_guard();
            """,
            "DROP TRIGGER IF EXISTS editorial_composition_items_guard ON editorial_composition_items"
  end

  # C6, C8, K9, R1, R3: who may do what. A bot never authors, reviews,
  # activates or publishes, and only an account with the reviewer role
  # reviews, activates or publishes. Checked on insert, from the rows as they
  # stand then.
  defp human_actor_checks do
    execute """
            CREATE FUNCTION curation_actor_is(candidate bigint, want_reviewer boolean) RETURNS boolean AS $$
              SELECT EXISTS (
                SELECT 1 FROM actors a JOIN users u ON u.id = a.user_id
                 WHERE a.id = candidate AND a.actor_kind = 'user'
                   AND (NOT want_reviewer OR u.reviewer)
              );
            $$ LANGUAGE sql STABLE;
            """,
            "DROP FUNCTION IF EXISTS curation_actor_is(bigint, boolean) CASCADE"

    execute """
            CREATE FUNCTION curation_human_actor_guard() RETURNS trigger AS $$
            DECLARE
              candidate bigint := (to_jsonb(NEW) ->> TG_ARGV[0])::bigint;
              want_reviewer boolean := TG_ARGV[1]::boolean;
            BEGIN
              IF NOT curation_actor_is(candidate, want_reviewer) THEN
                RAISE EXCEPTION '%.% must be a human account%', TG_TABLE_NAME, TG_ARGV[0],
                  CASE WHEN want_reviewer THEN ' with the reviewer role' ELSE '' END
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS curation_human_actor_guard() CASCADE"

    for {table, column, reviewer} <- [
          {"curator_profile_versions", "created_by_actor_id", false},
          {"editorial_composition_versions", "created_by_actor_id", false},
          {"editorial_composition_scope_changes", "actor_id", false},
          {"editorial_composition_reviews", "reviewer_actor_id", true},
          {"editorial_composition_publications", "actor_id", true},
          {"curation_configuration_activations", "actor_id", true}
        ] do
      execute """
              CREATE TRIGGER #{table}_human_actor BEFORE INSERT ON #{table}
                FOR EACH ROW EXECUTE FUNCTION curation_human_actor_guard('#{column}', '#{reviewer}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_human_actor ON #{table}"
    end

    # C6: admission names a human reviewer, a bot principal, and a version
    # that cites its sources and the subject's death. Admission covers one
    # version: moving an admitted profile to another version is a new
    # admission.
    execute """
            CREATE FUNCTION curator_profiles_admission_guard() RETURNS trigger AS $$
            BEGIN
              IF NEW.state = 'admitted' THEN
                IF TG_OP = 'UPDATE' AND OLD.state = 'admitted'
                   AND NEW.current_version_id IS DISTINCT FROM OLD.current_version_id
                   AND NEW.admitted_at IS NOT DISTINCT FROM OLD.admitted_at THEN
                  RAISE EXCEPTION 'a new version of an admitted profile needs a new admission'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
                IF NOT curation_actor_is(NEW.admitted_by_actor_id, true) THEN
                  RAISE EXCEPTION 'a profile is admitted by a human reviewer'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
                IF NOT EXISTS (SELECT 1 FROM actors WHERE id = NEW.bot_actor_id AND actor_kind = 'bot') THEN
                  RAISE EXCEPTION 'an admitted profile acts through a bot actor'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
                IF NOT EXISTS (
                  SELECT 1 FROM curator_profile_versions v
                   WHERE v.id = NEW.current_version_id
                     AND jsonb_typeof(v.source_refs) = 'array' AND jsonb_array_length(v.source_refs) > 0
                     AND jsonb_typeof(v.deceased_evidence_refs) = 'array'
                     AND jsonb_array_length(v.deceased_evidence_refs) > 0
                ) THEN
                  RAISE EXCEPTION 'an admitted profile''s version cites its sources and deceased-status evidence'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS curator_profiles_admission_guard() CASCADE"

    execute """
            CREATE TRIGGER curator_profiles_admission_guard BEFORE INSERT OR UPDATE ON curator_profiles
              FOR EACH ROW EXECUTE FUNCTION curator_profiles_admission_guard();
            """,
            "DROP TRIGGER IF EXISTS curator_profiles_admission_guard ON curator_profiles"
  end

  defp insert_checks do
    # K6, K7, K8: what an item must carry when it is written. The check
    # constraint admits the NULLs a later deletion leaves behind, so presence
    # is checked here, at insert only.
    execute """
            CREATE FUNCTION editorial_composition_items_complete() RETURNS trigger AS $$
            BEGIN
              -- A work pinned from a committed catalog may have no registry
              -- object yet; everything else names the object it shows.
              IF NEW.item_object_id IS NULL AND
                 NOT (NEW.item_kind = 'work' AND NEW.catalog_manifest IS NOT NULL) THEN
                RAISE EXCEPTION 'an item names its registry object'
                  USING ERRCODE = 'check_violation';
              END IF;

              IF (NEW.meaning_sense_revision_id IS NULL) = (NEW.meaning_lexeme_id IS NULL) THEN
                RAISE EXCEPTION 'an item has exactly one intended meaning'
                  USING ERRCODE = 'check_violation';
              END IF;

              IF (NEW.item_kind = 'content' AND NEW.content_revision_id IS NULL)
                 OR (NEW.item_kind = 'sense_quotation' AND
                     (NEW.sense_revision_id IS NULL OR NEW.words_sha256 IS NULL))
                 OR (NEW.item_kind = 'work' AND
                     (NEW.source_record_revision_id IS NULL) =
                     (NEW.catalog_manifest IS NULL OR NEW.catalog_checksum IS NULL
                      OR NEW.catalog_identity IS NULL))
              THEN
                RAISE EXCEPTION 'a % item names exactly one exact revision', NEW.item_kind
                  USING ERRCODE = 'check_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_items_complete() CASCADE"

    execute """
            CREATE TRIGGER editorial_composition_items_complete BEFORE INSERT
              ON editorial_composition_items
              FOR EACH ROW EXECUTE FUNCTION editorial_composition_items_complete();
            """,
            "DROP TRIGGER IF EXISTS editorial_composition_items_complete ON editorial_composition_items"

    # K2, K4: a version is made against the composition's scope as it stands,
    # and only while the composition is active.
    execute """
            CREATE FUNCTION editorial_composition_versions_scope_guard() RETURNS trigger AS $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM editorial_compositions c
                 WHERE c.id = NEW.composition_id AND c.state = 'active'
                   AND c.scope_signature = NEW.scope_signature
              ) THEN
                RAISE EXCEPTION 'a version is made against its active composition''s current scope'
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_versions_scope_guard() CASCADE"

    execute """
            CREATE TRIGGER editorial_composition_versions_scope_guard BEFORE INSERT
              ON editorial_composition_versions
              FOR EACH ROW EXECUTE FUNCTION editorial_composition_versions_scope_guard();
            """,
            "DROP TRIGGER IF EXISTS editorial_composition_versions_scope_guard ON editorial_composition_versions"

    # R1, R4: an acceptance is of the version's own eligibility.
    execute """
            CREATE FUNCTION editorial_composition_reviews_guard() RETURNS trigger AS $$
            BEGIN
              IF NEW.decision = 'accepted' AND NOT EXISTS (
                SELECT 1 FROM editorial_composition_versions v
                 WHERE v.id = NEW.composition_version_id
                   AND v.eligibility_fingerprint = NEW.reviewed_eligibility_fingerprint
              ) THEN
                RAISE EXCEPTION 'an acceptance reviews the version''s own eligibility fingerprint'
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_reviews_guard() CASCADE"

    execute """
            CREATE TRIGGER editorial_composition_reviews_guard BEFORE INSERT
              ON editorial_composition_reviews
              FOR EACH ROW EXECUTE FUNCTION editorial_composition_reviews_guard();
            """,
            "DROP TRIGGER IF EXISTS editorial_composition_reviews_guard ON editorial_composition_reviews"

    # R3: a publication is authorized by the *latest* decision on that very
    # version, which is an acceptance of the fingerprint being published.
    execute """
            CREATE FUNCTION editorial_composition_publications_review_guard() RETURNS trigger AS $$
            DECLARE
              latest record;
            BEGIN
              IF NEW.action = 'publish' THEN
                SELECT r.id, r.decision, r.reviewed_eligibility_fingerprint INTO latest
                  FROM editorial_composition_reviews r
                 WHERE r.composition_version_id = NEW.published_version_id
                 ORDER BY r.id DESC LIMIT 1;

                IF latest.id IS DISTINCT FROM NEW.authorizing_review_id
                   OR latest.decision IS DISTINCT FROM 'accepted'
                   OR latest.reviewed_eligibility_fingerprint IS DISTINCT FROM NEW.eligibility_fingerprint THEN
                  RAISE EXCEPTION 'a publication is authorized by the latest review of its version, an acceptance of this fingerprint'
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_publications_review_guard() CASCADE"

    execute """
            CREATE TRIGGER editorial_composition_publications_review_guard BEFORE INSERT
              ON editorial_composition_publications
              FOR EACH ROW EXECUTE FUNCTION editorial_composition_publications_review_guard();
            """,
            "DROP TRIGGER IF EXISTS editorial_composition_publications_review_guard ON editorial_composition_publications"
  end

  # Checked at COMMIT, from the rows as they then stand. Each function takes,
  # as its trigger argument, the column of the triggering row that names the
  # parent it checks: a PL/pgSQL expression cannot name a column the row's
  # table lacks, even in a branch it never takes.
  defp commit_checks do
    # C3: a configuration's pointer and state are its latest activation's, and
    # each activation continues from the one before it.
    execute """
            CREATE FUNCTION curation_configuration_receipt_check() RETURNS trigger AS $$
            DECLARE
              parent bigint := (to_jsonb(NEW) ->> TG_ARGV[0])::bigint;
              c record;
              latest record;
              prior bigint;
            BEGIN
              SELECT state, current_version_id INTO c FROM curation_configurations WHERE id = parent;

              SELECT action, configuration_version_id, previous_version_id INTO latest
                FROM curation_configuration_activations
               WHERE configuration_id = parent ORDER BY id DESC LIMIT 1;

              SELECT configuration_version_id INTO prior
                FROM curation_configuration_activations
               WHERE configuration_id = parent ORDER BY id DESC OFFSET 1 LIMIT 1;

              IF latest.action IS NULL THEN
                IF c.current_version_id IS NOT NULL OR c.state <> 'draft' THEN
                  RAISE EXCEPTION 'configuration % left draft without an activation receipt', parent
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              ELSIF c.current_version_id IS DISTINCT FROM latest.configuration_version_id
                    OR c.state IS DISTINCT FROM
                       (CASE latest.action WHEN 'activate' THEN 'enabled' ELSE 'disabled' END)
                    OR latest.previous_version_id IS DISTINCT FROM prior THEN
                RAISE EXCEPTION 'configuration % does not match its latest activation receipt', parent
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS curation_configuration_receipt_check() CASCADE"

    for {table, column, events} <- [
          {"curation_configurations", "id", "INSERT OR UPDATE"},
          {"curation_configuration_activations", "configuration_id", "INSERT"}
        ] do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_receipt AFTER #{events} ON #{table}
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION curation_configuration_receipt_check('#{column}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_receipt ON #{table}"
    end

    # R3, R5: a composition's pointer is its latest publication receipt's, and
    # each receipt continues from the one before it. Two writers that both read
    # the same pointer cannot both commit: whichever commits second finds that
    # its receipt no longer continues the chain.
    execute """
            CREATE FUNCTION editorial_composition_receipt_check() RETURNS trigger AS $$
            DECLARE
              parent bigint := (to_jsonb(NEW) ->> TG_ARGV[0])::bigint;
              pointer bigint;
              latest record;
              prior bigint;
            BEGIN
              SELECT current_published_version_id INTO pointer FROM editorial_compositions WHERE id = parent;

              SELECT id, published_version_id, previous_version_id INTO latest
                FROM editorial_composition_publications
               WHERE composition_id = parent ORDER BY id DESC LIMIT 1;

              SELECT published_version_id INTO prior
                FROM editorial_composition_publications
               WHERE composition_id = parent ORDER BY id DESC OFFSET 1 LIMIT 1;

              IF pointer IS DISTINCT FROM latest.published_version_id
                 OR (latest.id IS NOT NULL AND latest.previous_version_id IS DISTINCT FROM prior) THEN
                RAISE EXCEPTION 'composition % does not match its latest publication receipt', parent
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_composition_receipt_check() CASCADE"

    for {table, column, events} <- [
          {"editorial_compositions", "id", "INSERT OR UPDATE"},
          {"editorial_composition_publications", "composition_id", "INSERT"}
        ] do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_receipt AFTER #{events} ON #{table}
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION editorial_composition_receipt_check('#{column}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_receipt ON #{table}"
    end

    # K2, K3: a composition's signature is its members', it is the latest
    # scope-change receipt's, each receipt continues the one before it, and a
    # single-lexeme scope has exactly one member.
    execute """
            CREATE FUNCTION editorial_scope_signature(composition bigint) RETURNS text AS $$
              SELECT encode(sha256(convert_to(COALESCE(string_agg(
                       m.role || ':' || m.object_id, ',' ORDER BY m.role, m.object_id), ''), 'UTF8')), 'hex')
                FROM editorial_composition_memberships m
               WHERE m.composition_id = composition;
            $$ LANGUAGE sql STABLE;
            """,
            "DROP FUNCTION IF EXISTS editorial_scope_signature(bigint) CASCADE"

    execute """
            CREATE FUNCTION editorial_scope_check() RETURNS trigger AS $$
            DECLARE
              parent bigint := (COALESCE(to_jsonb(NEW), to_jsonb(OLD)) ->> TG_ARGV[0])::bigint;
              c record;
              latest record;
              prior text;
              members integer;
            BEGIN
              SELECT scope_kind, scope_signature INTO c FROM editorial_compositions WHERE id = parent;
              IF NOT FOUND THEN RETURN NULL; END IF;

              SELECT count(*) INTO members FROM editorial_composition_memberships WHERE composition_id = parent;

              SELECT scope_signature, previous_signature INTO latest
                FROM editorial_composition_scope_changes
               WHERE composition_id = parent ORDER BY id DESC LIMIT 1;

              SELECT scope_signature INTO prior
                FROM editorial_composition_scope_changes
               WHERE composition_id = parent ORDER BY id DESC OFFSET 1 LIMIT 1;

              IF c.scope_signature IS DISTINCT FROM editorial_scope_signature(parent)
                 OR c.scope_signature IS DISTINCT FROM latest.scope_signature
                 OR latest.previous_signature IS DISTINCT FROM prior
                 OR members = 0
                 OR (c.scope_kind = 'lexeme' AND members <> 1) THEN
                RAISE EXCEPTION 'composition % scope does not match its members and latest scope-change receipt', parent
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_scope_check() CASCADE"

    for {table, column, events} <- [
          {"editorial_compositions", "id", "INSERT OR UPDATE"},
          {"editorial_composition_memberships", "composition_id", "INSERT OR DELETE"},
          {"editorial_composition_scope_changes", "composition_id", "INSERT"}
        ] do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_scope AFTER #{events} ON #{table}
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION editorial_scope_check('#{column}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_scope ON #{table}"
    end

    # C4: a roster is exactly the members its version was created with.
    execute """
            CREATE FUNCTION curation_roster_hash(version_id bigint) RETURNS text AS $$
              SELECT encode(sha256(convert_to(COALESCE(string_agg(
                       m.slot || ':' || m.profile_id || ':' || m.profile_version_id || ':' || m.voting_weight,
                       ',' ORDER BY m.slot), ''), 'UTF8')), 'hex')
                FROM curation_configuration_members m
               WHERE m.configuration_version_id = version_id;
            $$ LANGUAGE sql STABLE;
            """,
            "DROP FUNCTION IF EXISTS curation_roster_hash(bigint) CASCADE"

    execute """
            CREATE FUNCTION curation_roster_check() RETURNS trigger AS $$
            DECLARE
              version_id bigint := (to_jsonb(NEW) ->> TG_ARGV[0])::bigint;
            BEGIN
              IF (SELECT roster_hash FROM curation_configuration_versions WHERE id = version_id)
                 IS DISTINCT FROM curation_roster_hash(version_id) THEN
                RAISE EXCEPTION 'configuration version % roster differs from the roster it was created with', version_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS curation_roster_check() CASCADE"

    for {table, column} <- [
          {"curation_configuration_versions", "id"},
          {"curation_configuration_members", "configuration_version_id"}
        ] do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_roster AFTER INSERT ON #{table}
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION curation_roster_check('#{column}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_roster ON #{table}"
    end

    # K5: an arrangement is exactly the items its version was created with.
    # Each field is length-prefixed (NULL is `~`), so no note or locator can
    # make two different arrangements hash alike.
    # `DevilsDictionary.Curation.Digest` computes the same digest.
    execute """
            CREATE FUNCTION curation_field(value text) RETURNS text AS $$
              SELECT CASE WHEN value IS NULL THEN '~' ELSE octet_length(value) || ':' || value END;
            $$ LANGUAGE sql IMMUTABLE;
            """,
            "DROP FUNCTION IF EXISTS curation_field(text) CASCADE"

    execute """
            CREATE FUNCTION editorial_arrangement_hash(version_id bigint) RETURNS text AS $$
              SELECT encode(sha256(convert_to(COALESCE(string_agg(
                       curation_field(i.role) || curation_field(i.position::text) ||
                       curation_field(i.item_kind) || curation_field(i.item_object_id::text) ||
                       curation_field(i.content_revision_id::text) || curation_field(i.sense_revision_id::text) ||
                       curation_field(i.source_record_revision_id::text) || curation_field(i.catalog_manifest) ||
                       curation_field(i.catalog_checksum) || curation_field(i.catalog_identity) ||
                       curation_field(i.locator) || curation_field(i.words_sha256) ||
                       curation_field(i.meaning_sense_revision_id::text) || curation_field(i.meaning_lexeme_id::text) ||
                       curation_field(i.assertion_revision_id::text) || curation_field(i.selection_origin) ||
                       curation_field(i.note) || curation_field(i.note_author_kind) ||
                       curation_field(i.note_author_label),
                       '' ORDER BY i.role, i.position), ''), 'UTF8')), 'hex')
                FROM editorial_composition_items i
               WHERE i.composition_version_id = version_id;
            $$ LANGUAGE sql STABLE;
            """,
            "DROP FUNCTION IF EXISTS editorial_arrangement_hash(bigint) CASCADE"

    execute """
            CREATE FUNCTION editorial_arrangement_check() RETURNS trigger AS $$
            DECLARE
              version_id bigint := (to_jsonb(NEW) ->> TG_ARGV[0])::bigint;
            BEGIN
              IF (SELECT arrangement_hash FROM editorial_composition_versions WHERE id = version_id)
                 IS DISTINCT FROM editorial_arrangement_hash(version_id) THEN
                RAISE EXCEPTION 'composition version % arrangement differs from the one it was created with', version_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS editorial_arrangement_check() CASCADE"

    for {table, column} <- [
          {"editorial_composition_versions", "id"},
          {"editorial_composition_items", "composition_version_id"}
        ] do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_arrangement AFTER INSERT ON #{table}
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION editorial_arrangement_check('#{column}');
              """,
              "DROP TRIGGER IF EXISTS #{table}_arrangement ON #{table}"
    end
  end
end
