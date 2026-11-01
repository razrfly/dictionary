defmodule DevilsDictionary.Repo.Migrations.AdmitGroundedSelectionInstruction do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE curation_configuration_versions DROP CONSTRAINT curation_configuration_versions_shape"

    execute """
    ALTER TABLE curation_configuration_versions ADD CONSTRAINT curation_configuration_versions_shape CHECK (version >= 1 AND max_highlights BETWEEN 0 AND 12 AND ((max_highlights <= 3 AND COALESCE(manifest->>'selection_scope','') <> 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') NOT IN ('voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6','voltaire-whole-entry-v7')) OR (max_highlights = 12 AND COALESCE(manifest->>'selection_scope','') = 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') IN ('voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6','voltaire-whole-entry-v7'))) AND lead_policy IN ('bierce_first_v1') AND btrim(change_reason) <> '');
    """

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
                   AND pv.template_version IN ('voltaire-selector-v1','voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6','voltaire-whole-entry-v7')
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

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM local_model_configs WHERE instruction_version='voltaire-whole-entry-v7') OR EXISTS (SELECT 1 FROM curator_profile_versions WHERE template_version='voltaire-whole-entry-v7') THEN
        RAISE EXCEPTION 'grounded instruction history exists; disable policy and roll forward';
      END IF;
    END $$;
    """

    execute "ALTER TABLE curation_configuration_versions DROP CONSTRAINT curation_configuration_versions_shape"

    execute """
    ALTER TABLE curation_configuration_versions ADD CONSTRAINT curation_configuration_versions_shape CHECK (version >= 1 AND max_highlights BETWEEN 0 AND 12 AND ((max_highlights <= 3 AND COALESCE(manifest->>'selection_scope','') <> 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') NOT IN ('voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6')) OR (max_highlights = 12 AND COALESCE(manifest->>'selection_scope','') = 'whole_entry_v1' AND COALESCE(manifest->'editor'->>'instruction_version','') IN ('voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6'))) AND lead_policy IN ('bierce_first_v1') AND btrim(change_reason) <> '');
    """

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
                   AND pv.template_version IN ('voltaire-selector-v1','voltaire-whole-entry-v1','voltaire-whole-entry-v2','voltaire-whole-entry-v3','voltaire-whole-entry-v4','voltaire-whole-entry-v5','voltaire-whole-entry-v6')
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
