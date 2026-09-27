defmodule DevilsDictionary.Repo.Migrations.RepairCurationIntegrity do
  @moduledoc """
  Repairs to the curation foundation from the independent audit of PR #206
  (#196, #201). It is a separate migration, not an edit of
  `20260926233642_create_curation_foundation`, so that every database that
  already applied that one, including test partitions, is repaired by
  `ecto.migrate` rather than silently left behind.

    1. **A deleted reference is not a missing one.** Each item records, at
       insert, which of its references it was made with
       (`required_references`). A reference that deletion later nulls is then
       distinguishable from one the item never had, so deleting a claim or an
       object withholds the item rather than making it eligible again.
    2. **Version deduplication includes the frozen configuration version.**
       The same arrangement can be made again under a new configuration
       version. It then needs its own review.
    3. **A note's author is an actor, not a caller-supplied label.**
       `note_author_actor_id` names who wrote it. A human note is its
       version's author's, and the stored label is that actor's.
    4. **Every publication receipt names its authority.** `authority_kind` is
       `operator` (an accepted operator review) and nothing else in this
       slice. The panel-decision authority described in
       `docs/curation/persistence-slice-1.md` needs decision records that do
       not exist yet (#197). Until a later migration adds them, the database
       refuses it.
  """
  use Ecto.Migration

  # The references an item was made with. `meaning_lexeme_id` is absent: it is
  # RESTRICT, so a deletion never nulls it.
  @references_function """
  CREATE FUNCTION curation_item_references(i editorial_composition_items) RETURNS text[] AS $$
    SELECT array_remove(ARRAY[
      CASE WHEN i.item_object_id IS NOT NULL THEN 'item_object_id' END,
      CASE WHEN i.content_revision_id IS NOT NULL THEN 'content_revision_id' END,
      CASE WHEN i.sense_revision_id IS NOT NULL THEN 'sense_revision_id' END,
      CASE WHEN i.source_record_revision_id IS NOT NULL THEN 'source_record_revision_id' END,
      CASE WHEN i.meaning_sense_revision_id IS NOT NULL THEN 'meaning_sense_revision_id' END,
      CASE WHEN i.assertion_revision_id IS NOT NULL THEN 'assertion_revision_id' END
    ], NULL);
  $$ LANGUAGE sql IMMUTABLE;
  """

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

  @complete_function_v1 """
  CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger AS $$
  BEGIN
  #{@complete_checks}
    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  """

  # K7, K8, R6, R7 and note authorship. The database, not the caller, records
  # which references the item was made with, and checks who wrote its note: a
  # human note is its version's author's, under that actor's own label; a
  # model note (none is written in this slice) is a bot's.
  @complete_function_v2 """
  CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger AS $$
  DECLARE
    author record;
  BEGIN
  #{@complete_checks}
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

    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  """

  # R1, R3, R5: who may publish under which authority. An operator publication
  # is a reviewer's, authorized by the latest review of that very version, an
  # acceptance of the fingerprint published; an operator withdrawal is a
  # reviewer's. Any other authority is refused: a panel decision needs the
  # decision records a later migration adds (#197).
  @authority_function """
  CREATE FUNCTION editorial_composition_publications_authority() RETURNS trigger AS $$
  DECLARE
    latest record;
  BEGIN
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
    END IF;

    RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;
  """

  @review_guard_function_v1 """
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
  """

  def up do
    alter table(:editorial_composition_items) do
      add :required_references, {:array, :text}
      add :note_author_actor_id, references(:actors, on_delete: :restrict)
    end

    execute @references_function
    execute @complete_function_v2

    # Existing rows: backfill what they were made with. The item guard forbids
    # every non-reference change, so it steps aside for this one statement.
    # A reference an earlier deletion already nulled cannot be recovered here.
    execute "ALTER TABLE editorial_composition_items DISABLE TRIGGER editorial_composition_items_guard"

    execute """
    UPDATE editorial_composition_items i
       SET required_references = curation_item_references(i),
           note_author_actor_id = CASE WHEN i.note IS NULL THEN NULL ELSE v.created_by_actor_id END
      FROM editorial_composition_versions v
     WHERE v.id = i.composition_version_id
    """

    execute "ALTER TABLE editorial_composition_items ENABLE TRIGGER editorial_composition_items_guard"

    execute "ALTER TABLE editorial_composition_items ALTER COLUMN required_references SET NOT NULL"

    create constraint(:editorial_composition_items, :editorial_composition_items_note_author,
             check: "(note IS NULL) = (note_author_actor_id IS NULL)"
           )

    drop index(:editorial_composition_versions, [
           :composition_id,
           :arrangement_hash,
           :eligibility_fingerprint
         ])

    create unique_index(
             :editorial_composition_versions,
             [
               :composition_id,
               :configuration_version_id,
               :arrangement_hash,
               :eligibility_fingerprint
             ],
             name: :editorial_composition_versions_dedup_index
           )

    alter table(:editorial_composition_publications) do
      add :authority_kind, :text, null: false, default: "operator"
    end

    execute "ALTER TABLE editorial_composition_publications ALTER COLUMN authority_kind DROP DEFAULT"

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_authority,
             check: "authority_kind IN ('operator')"
           )

    execute "DROP TRIGGER editorial_composition_publications_human_actor ON editorial_composition_publications"
    execute @authority_function

    execute "DROP TRIGGER editorial_composition_publications_review_guard ON editorial_composition_publications"

    execute "DROP FUNCTION editorial_composition_publications_review_guard()"

    execute """
    CREATE TRIGGER editorial_composition_publications_authority BEFORE INSERT
      ON editorial_composition_publications
      FOR EACH ROW EXECUTE FUNCTION editorial_composition_publications_authority();
    """
  end

  def down do
    execute "DROP TRIGGER editorial_composition_publications_authority ON editorial_composition_publications"
    execute "DROP FUNCTION editorial_composition_publications_authority()"
    execute @review_guard_function_v1

    execute """
    CREATE TRIGGER editorial_composition_publications_review_guard BEFORE INSERT
      ON editorial_composition_publications
      FOR EACH ROW EXECUTE FUNCTION editorial_composition_publications_review_guard();
    """

    execute """
    CREATE TRIGGER editorial_composition_publications_human_actor BEFORE INSERT
      ON editorial_composition_publications
      FOR EACH ROW EXECUTE FUNCTION curation_human_actor_guard('actor_id', 'true');
    """

    drop constraint(
           :editorial_composition_publications,
           :editorial_composition_publications_authority
         )

    alter table(:editorial_composition_publications) do
      remove :authority_kind
    end

    drop index(:editorial_composition_versions, [],
           name: :editorial_composition_versions_dedup_index
         )

    create unique_index(:editorial_composition_versions, [
             :composition_id,
             :arrangement_hash,
             :eligibility_fingerprint
           ])

    drop constraint(:editorial_composition_items, :editorial_composition_items_note_author)
    execute @complete_function_v1

    alter table(:editorial_composition_items) do
      remove :note_author_actor_id
      remove :required_references
    end

    execute "DROP FUNCTION curation_item_references(editorial_composition_items)"
  end
end
