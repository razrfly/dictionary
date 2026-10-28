defmodule DevilsDictionary.Repo.Migrations.CreateCurationProposals do
  @moduledoc """
  The proposal path (#264 §5): the first bot proposes into the owner's
  screen through the same record the owner uses.

  **Additive only (#264 R19).** New nullable or defaulted columns, one new
  table, CHECKs widened, one unique index made partial, and trigger
  functions replaced so that every row the code before this migration
  writes is accepted exactly as before:

    * versions gain `attempt_id`; `origin` may be `model`, and only with an
      attempt; the dedup index covers manual versions only; the author
      guard keeps the human-account rule for manual versions word for word
      and adds the bound bot's rule for model ones;
    * items gain `copied_from_item_id`; `selection_origin` may be `model`;
      the completeness trigger keeps the human-note rule for uncopied
      manual items and adds the copy and model-note rules;
    * reviews refuse to accept, and publications to publish, a model
      version (R13);
    * compositions gain the D8 marks (`mode`, `kept_items`), set only by
      human reviewers;
    * refresh rows gain `review_unit_reserved_at`, nullable `last_deferred_at`
      and three outcomes;
    * configurations gain the editor switch, set only by a human reviewer
      with a reason, to null or the current version;
    * profiles gain `kind`, fixed at insert, with the generic editor's
      narrow admission beside the persona rule, which is unchanged;
    * `curation_proposals`, the proposal lifecycle (R10).

  The data the live steps need (the generic editor's source, bot actor,
  profile and version; the editor's configuration version) is written by
  `mix dd.curation.editor`, never here.

  **Rollback (R19.3).** `down` refuses to run once any model version,
  proposal or copied item exists: the code before this migration cannot
  read them.
  """
  use Ecto.Migration

  def up do
    versions_up()
    items_up()
    reviews_and_publications_up()
    compositions_up()
    refresh_states_up()
    configurations_up()
    profiles_up()
    proposals_up()
  end

  # The refusal `down` starts with (R19.3): the code before this migration
  # cannot read a model version, a proposal or a copied item, so none may
  # exist when it is rolled back.
  @down_guard """
  DO $$
  BEGIN
    IF EXISTS (SELECT 1 FROM editorial_composition_versions WHERE origin <> 'manual')
       OR EXISTS (SELECT 1 FROM curation_proposals)
       OR EXISTS (SELECT 1 FROM editorial_composition_items
                   WHERE copied_from_item_id IS NOT NULL OR selection_origin <> 'manual') THEN
      RAISE EXCEPTION 'create_curation_proposals cannot be rolled back: model versions, proposals or copied items exist (#264 R19.3)'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END
  $$;
  """

  @doc "The statement `down/0` runs first, which refuses the rollback once a model row exists."
  def down_guard, do: @down_guard

  def down do
    execute(@down_guard)

    proposals_down()
    profiles_down()
    configurations_down()
    refresh_states_down()
    compositions_down()
    reviews_and_publications_down()
    items_down()
    versions_down()
  end

  # ── editorial_composition_versions ─────────────────────────────────────────

  defp versions_up do
    alter table(:editorial_composition_versions) do
      add :attempt_id, references(:inference_attempts, on_delete: :restrict)
    end

    create unique_index(:editorial_composition_versions, [:attempt_id],
             where: "attempt_id IS NOT NULL",
             name: :editorial_composition_versions_attempt_index
           )

    execute(
      "ALTER TABLE editorial_composition_versions DROP CONSTRAINT editorial_composition_versions_shape"
    )

    execute("""
    ALTER TABLE editorial_composition_versions ADD CONSTRAINT editorial_composition_versions_shape CHECK (
      version >= 1 AND origin IN ('manual', 'model') AND btrim(change_reason) <> ''
      AND lead_policy = 'bierce_first_v1'
      AND ((version = 1) = (parent_version_id IS NULL))
      AND ((origin = 'model') = (attempt_id IS NOT NULL))
    )
    """)

    execute("DROP INDEX editorial_composition_versions_dedup_index")

    execute("""
    CREATE UNIQUE INDEX editorial_composition_versions_dedup_index
      ON editorial_composition_versions
      (composition_id, configuration_version_id, arrangement_hash, eligibility_fingerprint)
      WHERE origin = 'manual'
    """)

    execute(
      "DROP TRIGGER editorial_composition_versions_human_actor ON editorial_composition_versions"
    )

    execute("""
    CREATE FUNCTION editorial_composition_versions_author_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      editor jsonb;
    BEGIN
      IF NEW.origin = 'model' THEN
        SELECT v.manifest -> 'editor' INTO editor
          FROM curation_configuration_versions v WHERE v.id = NEW.configuration_version_id;

        IF editor IS NULL OR jsonb_typeof(editor) <> 'object' THEN
          RAISE EXCEPTION 'a model version is made under a configuration version that binds an editor'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM curator_profiles p
           WHERE p.id = (editor ->> 'profile_id')::bigint
             AND p.kind = 'generic_editor' AND p.state = 'admitted'
             AND p.current_version_id = (editor ->> 'profile_version_id')::bigint
             AND p.bot_actor_id = NEW.created_by_actor_id
             AND (editor ->> 'bot_actor_id')::bigint = NEW.created_by_actor_id
        ) THEN
          RAISE EXCEPTION 'a model version is written by the bot actor of the admitted generic editor its configuration version binds'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM inference_attempts a
           WHERE a.id = NEW.attempt_id AND a.state = 'completed' AND a.outcome = 'accepted'
             AND a.requested_by_actor_id = NEW.created_by_actor_id
             AND a.model_config_id = (editor ->> 'model_config_id')::bigint
        ) THEN
          RAISE EXCEPTION 'a model version comes from a completed, accepted attempt of its bot under the bound model config'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      ELSIF NOT curation_actor_is(NEW.created_by_actor_id, false) THEN
        RAISE EXCEPTION '%.% must be a human account', TG_TABLE_NAME, 'created_by_actor_id'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER editorial_composition_versions_author_guard
      BEFORE INSERT ON editorial_composition_versions
      FOR EACH ROW EXECUTE FUNCTION editorial_composition_versions_author_guard()
    """)
  end

  defp versions_down do
    execute(
      "DROP TRIGGER editorial_composition_versions_author_guard ON editorial_composition_versions"
    )

    execute("DROP FUNCTION editorial_composition_versions_author_guard()")

    execute("""
    CREATE TRIGGER editorial_composition_versions_human_actor
      BEFORE INSERT ON editorial_composition_versions
      FOR EACH ROW EXECUTE FUNCTION curation_human_actor_guard('created_by_actor_id', 'false')
    """)

    execute("DROP INDEX editorial_composition_versions_dedup_index")

    execute("""
    CREATE UNIQUE INDEX editorial_composition_versions_dedup_index
      ON editorial_composition_versions
      (composition_id, configuration_version_id, arrangement_hash, eligibility_fingerprint)
    """)

    execute(
      "ALTER TABLE editorial_composition_versions DROP CONSTRAINT editorial_composition_versions_shape"
    )

    execute("""
    ALTER TABLE editorial_composition_versions ADD CONSTRAINT editorial_composition_versions_shape CHECK (
      version >= 1 AND origin = 'manual' AND btrim(change_reason) <> ''
      AND lead_policy = 'bierce_first_v1'
      AND ((version = 1) = (parent_version_id IS NULL))
    )
    """)

    drop index(:editorial_composition_versions, [:attempt_id],
           name: :editorial_composition_versions_attempt_index
         )

    alter table(:editorial_composition_versions) do
      remove :attempt_id
    end
  end

  # ── editorial_composition_items ────────────────────────────────────────────

  @item_shape_head """
    role IN ('lead', 'highlight')
    AND item_kind IN ('content', 'sense_quotation', 'work', 'exemplar')
  """

  @item_shape_tail """
    AND (role <> 'lead' OR (position = 1 AND item_kind = 'content'))
    AND (role <> 'highlight' OR (position >= 1 AND position <= 3))
    AND (item_kind <> 'exemplar' OR role = 'highlight')
    AND (item_kind IN ('content', 'exemplar') OR content_revision_id IS NULL)
    AND (item_kind = 'sense_quotation' OR (sense_revision_id IS NULL AND locator IS NULL AND words_sha256 IS NULL))
    AND (item_kind = 'work' OR (catalog_manifest IS NULL AND catalog_checksum IS NULL
         AND catalog_identity IS NULL AND source_record_revision_id IS NULL))
    AND (item_kind <> 'sense_quotation' OR locator ~ '^quotation:[0-9]+$')
    AND ((meaning_sense_revision_id IS NOT NULL)::int + (meaning_lexeme_id IS NOT NULL)::int <= 1)
    AND ((note IS NULL AND note_author_kind IS NULL AND note_author_label IS NULL)
         OR (btrim(note) <> '' AND note_author_kind IN ('human', 'model') AND btrim(note_author_label) <> ''))
  """

  # The structural checks of `editorial_composition_items_complete()`, word
  # for word: only the note rules after them differ between up and down.
  @items_complete_head """
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

    IF NEW.item_kind = 'exemplar' THEN
      IF NEW.assertion_revision_id IS NULL THEN
        RAISE EXCEPTION 'an exemplar item names the claim it shows'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM assertion_revisions r JOIN predicates p ON p.id = r.predicate_id
         WHERE r.id = NEW.assertion_revision_id AND p.key = 'illustrates'
      ) THEN
        RAISE EXCEPTION 'an exemplar item shows an illustrates claim'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      subject_kind := (SELECT o.kind FROM objects o WHERE o.id = NEW.item_object_id);

      IF subject_kind = 'content' AND NEW.content_revision_id IS NULL THEN
        RAISE EXCEPTION 'an exemplar of a passage or quotation pins its words'
          USING ERRCODE = 'check_violation';
      END IF;

      IF subject_kind IS DISTINCT FROM 'content' AND NEW.content_revision_id IS NOT NULL THEN
        RAISE EXCEPTION 'an exemplar of an entity pins no words'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

    NEW.required_references := curation_item_references(NEW);
  """

  defp items_up do
    alter table(:editorial_composition_items) do
      add :copied_from_item_id, references(:editorial_composition_items, on_delete: :restrict)
    end

    execute(
      "ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape"
    )

    execute("""
    ALTER TABLE editorial_composition_items ADD CONSTRAINT editorial_composition_items_shape CHECK (
    #{@item_shape_head}
      AND selection_origin IN ('manual', 'model')
    #{@item_shape_tail}
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      author record;
      subject_kind text;
      version record;
      source record;
    BEGIN
    #{@items_complete_head}

      SELECT v.origin, v.created_by_actor_id, v.composition_id INTO version
        FROM editorial_composition_versions v WHERE v.id = NEW.composition_version_id;

      -- A verified copy (#264 R8.2, R11): the same reference, meaning, note,
      -- note author and selection origin as an item of a version of the same
      -- composition. The author and label checks held for the source.
      IF NEW.copied_from_item_id IS NOT NULL THEN
        SELECT i.*, v.composition_id AS source_composition_id INTO source
          FROM editorial_composition_items i
          JOIN editorial_composition_versions v ON v.id = i.composition_version_id
         WHERE i.id = NEW.copied_from_item_id;

        IF source.id IS NULL OR source.source_composition_id IS DISTINCT FROM version.composition_id THEN
          RAISE EXCEPTION 'a copied item copies an item of its own composition'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.item_kind IS DISTINCT FROM source.item_kind
           OR NEW.item_object_id IS DISTINCT FROM source.item_object_id
           OR NEW.content_revision_id IS DISTINCT FROM source.content_revision_id
           OR NEW.sense_revision_id IS DISTINCT FROM source.sense_revision_id
           OR NEW.source_record_revision_id IS DISTINCT FROM source.source_record_revision_id
           OR NEW.catalog_manifest IS DISTINCT FROM source.catalog_manifest
           OR NEW.catalog_checksum IS DISTINCT FROM source.catalog_checksum
           OR NEW.catalog_identity IS DISTINCT FROM source.catalog_identity
           OR NEW.locator IS DISTINCT FROM source.locator
           OR NEW.words_sha256 IS DISTINCT FROM source.words_sha256
           OR NEW.meaning_sense_revision_id IS DISTINCT FROM source.meaning_sense_revision_id
           OR NEW.meaning_lexeme_id IS DISTINCT FROM source.meaning_lexeme_id
           OR NEW.assertion_revision_id IS DISTINCT FROM source.assertion_revision_id
           OR NEW.note IS DISTINCT FROM source.note
           OR NEW.note_author_kind IS DISTINCT FROM source.note_author_kind
           OR NEW.note_author_label IS DISTINCT FROM source.note_author_label
           OR NEW.note_author_actor_id IS DISTINCT FROM source.note_author_actor_id
           OR NEW.selection_origin IS DISTINCT FROM source.selection_origin THEN
          RAISE EXCEPTION 'a copied item is identical to the item it copies'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        RETURN NEW;
      END IF;

      IF NEW.selection_origin = 'model' AND version.origin IS DISTINCT FROM 'model' THEN
        RAISE EXCEPTION 'a model-selected item is written only in a model version'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NEW.note IS NULL THEN
        IF NEW.note_author_actor_id IS NOT NULL THEN
          RAISE EXCEPTION 'an item without a note has no note author'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        SELECT a.id, a.actor_kind, COALESCE(a.label, 'Account #' || a.id) AS label INTO author
          FROM actors a WHERE a.id = NEW.note_author_actor_id;

        IF author.id IS NULL THEN
          RAISE EXCEPTION 'a note names the actor who wrote it'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_kind = 'human' AND (author.actor_kind <> 'user' OR author.id IS DISTINCT FROM
           version.created_by_actor_id) THEN
          RAISE EXCEPTION 'a human note is written by its version''s author'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_kind = 'model' AND author.actor_kind <> 'bot' THEN
          RAISE EXCEPTION 'a model note is written by a bot actor'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_kind = 'model' AND (version.origin IS DISTINCT FROM 'model'
           OR author.id IS DISTINCT FROM version.created_by_actor_id) THEN
          RAISE EXCEPTION 'a model note is written only in a model version, by its bot author'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_label IS DISTINCT FROM author.label THEN
          RAISE EXCEPTION 'a note is attributed under its author''s own label'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$
    """)
  end

  defp items_down do
    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      author record;
      subject_kind text;
    BEGIN
    #{@items_complete_head}

      IF NEW.note IS NULL THEN
        IF NEW.note_author_actor_id IS NOT NULL THEN
          RAISE EXCEPTION 'an item without a note has no note author'
            USING ERRCODE = 'check_violation';
        END IF;
      ELSE
        SELECT a.id, a.actor_kind, COALESCE(a.label, 'Account #' || a.id) AS label INTO author
          FROM actors a WHERE a.id = NEW.note_author_actor_id;

        IF author.id IS NULL THEN
          RAISE EXCEPTION 'a note names the actor who wrote it'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_kind = 'human' AND (author.actor_kind <> 'user' OR author.id IS DISTINCT FROM
           (SELECT created_by_actor_id FROM editorial_composition_versions WHERE id = NEW.composition_version_id)) THEN
          RAISE EXCEPTION 'a human note is written by its version''s author'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_kind = 'model' AND author.actor_kind <> 'bot' THEN
          RAISE EXCEPTION 'a model note is written by a bot actor'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF NEW.note_author_label IS DISTINCT FROM author.label THEN
          RAISE EXCEPTION 'a note is attributed under its author''s own label'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute(
      "ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape"
    )

    execute("""
    ALTER TABLE editorial_composition_items ADD CONSTRAINT editorial_composition_items_shape CHECK (
    #{@item_shape_head}
      AND selection_origin = 'manual'
    #{@item_shape_tail}
    )
    """)

    alter table(:editorial_composition_items) do
      remove :copied_from_item_id
    end
  end

  # ── reviews and publications (R13) ─────────────────────────────────────────

  @reviews_guard_body """
    IF NEW.decision = 'accepted' AND NOT EXISTS (
      SELECT 1 FROM editorial_composition_versions v
       WHERE v.id = NEW.composition_version_id
         AND v.eligibility_fingerprint = NEW.reviewed_eligibility_fingerprint
    ) THEN
      RAISE EXCEPTION 'an acceptance reviews the version''s own eligibility fingerprint'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  """

  @authority_head """
    IF NEW.authority_kind IS DISTINCT FROM 'operator' THEN
      RAISE EXCEPTION 'publication authority % is not available', NEW.authority_kind
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF NOT curation_actor_is(NEW.actor_id, true) THEN
      RAISE EXCEPTION 'an operator publication is made by a human account with the reviewer role'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

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
  """

  defp reviews_and_publications_up do
    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_reviews_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
    #{@reviews_guard_body}
      IF NEW.decision = 'accepted' AND EXISTS (
        SELECT 1 FROM editorial_composition_versions v
         WHERE v.id = NEW.composition_version_id AND v.origin <> 'manual'
      ) THEN
        RAISE EXCEPTION 'a model version is never accepted: it is taken into a manual version'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_publications_authority() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      latest record;
    BEGIN
    #{@authority_head}

        IF NOT EXISTS (
          SELECT 1 FROM editorial_composition_versions v
           WHERE v.id = NEW.published_version_id AND v.origin = 'manual'
        ) THEN
          RAISE EXCEPTION 'a model version is never published: it is taken into a manual version'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$
    """)
  end

  defp reviews_and_publications_down do
    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_reviews_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
    #{@reviews_guard_body}
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION editorial_composition_publications_authority() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      latest record;
    BEGIN
    #{@authority_head}
      END IF;

      RETURN NEW;
    END;
    $$
    """)
  end

  # ── editorial_compositions: the D8 marks (R15) ─────────────────────────────

  defp compositions_up do
    alter table(:editorial_compositions) do
      add :mode, :text, null: false, default: "open"
      add :mode_set_by_actor_id, references(:actors, on_delete: :restrict)
      add :mode_set_at, :utc_datetime_usec
      add :kept_items, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    create constraint(:editorial_compositions, :editorial_compositions_marks,
             check: "mode IN ('open', 'mine') AND jsonb_typeof(kept_items) = 'array'"
           )

    execute("""
    CREATE FUNCTION editorial_compositions_marks_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      element jsonb;
    BEGIN
      IF NEW.mode IS DISTINCT FROM OLD.mode
         OR NEW.mode_set_by_actor_id IS DISTINCT FROM OLD.mode_set_by_actor_id
         OR NEW.mode_set_at IS DISTINCT FROM OLD.mode_set_at THEN
        IF NEW.mode_set_at IS NULL OR NOT curation_actor_is(NEW.mode_set_by_actor_id, true) THEN
          RAISE EXCEPTION 'a page''s mode is set by a human reviewer, with the time'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

      IF NEW.kept_items IS DISTINCT FROM OLD.kept_items THEN
        FOR element IN SELECT * FROM jsonb_array_elements(NEW.kept_items) LOOP
          -- A new element is one not already in the array, compared whole:
          -- jsonb containment would let a fragment of an old mark through.
          IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(OLD.kept_items) o WHERE o = element) AND (
               jsonb_typeof(element) <> 'object'
               OR element ->> 'marked_at' IS NULL
               OR NOT curation_actor_is((element ->> 'marked_by_actor_id')::bigint, true)) THEN
            RAISE EXCEPTION 'an item is kept by a human reviewer, with the time'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END LOOP;
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER editorial_compositions_marks_guard
      BEFORE UPDATE ON editorial_compositions
      FOR EACH ROW
      WHEN (OLD.mode IS DISTINCT FROM NEW.mode
            OR OLD.mode_set_by_actor_id IS DISTINCT FROM NEW.mode_set_by_actor_id
            OR OLD.mode_set_at IS DISTINCT FROM NEW.mode_set_at
            OR OLD.kept_items IS DISTINCT FROM NEW.kept_items)
      EXECUTE FUNCTION editorial_compositions_marks_guard()
    """)
  end

  defp compositions_down do
    execute("DROP TRIGGER editorial_compositions_marks_guard ON editorial_compositions")
    execute("DROP FUNCTION editorial_compositions_marks_guard()")
    drop constraint(:editorial_compositions, :editorial_compositions_marks)

    alter table(:editorial_compositions) do
      remove :kept_items
      remove :mode_set_at
      remove :mode_set_by_actor_id
      remove :mode
    end
  end

  # ── curation_refresh_states (R5, R14) ──────────────────────────────────────

  @refresh_shape_tail """
    AND (refresh_generation >= 0) AND (lease_token >= 0) AND (lease_attempts >= 0)
    AND (failures >= 0) AND (dirty_seq >= 0)
    AND (state NOT IN ('queued', 'running') OR lease_expires_at IS NOT NULL)
    AND (state <> 'running' OR run_dirty_seq IS NOT NULL)
    AND (state <> 'deferred' OR next_retry_at IS NOT NULL)
    AND (last_completed_at IS NULL OR (last_outcome IS NOT NULL AND refresh_after IS NOT NULL))
  """

  defp refresh_states_up do
    alter table(:curation_refresh_states) do
      add :review_unit_reserved_at, :utc_datetime_usec
      add :last_deferred_at, :utc_datetime_usec
    end

    execute("ALTER TABLE curation_refresh_states DROP CONSTRAINT curation_refresh_states_shape")

    execute("""
    ALTER TABLE curation_refresh_states ADD CONSTRAINT curation_refresh_states_shape CHECK (
      state IN ('idle', 'queued', 'running', 'suppressed', 'deferred')
      AND (last_outcome IS NULL OR last_outcome IN
           ('unchanged', 'needs_editor', 'proposed', 'abstained', 'no_change'))
    #{@refresh_shape_tail}
    )
    """)
  end

  defp refresh_states_down do
    execute("ALTER TABLE curation_refresh_states DROP CONSTRAINT curation_refresh_states_shape")

    execute("""
    ALTER TABLE curation_refresh_states ADD CONSTRAINT curation_refresh_states_shape CHECK (
      state IN ('idle', 'queued', 'running', 'suppressed', 'deferred')
      AND (last_outcome IS NULL OR last_outcome IN ('unchanged', 'needs_editor'))
    #{@refresh_shape_tail}
    )
    """)

    alter table(:curation_refresh_states) do
      remove :review_unit_reserved_at
      remove :last_deferred_at
    end
  end

  # ── curation_configurations: the editor switch (R1.5) ──────────────────────

  defp configurations_up do
    alter table(:curation_configurations) do
      add :editor_enabled_version_id, :bigint
      add :editor_switched_by_actor_id, references(:actors, on_delete: :restrict)
      add :editor_switched_at, :utc_datetime_usec
      add :editor_switch_reason, :text
    end

    execute("""
    ALTER TABLE curation_configurations ADD CONSTRAINT curation_configurations_editor_version_fkey
      FOREIGN KEY (editor_enabled_version_id, id)
      REFERENCES curation_configuration_versions (id, configuration_id)
    """)

    # Fires only when the switch itself changes, so an activation, which
    # leaves it where it was (R1.5), is untouched (Stage 0 check,
    # recommendation 2).
    execute("""
    CREATE FUNCTION curation_configurations_editor_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT curation_actor_is(NEW.editor_switched_by_actor_id, true)
         OR NEW.editor_switched_at IS NULL
         OR NEW.editor_switch_reason IS NULL OR btrim(NEW.editor_switch_reason) = ''
         OR (NEW.editor_enabled_version_id IS NOT NULL
             AND NEW.editor_enabled_version_id IS DISTINCT FROM NEW.current_version_id) THEN
        RAISE EXCEPTION 'the editor is switched by a human reviewer, with a reason, to nothing or the current version'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER curation_configurations_editor_guard
      BEFORE UPDATE ON curation_configurations
      FOR EACH ROW
      WHEN (OLD.editor_enabled_version_id IS DISTINCT FROM NEW.editor_enabled_version_id
            OR OLD.editor_switched_by_actor_id IS DISTINCT FROM NEW.editor_switched_by_actor_id
            OR OLD.editor_switched_at IS DISTINCT FROM NEW.editor_switched_at
            OR OLD.editor_switch_reason IS DISTINCT FROM NEW.editor_switch_reason)
      EXECUTE FUNCTION curation_configurations_editor_guard()
    """)
  end

  defp configurations_down do
    execute("DROP TRIGGER curation_configurations_editor_guard ON curation_configurations")
    execute("DROP FUNCTION curation_configurations_editor_guard()")

    execute(
      "ALTER TABLE curation_configurations DROP CONSTRAINT curation_configurations_editor_version_fkey"
    )

    alter table(:curation_configurations) do
      remove :editor_switch_reason
      remove :editor_switched_at
      remove :editor_switched_by_actor_id
      remove :editor_enabled_version_id
    end
  end

  # ── curator_profiles: the generic editor (R2) ──────────────────────────────

  # The persona rule, word for word as `curator_profiles_admission_guard()`
  # had it.
  @persona_admission """
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
  """

  @persona_evidence """
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
  """

  defp profiles_up do
    alter table(:curator_profiles) do
      add :kind, :text, null: false, default: "persona"
    end

    create constraint(:curator_profiles, :curator_profiles_kind,
             check: "kind IN ('persona', 'generic_editor')"
           )

    create unique_index(:curator_profiles, [:kind],
             where: "kind = 'generic_editor'",
             name: :curator_profiles_one_generic_editor_index
           )

    execute("""
    CREATE OR REPLACE FUNCTION curator_profiles_admission_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'a profile''s kind is fixed when it is created'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF NEW.state = 'admitted' THEN
    #{@persona_admission}
        IF NEW.kind = 'generic_editor' THEN
          -- The generic editor's narrow admission (#264 R2.2): no dossier, no
          -- sources, no deceased-status evidence, and an instruction named.
          IF NOT EXISTS (
            SELECT 1 FROM curator_profile_versions v
             WHERE v.id = NEW.current_version_id
               AND v.dossier = '{}'::jsonb
               AND v.source_refs = '[]'::jsonb AND v.deceased_evidence_refs = '[]'::jsonb
               AND btrim(v.template_version) <> ''
          ) THEN
            RAISE EXCEPTION 'the generic editor is admitted from an empty version naming its instruction'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        ELSE
    #{@persona_evidence}
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$
    """)
  end

  defp profiles_down do
    execute("""
    CREATE OR REPLACE FUNCTION curator_profiles_admission_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.state = 'admitted' THEN
    #{@persona_admission}
    #{@persona_evidence}
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    drop index(:curator_profiles, [:kind], name: :curator_profiles_one_generic_editor_index)
    drop constraint(:curator_profiles, :curator_profiles_kind)

    alter table(:curator_profiles) do
      remove :kind
    end
  end

  # ── curation_proposals (R9, R10) ───────────────────────────────────────────

  defp proposals_up do
    create table(:curation_proposals) do
      add :composition_id, references(:editorial_compositions, on_delete: :restrict), null: false
      add :version_id, :bigint, null: false

      add :configuration_version_id,
          references(:curation_configuration_versions, on_delete: :restrict),
          null: false

      add :refresh_state_id, references(:curation_refresh_states, on_delete: :restrict),
        null: false

      add :refresh_generation, :bigint, null: false
      add :request_key, :text, null: false
      add :model_config_id, references(:local_model_configs, on_delete: :restrict), null: false
      add :profile_id, references(:curator_profiles, on_delete: :restrict), null: false
      add :profile_version_id, :bigint, null: false
      add :packet_hash, :text, null: false
      add :arrangement_hash, :text, null: false
      add :published_parent_version_id, :bigint
      add :superseded_on_arrival, :boolean, null: false
      add :marks_digest, :text, null: false
      add :carried, :jsonb, null: false
      add :overflow, :jsonb, null: false

      add :state, :text, null: false, default: "pending"
      add :resolved_at, :utc_datetime_usec
      add :resolved_by_actor_id, references(:actors, on_delete: :restrict)
      add :resolution_reason, :text
      add :resolution_version_id, :bigint
      add :resolution_review_id, references(:editorial_composition_reviews, on_delete: :restrict)
      add :obsoleted_by_proposal_id, :bigint
      add :quality_form, :jsonb

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute("""
    ALTER TABLE curation_proposals
      ADD CONSTRAINT curation_proposals_version_fkey
        FOREIGN KEY (version_id, composition_id)
        REFERENCES editorial_composition_versions (id, composition_id),
      ADD CONSTRAINT curation_proposals_profile_version_fkey
        FOREIGN KEY (profile_version_id, profile_id)
        REFERENCES curator_profile_versions (id, profile_id),
      ADD CONSTRAINT curation_proposals_published_parent_fkey
        FOREIGN KEY (published_parent_version_id, composition_id)
        REFERENCES editorial_composition_versions (id, composition_id),
      ADD CONSTRAINT curation_proposals_resolution_version_fkey
        FOREIGN KEY (resolution_version_id, composition_id)
        REFERENCES editorial_composition_versions (id, composition_id),
      -- Deferred: the older pending proposal is made obsolete, naming the
      -- newer, just before the newer is inserted (one pending per page).
      ADD CONSTRAINT curation_proposals_obsoleted_by_fkey
        FOREIGN KEY (obsoleted_by_proposal_id) REFERENCES curation_proposals (id)
        DEFERRABLE INITIALLY DEFERRED
    """)

    create constraint(:curation_proposals, :curation_proposals_shape,
             check: """
             state IN ('pending', 'taken', 'dismissed', 'obsolete')
             AND (state = 'pending') = (resolved_at IS NULL)
             AND jsonb_typeof(carried) = 'array' AND jsonb_typeof(overflow) = 'array'
             AND (state <> 'pending' OR (resolved_by_actor_id IS NULL AND resolution_reason IS NULL
                  AND resolution_version_id IS NULL AND resolution_review_id IS NULL
                  AND obsoleted_by_proposal_id IS NULL AND quality_form IS NULL))
             AND (state <> 'taken' OR (resolution_version_id IS NOT NULL
                  AND resolved_by_actor_id IS NOT NULL AND quality_form IS NOT NULL
                  AND resolution_review_id IS NULL AND obsoleted_by_proposal_id IS NULL))
             AND (state <> 'dismissed' OR (resolution_review_id IS NOT NULL
                  AND resolved_by_actor_id IS NOT NULL AND resolution_reason IS NOT NULL
                  AND btrim(resolution_reason) <> '' AND resolution_version_id IS NULL
                  AND obsoleted_by_proposal_id IS NULL))
             AND (state <> 'obsolete' OR (resolution_reason IS NOT NULL
                  AND btrim(resolution_reason) <> '' AND resolved_by_actor_id IS NULL
                  AND resolution_version_id IS NULL AND resolution_review_id IS NULL
                  AND quality_form IS NULL))
             """
           )

    create unique_index(:curation_proposals, [:version_id])
    create unique_index(:curation_proposals, [:request_key])

    create unique_index(:curation_proposals, [:composition_id],
             where: "state = 'pending'",
             name: :curation_proposals_one_pending_index
           )

    execute("""
    CREATE FUNCTION curation_proposals_insert_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.state IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'a proposal is written pending'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM editorial_composition_versions v
          JOIN inference_attempts a ON a.id = v.attempt_id
         WHERE v.id = NEW.version_id AND v.composition_id = NEW.composition_id
           AND v.origin = 'model'
           AND v.configuration_version_id = NEW.configuration_version_id
           AND v.arrangement_hash = NEW.arrangement_hash
           AND a.request_key = NEW.request_key AND a.packet_hash = NEW.packet_hash
           AND a.model_config_id = NEW.model_config_id
      ) THEN
        RAISE EXCEPTION 'a proposal names its model version, whose attempt has its key and packet'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER curation_proposals_insert_guard
      BEFORE INSERT ON curation_proposals
      FOR EACH ROW EXECUTE FUNCTION curation_proposals_insert_guard()
    """)

    execute("""
    CREATE FUNCTION curation_proposals_update_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      identity text[] := ARRAY['id', 'composition_id', 'version_id', 'configuration_version_id',
        'refresh_state_id', 'refresh_generation', 'request_key', 'model_config_id', 'profile_id',
        'profile_version_id', 'packet_hash', 'arrangement_hash', 'published_parent_version_id',
        'superseded_on_arrival', 'marks_digest', 'carried', 'overflow', 'inserted_at'];
      field text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'curation_proposals rows are never deleted (id %)', OLD.id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      FOREACH field IN ARRAY identity LOOP
        IF (to_jsonb(NEW) -> field) IS DISTINCT FROM (to_jsonb(OLD) -> field) THEN
          RAISE EXCEPTION 'curation_proposals.% is fixed when the proposal is written (id %)', field, OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END LOOP;

      IF OLD.state IS DISTINCT FROM 'pending' OR NEW.state = 'pending' THEN
        RAISE EXCEPTION 'a proposal leaves pending once (id %)', OLD.id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NEW.state IN ('taken', 'dismissed') AND NOT curation_actor_is(NEW.resolved_by_actor_id, true) THEN
        RAISE EXCEPTION 'a proposal is taken or dismissed by a human reviewer'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NEW.state = 'taken' AND NOT EXISTS (
        SELECT 1 FROM editorial_composition_versions v
         WHERE v.id = NEW.resolution_version_id AND v.origin = 'manual'
           AND v.parent_version_id = NEW.version_id
      ) THEN
        RAISE EXCEPTION 'a taken proposal is the parent of the manual version that took it'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF NEW.state = 'dismissed' AND NOT EXISTS (
        SELECT 1 FROM editorial_composition_reviews r
         WHERE r.id = NEW.resolution_review_id AND r.composition_version_id = NEW.version_id
           AND r.decision = 'rejected'
      ) THEN
        RAISE EXCEPTION 'a dismissed proposal is rejected by a review of its version'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER curation_proposals_update_guard
      BEFORE UPDATE OR DELETE ON curation_proposals
      FOR EACH ROW EXECUTE FUNCTION curation_proposals_update_guard()
    """)
  end

  defp proposals_down do
    drop table(:curation_proposals)
    execute("DROP FUNCTION curation_proposals_update_guard()")
    execute("DROP FUNCTION curation_proposals_insert_guard()")
  end
end
