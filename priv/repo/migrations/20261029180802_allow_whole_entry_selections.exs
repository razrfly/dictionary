defmodule DevilsDictionary.Repo.Migrations.AllowWholeEntrySelections do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape"

    execute """
    ALTER TABLE editorial_composition_items ADD CONSTRAINT editorial_composition_items_shape CHECK (
    role IN ('lead', 'highlight')
    AND item_kind IN ('content', 'sense_quotation', 'work', 'exemplar', 'sense_definition', 'claim')
    AND selection_origin IN ('manual','model') 
    AND (role <> 'lead' OR (position = 1 AND item_kind IN ('content','sense_definition')))
    AND (role <> 'highlight' OR (position >= 1 AND position <= 12))
    AND (item_kind <> 'exemplar' OR role = 'highlight')
    AND (item_kind IN ('content', 'exemplar') OR content_revision_id IS NULL)
    AND (item_kind IN ('sense_quotation','sense_definition') OR (sense_revision_id IS NULL AND locator IS NULL AND words_sha256 IS NULL))
    AND (item_kind = 'work' OR (catalog_manifest IS NULL AND catalog_checksum IS NULL
         AND catalog_identity IS NULL AND source_record_revision_id IS NULL))
    AND (item_kind <> 'sense_quotation' OR locator ~ '^quotation:[0-9]+$')
    AND ((meaning_sense_revision_id IS NOT NULL)::int + (meaning_lexeme_id IS NOT NULL)::int <= 1)
    AND ((note IS NULL AND note_author_kind IS NULL AND note_author_label IS NULL)
         OR (btrim(note) <> '' AND note_author_kind IN ('human', 'model') AND btrim(note_author_label) <> ''))
    AND (item_kind <> 'sense_definition' OR (role IN ('lead','highlight') AND locator IS NULL)) AND (shelf_citation_id IS NULL OR item_kind = 'work') );
    """

    execute "ALTER TABLE curation_configuration_versions DROP CONSTRAINT curation_configuration_versions_shape"

    create constraint(:curation_configuration_versions, :curation_configuration_versions_shape,
             check: """
             version >= 1 AND max_highlights BETWEEN 0 AND 12 AND ((max_highlights <= 3 AND COALESCE(manifest->>'selection_scope','') <> 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') <> 'voltaire-whole-entry-v1') OR (max_highlights = 12 AND COALESCE(manifest->>'selection_scope','') = 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') = 'voltaire-whole-entry-v1')) AND lead_policy IN ('bierce_first_v1') AND btrim(change_reason) <> ''
             """
           )

    execute """
    CREATE OR REPLACE FUNCTION editorial_composition_versions_author_guard() RETURNS trigger
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
             AND (p.kind = 'generic_editor' OR (
               p.kind = 'persona' AND p.slug = 'voltaire' AND EXISTS (
                 SELECT 1 FROM curator_profile_versions pv, local_model_configs mc
                 WHERE pv.id = p.current_version_id AND mc.id = (editor ->> 'model_config_id')::bigint
                   AND pv.template_version IN ('voltaire-selector-v1','voltaire-whole-entry-v1')
                   AND mc.instruction_version = pv.template_version
                   AND pv.dossier = '{"disclosure": "An AI selection lens inspired by Voltaire; not his voice or an assertion of his opinions about modern events.", "selection": "Prefer sourced material that makes dogma, unjustified certainty or intolerance visible through a concrete contrast. Prefer evidence of consequences to rhetorical agreement. The lens cannot change lead policy, source eligibility, meaning constraints or exact quotation. Explain the relevance, not an imagined endorsement by Voltaire. Abstain when no supplied evidence fits. Do not prefer an item merely because it agrees with this lens.", "principles": ["Test confident abstractions against particular consequences.", "Distinguish satire from factual assertion."], "blind_spots": ["Satire may oversimplify sincere beliefs; do not assume bad faith."], "positive_example": "Select a supplied, meaning-relevant example of a claim contradicted by its documented consequences.", "negative_example": "Reject an irrelevant news headline chosen only because it mocks a disliked belief."}'::jsonb
                   AND pv.source_refs = '[{"url": "https://www.gutenberg.org/ebooks/19942", "work": "Candide", "edition": "Project Gutenberg 19942, English text, released 2006-11-27; translator not identified in this dossier", "locators": ["Chapter I: Pangloss and the castle", "Chapter III: war and its consequences", "Chapter XXX: conclusion"], "rights": "Public domain in the USA; two short passages and original editorial paraphrases; check jurisdiction before reuse.", "basis": "These chapters contrast philosophical assurances with observed consequences; the selection lens is our interpretation, not a historical quotation.", "passages": [{"locator": "Chapter I, Pangloss on spectacles", "speaker": "Pangloss (fictional character), not a literal statement of the author’s beliefs", "text": "the nose has been formed to bear spectacles"}, {"locator": "Chapter XXX, final reply", "speaker": "Candide (fictional character)", "text": "but let us cultivate our garden."}]}]'::jsonb
                   AND pv.deceased_evidence_refs = '[{"url": "https://catalogue.bnf.fr/ark:/12148/cb11928669t", "authority": "Bibliothèque nationale de France person authority", "field": "Mort", "value": "1778-05-30"}]'::jsonb
               ))) AND p.state = 'admitted'
             AND p.current_version_id = (editor ->> 'profile_version_id')::bigint
             AND p.bot_actor_id = NEW.created_by_actor_id
             AND (editor ->> 'bot_actor_id')::bigint = NEW.created_by_actor_id
        ) THEN
          RAISE EXCEPTION 'a model version is written by the bot actor of the admitted editor its configuration version binds'
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
    """

    execute """
    CREATE FUNCTION editorial_whole_entry_limits() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE cv record;
    BEGIN
      SELECT c.* INTO cv FROM curation_configuration_versions c
        JOIN editorial_composition_versions v ON v.configuration_version_id=c.id
        WHERE v.id=NEW.composition_version_id;
      IF NEW.role='highlight' AND NEW.position>cv.max_highlights THEN
        RAISE EXCEPTION 'highlight positions/count exceed the immutable configuration limit' USING ERRCODE='check_violation', CONSTRAINT='editorial_composition_items_shape';
      END IF;
      IF NEW.role='lead' AND NEW.item_kind='sense_definition' AND COALESCE(cv.manifest->>'selection_scope','') <> 'whole_entry_v1' THEN
        RAISE EXCEPTION 'sense-definition leads require whole-entry opt-in' USING ERRCODE='check_violation', CONSTRAINT='editorial_composition_items_shape';
      END IF;
      IF EXISTS (SELECT 1 FROM editorial_composition_items i WHERE i.composition_version_id=NEW.composition_version_id
          AND i.role='highlight' AND i.position>cv.max_highlights)
        OR (SELECT count(*) FROM editorial_composition_items WHERE composition_version_id=NEW.composition_version_id AND role='highlight')>cv.max_highlights THEN
        RAISE EXCEPTION 'highlight positions/count exceed the immutable configuration limit' USING ERRCODE='check_violation', CONSTRAINT='editorial_composition_items_shape';
      END IF;
      IF COALESCE(cv.manifest->>'selection_scope','') <> 'whole_entry_v1' THEN
        IF EXISTS (SELECT 1 FROM editorial_composition_items WHERE composition_version_id=NEW.composition_version_id AND role='lead' AND item_kind='sense_definition') THEN
          RAISE EXCEPTION 'sense-definition leads require whole-entry opt-in' USING ERRCODE='check_violation', CONSTRAINT='editorial_composition_items_shape';
        END IF;
      ELSE
        IF EXISTS (
          SELECT section FROM (
            SELECT CASE WHEN i.item_kind='work' AND i.shelf_citation_id IS NOT NULL THEN c.shelf_kind
              WHEN i.item_kind='sense_quotation' THEN 'quotes'
              WHEN i.item_kind IN ('claim','exemplar') THEN 'examples'
              WHEN i.item_kind='work' THEN 'images' ELSE 'definitions' END AS section
            FROM editorial_composition_items i LEFT JOIN curation_shelf_citations c ON c.id=i.shelf_citation_id
            WHERE i.composition_version_id=NEW.composition_version_id AND i.role='highlight'
          ) sections GROUP BY section HAVING count(*)>CASE WHEN section IN ('examples','quotes') THEN 2 ELSE 1 END
        ) THEN RAISE EXCEPTION 'whole-entry section limit exceeded' USING ERRCODE='check_violation', CONSTRAINT='editorial_composition_items_shape'; END IF;
      END IF;
      RETURN NEW;
    END $$;
    """

    execute """
    CREATE TRIGGER editorial_whole_entry_insert BEFORE INSERT ON editorial_composition_items
      FOR EACH ROW EXECUTE FUNCTION editorial_whole_entry_limits();
    """

    execute """
    CREATE CONSTRAINT TRIGGER editorial_whole_entry_limits AFTER INSERT ON editorial_composition_items
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION editorial_whole_entry_limits();
    """
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM curation_configuration_versions WHERE manifest->>'selection_scope'='whole_entry_v1')
        OR EXISTS (SELECT 1 FROM editorial_composition_items WHERE position>3 OR (role='lead' AND item_kind='sense_definition')) THEN
        RAISE EXCEPTION 'whole-entry history exists; disable automation and roll forward, never erase history';
      END IF;
    END $$;
    """

    execute "DROP TRIGGER IF EXISTS editorial_whole_entry_insert ON editorial_composition_items"
    execute "DROP TRIGGER IF EXISTS editorial_whole_entry_limits ON editorial_composition_items"
    execute "DROP FUNCTION IF EXISTS editorial_whole_entry_limits()"

    execute "ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape"

    execute """
    ALTER TABLE editorial_composition_items ADD CONSTRAINT editorial_composition_items_shape CHECK (
    role IN ('lead', 'highlight')
    AND item_kind IN ('content', 'sense_quotation', 'work', 'exemplar', 'sense_definition', 'claim')
    AND selection_origin IN ('manual','model') 
    AND (role <> 'lead' OR (position = 1 AND item_kind = 'content'))
    AND (role <> 'highlight' OR (position >= 1 AND position <= 3))
    AND (item_kind <> 'exemplar' OR role = 'highlight')
    AND (item_kind IN ('content', 'exemplar') OR content_revision_id IS NULL)
    AND (item_kind IN ('sense_quotation','sense_definition') OR (sense_revision_id IS NULL AND locator IS NULL AND words_sha256 IS NULL))
    AND (item_kind = 'work' OR (catalog_manifest IS NULL AND catalog_checksum IS NULL
         AND catalog_identity IS NULL AND source_record_revision_id IS NULL))
    AND (item_kind <> 'sense_quotation' OR locator ~ '^quotation:[0-9]+$')
    AND ((meaning_sense_revision_id IS NOT NULL)::int + (meaning_lexeme_id IS NOT NULL)::int <= 1)
    AND ((note IS NULL AND note_author_kind IS NULL AND note_author_label IS NULL)
         OR (btrim(note) <> '' AND note_author_kind IN ('human', 'model') AND btrim(note_author_label) <> ''))
    AND (item_kind <> 'sense_definition' OR (role = 'highlight' AND locator IS NULL)) AND (shelf_citation_id IS NULL OR item_kind = 'work') );
    """

    execute "ALTER TABLE curation_configuration_versions DROP CONSTRAINT curation_configuration_versions_shape"

    create constraint(:curation_configuration_versions, :curation_configuration_versions_shape,
             check: """
             version >= 1 AND max_highlights BETWEEN 0 AND 3 AND lead_policy IN ('bierce_first_v1') AND btrim(change_reason) <> ''
             """
           )

    execute """
    CREATE OR REPLACE FUNCTION editorial_composition_versions_author_guard() RETURNS trigger
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
             AND (p.kind = 'generic_editor' OR (
               p.kind = 'persona' AND p.slug = 'voltaire' AND EXISTS (
                 SELECT 1 FROM curator_profile_versions pv, local_model_configs mc
                 WHERE pv.id = p.current_version_id AND mc.id = (editor ->> 'model_config_id')::bigint
                   AND pv.template_version = 'voltaire-selector-v1'
                   AND mc.instruction_version = pv.template_version
                   AND pv.dossier = '{"disclosure": "An AI selection lens inspired by Voltaire; not his voice or an assertion of his opinions about modern events.", "selection": "Prefer sourced material that makes dogma, unjustified certainty or intolerance visible through a concrete contrast. Prefer evidence of consequences to rhetorical agreement. The lens cannot change lead policy, source eligibility, meaning constraints or exact quotation. Explain the relevance, not an imagined endorsement by Voltaire. Abstain when no supplied evidence fits. Do not prefer an item merely because it agrees with this lens.", "principles": ["Test confident abstractions against particular consequences.", "Distinguish satire from factual assertion."], "blind_spots": ["Satire may oversimplify sincere beliefs; do not assume bad faith."], "positive_example": "Select a supplied, meaning-relevant example of a claim contradicted by its documented consequences.", "negative_example": "Reject an irrelevant news headline chosen only because it mocks a disliked belief."}'::jsonb
                   AND pv.source_refs = '[{"url": "https://www.gutenberg.org/ebooks/19942", "work": "Candide", "edition": "Project Gutenberg 19942, English text, released 2006-11-27; translator not identified in this dossier", "locators": ["Chapter I: Pangloss and the castle", "Chapter III: war and its consequences", "Chapter XXX: conclusion"], "rights": "Public domain in the USA; two short passages and original editorial paraphrases; check jurisdiction before reuse.", "basis": "These chapters contrast philosophical assurances with observed consequences; the selection lens is our interpretation, not a historical quotation.", "passages": [{"locator": "Chapter I, Pangloss on spectacles", "speaker": "Pangloss (fictional character), not a literal statement of the author’s beliefs", "text": "the nose has been formed to bear spectacles"}, {"locator": "Chapter XXX, final reply", "speaker": "Candide (fictional character)", "text": "but let us cultivate our garden."}]}]'::jsonb
                   AND pv.deceased_evidence_refs = '[{"url": "https://catalogue.bnf.fr/ark:/12148/cb11928669t", "authority": "Bibliothèque nationale de France person authority", "field": "Mort", "value": "1778-05-30"}]'::jsonb
               ))) AND p.state = 'admitted'
             AND p.current_version_id = (editor ->> 'profile_version_id')::bigint
             AND p.bot_actor_id = NEW.created_by_actor_id
             AND (editor ->> 'bot_actor_id')::bigint = NEW.created_by_actor_id
        ) THEN
          RAISE EXCEPTION 'a model version is written by the bot actor of the admitted editor its configuration version binds'
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
    """
  end
end
