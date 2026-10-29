defmodule DevilsDictionary.Repo.Migrations.AllowSingleEditorPublication do
  use Ecto.Migration

  # Existing operator receipts and deployed manual code remain valid. No policy,
  # identity, activation, job or publication is created by this migration.
  def up do
    execute "ALTER TABLE editorial_composition_publications DROP CONSTRAINT editorial_composition_publications_authority"

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_authority,
             check: "authority_kind IN ('operator','single_editor')"
           )

    execute "ALTER TABLE editorial_composition_publications DROP CONSTRAINT editorial_composition_publications_shape"

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_shape,
             check: """
             btrim(reason) <> '' AND (
             (action = 'publish' AND published_version_id IS NOT NULL AND eligibility_fingerprint IS NOT NULL
              AND ((authority_kind = 'operator' AND authorizing_review_id IS NOT NULL)
                OR (authority_kind = 'single_editor' AND authorizing_review_id IS NULL)))
             OR (action = 'withdraw' AND authority_kind = 'operator' AND previous_version_id IS NOT NULL
               AND published_version_id IS NULL AND authorizing_review_id IS NULL AND eligibility_fingerprint IS NULL))
             """
           )

    execute """
    CREATE OR REPLACE FUNCTION editorial_composition_publications_authority() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE latest record; BEGIN

      IF NEW.authority_kind = 'single_editor' THEN
        IF NEW.action <> 'publish' OR NEW.authorizing_review_id IS NOT NULL OR NOT EXISTS (
          SELECT 1 FROM editorial_composition_versions v
          JOIN editorial_compositions c ON c.id = v.composition_id
          JOIN curation_configuration_versions cv ON cv.id = v.configuration_version_id
          JOIN curation_configurations cfg ON cfg.id = cv.configuration_id
          JOIN inference_attempts a ON a.id = v.attempt_id
          JOIN curation_refresh_states rs ON rs.composition_id = c.id AND rs.configuration_version_id = cv.id
          JOIN curator_profiles p ON p.id = (cv.manifest->'editor'->>'profile_id')::bigint
          JOIN local_model_configs mc ON mc.id = a.model_config_id
          WHERE v.id = NEW.published_version_id AND c.id = NEW.composition_id
            AND v.origin = 'model' AND v.created_by_actor_id = NEW.actor_id
            AND v.eligibility_fingerprint = NEW.eligibility_fingerprint
            AND c.state = 'active' AND c.mode = 'open'
            AND c.current_published_version_id IS NOT DISTINCT FROM NEW.previous_version_id
            AND rs.admitted_parent_version_id IS NOT DISTINCT FROM NEW.previous_version_id
            AND rs.state = 'running' AND rs.lease_expires_at > clock_timestamp()
            AND rs.dirty_seq = rs.run_dirty_seq
            AND a.request_key = 'proposal:' || c.id || ':' || cv.id || ':' || rs.refresh_generation
            AND a.state = 'completed' AND a.outcome = 'accepted'
            AND a.requested_by_actor_id = NEW.actor_id
            AND cfg.state = 'enabled' AND cfg.current_version_id = cv.id
            AND cfg.editor_enabled_version_id = cv.id
            AND cfg.editor_switched_at > COALESCE((
              SELECT max(committed_at) FROM curation_configuration_activations
              WHERE configuration_id = cfg.id AND action = 'activate'), '-infinity'::timestamptz)
            AND cv.manifest->>'editor_publication' = 'single_editor_v1'
            AND (cv.manifest->'editor'->>'bot_actor_id')::bigint = NEW.actor_id
            AND (cv.manifest->'editor'->>'model_config_id')::bigint = a.model_config_id
            AND cv.manifest->'editor'->>'model_config_hash' = mc.config_hash
            AND cv.manifest->'editor'->>'instruction_version' = mc.instruction_version
            AND p.state = 'admitted' AND p.bot_actor_id = NEW.actor_id
            AND p.current_version_id = (cv.manifest->'editor'->>'profile_version_id')::bigint
            AND EXISTS (SELECT 1 FROM editorial_composition_memberships m
              JOIN lexemes l ON l.object_id = m.object_id WHERE m.composition_id = c.id
                AND l.slug IN ('nepotism','greed','war','love','coward','patience','justice','truth','hope','bestiality'))
            AND NOT EXISTS (SELECT 1 FROM editorial_composition_memberships m
              JOIN lexemes l ON l.object_id = m.object_id WHERE m.composition_id = c.id
                AND l.slug NOT IN ('nepotism','greed','war','love','coward','patience','justice','truth','hope','bestiality'))
        ) THEN
          RAISE EXCEPTION 'single-editor publication requires its enabled policy, accepted attempt, live unchanged fence and open pilot parent'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
      END IF;
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
        IF NOT EXISTS (SELECT 1 FROM editorial_composition_versions
          WHERE id = NEW.published_version_id AND origin = 'manual') THEN
          RAISE EXCEPTION 'operator publication requires a manual version'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

    RETURN NEW; END; $$
    """
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM editorial_composition_publications WHERE authority_kind = 'single_editor') THEN
        RAISE EXCEPTION 'single-editor history exists: disable automation and roll forward; never erase history';
      END IF;
    END $$;
    """

    execute "ALTER TABLE editorial_composition_publications DROP CONSTRAINT editorial_composition_publications_authority"

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_authority,
             check: "authority_kind IN ('operator')"
           )

    execute "ALTER TABLE editorial_composition_publications DROP CONSTRAINT editorial_composition_publications_shape"

    create constraint(
             :editorial_composition_publications,
             :editorial_composition_publications_shape,
             check: """
             btrim(reason) <> '' AND ((action = 'publish' AND published_version_id IS NOT NULL AND authorizing_review_id IS NOT NULL AND eligibility_fingerprint IS NOT NULL) OR (action = 'withdraw' AND previous_version_id IS NOT NULL AND published_version_id IS NULL AND authorizing_review_id IS NULL AND eligibility_fingerprint IS NULL))
             """
           )

    execute """
    CREATE OR REPLACE FUNCTION editorial_composition_publications_authority() RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE latest record; BEGIN
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
        IF NOT EXISTS (SELECT 1 FROM editorial_composition_versions
          WHERE id = NEW.published_version_id AND origin = 'manual') THEN
          RAISE EXCEPTION 'operator publication requires a manual version'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
      END IF;

    RETURN NEW; END; $$
    """
  end
end
