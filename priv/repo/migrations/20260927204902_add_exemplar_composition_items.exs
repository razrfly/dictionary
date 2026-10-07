defmodule DevilsDictionary.Repo.Migrations.AddExemplarCompositionItems do
  @moduledoc """
  The `exemplar` composition item kind (#212, build 1): a highlight that shows
  an accepted `illustrates` claim's subject, a person, a work or a passage
  someone cited as an example of a meaning.

  Additive. The shapes of the `content`, `sense_quotation` and `work` kinds do
  not change, and no existing function is recomputed: `arrangement_hash` and
  `required_references` already cover every column an exemplar uses. The one
  rule that reaches the other kinds is the claim-subject key below.

    * `item_kind` gains `'exemplar'`, a highlight only (the lead stays a
      `content` definition, K10);
    * an exemplar names its claim (`assertion_revision_id`) at insert, and the
      claim is an `illustrates` one;
    * **the claim is about the object shown.** A composite foreign key ties
      `(assertion_revision_id, item_object_id)` to the revision's
      `(id, subject_object_id)`, the way `content_revision_id` is tied to
      `content_id`. Deleting the revision nulls only the claim reference, and
      `required_references` then withholds the item (`:claim_deleted`, R7);
    * `content_revision_id` pins the words when the subject is a passage or
      quotation (a `content` object), and is absent for an entity, which has
      no revisions;
    * the sense-quotation and work references stay NULL (the shape check).

  PostgreSQL has no per-kind foreign key, so the composite key binds every
  item that names both an object and a claim: an optional claim on a
  `content`, `sense_quotation` or `work` item must be about that item's
  object too. Slice 1's one use of it, a `defines` claim on its own content
  item, already satisfies it, and `Eligibility` refuses any other with
  `:claim_not_about_object` before the insert.

  The key's target is a unique index on `assertion_revisions (id,
  subject_object_id)`. It is built in the migration's transaction, so writes
  to `assertion_revisions` wait for it (4.2M rows on the dev database,
  2026-09-27).

  Reversible. Rollback restores the previous shape check and insert trigger
  and drops the key and its index. It fails, rather than dropping anything,
  if an exemplar item has been stored: items are immutable (R7).
  """
  use Ecto.Migration

  # The shape check as `20260926233642_create_curation_foundation` wrote it.
  @shape_v1 """
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

  # The same check with `exemplar`: a highlight whose only exact reference
  # besides its claim is a content revision.
  @shape_v2 """
  role IN ('lead', 'highlight') AND
  item_kind IN ('content', 'sense_quotation', 'work', 'exemplar') AND
  selection_origin = 'manual' AND
  (role <> 'lead' OR (position = 1 AND item_kind = 'content')) AND
  (role <> 'highlight' OR position BETWEEN 1 AND 3) AND
  (item_kind <> 'exemplar' OR role = 'highlight') AND
  (item_kind IN ('content', 'exemplar') OR content_revision_id IS NULL) AND
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

  # The insert trigger's checks as `20260927094256_repair_curation_integrity`
  # left them, unchanged here.
  @complete_checks """
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
  """

  @note_checks """
    NEW.required_references := curation_item_references(NEW);

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
  """

  # An exemplar names an `illustrates` claim, and pins the words of a content
  # subject. That the claim is about `item_object_id` is the composite key's.
  @exemplar_checks """
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
  """

  @complete_function_v2 """
  CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger AS $$
  DECLARE
    author record;
  BEGIN
  #{@complete_checks}
  #{@note_checks}
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  """

  @complete_function_v3 """
  CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger AS $$
  DECLARE
    author record;
    subject_kind text;
  BEGIN
  #{@complete_checks}
  #{@exemplar_checks}
  #{@note_checks}
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  """

  def up do
    # Column-list referential actions (`ON DELETE SET NULL (column)`) arrived
    # in PostgreSQL 15; the curation foundation already refuses older servers.
    execute """
    DO $$
    BEGIN
      IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION 'exemplar composition items need PostgreSQL 15 or newer (column-list ON DELETE SET NULL); this server is %',
          current_setting('server_version');
      END IF;
    END
    $$;
    """

    # The target of the claim-subject key. `id` is already unique, so this
    # only lets an item name (revision, subject) and have the pair checked.
    create unique_index(:assertion_revisions, [:id, :subject_object_id],
             name: :assertion_revisions_id_subject_index
           )

    drop constraint(:editorial_composition_items, :editorial_composition_items_shape)

    create constraint(:editorial_composition_items, :editorial_composition_items_shape,
             check: @shape_v2
           )

    execute """
    ALTER TABLE editorial_composition_items
      ADD CONSTRAINT editorial_composition_items_claim_subject_fkey
      FOREIGN KEY (assertion_revision_id, item_object_id)
      REFERENCES assertion_revisions (id, subject_object_id)
      ON DELETE SET NULL (assertion_revision_id)
    """

    execute @complete_function_v3
  end

  def down do
    execute @complete_function_v2

    execute """
    ALTER TABLE editorial_composition_items
      DROP CONSTRAINT editorial_composition_items_claim_subject_fkey
    """

    drop constraint(:editorial_composition_items, :editorial_composition_items_shape)

    create constraint(:editorial_composition_items, :editorial_composition_items_shape,
             check: @shape_v1
           )

    drop index(:assertion_revisions, [:id, :subject_object_id],
           name: :assertion_revisions_id_subject_index
         )
  end
end
