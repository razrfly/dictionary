defmodule DevilsDictionary.Repo.Migrations.CreateCurationCitations do
  use Ecto.Migration

  def up do
    execute(~S"""
    ALTER TABLE discovery_results ADD COLUMN source_record_revision_id bigint REFERENCES source_record_revisions(id) ON DELETE SET NULL;
    """)

    execute(~S"""
    CREATE INDEX discovery_results_revision_index ON discovery_results(source_record_revision_id);
    """)

    execute(~S"""
    ALTER TABLE discovery_runs ADD COLUMN retention_seconds bigint, ADD COLUMN retention_policy_sha256 text;
    """)

    execute(~S"""
    ALTER TABLE source_record_revisions ADD COLUMN discovery_retain_until timestamptz,
    ADD COLUMN discovery_retention_policy_sha256 text, ADD COLUMN discovery_last_observed_at timestamptz;
    """)

    execute(~S"""
    ALTER TABLE curation_refresh_states ADD COLUMN shelf_focus text CHECK (shelf_focus IN ('news','images','films','music','books','poems','quotes'));
    """)

    execute(~S"""
    CREATE TABLE curation_shelf_citations (
    id bigserial PRIMARY KEY,
    source_id bigint NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
    external_ref_sha256 text NOT NULL,
    cited_source_record_id bigint NOT NULL, cited_revision_id bigint NOT NULL, cited_checksum text NOT NULL,
    cited_object_id bigint,
    source_record_id bigint REFERENCES source_records(id) ON DELETE SET NULL,
    source_record_revision_id bigint REFERENCES source_record_revisions(id) ON DELETE SET NULL,
    discovery_result_id bigint NOT NULL UNIQUE, discovery_run_id bigint NOT NULL,
    mapping_id bigint NOT NULL, target_object_id bigint NOT NULL, adapter_version text NOT NULL,
    observed_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
    expiry_origin text NOT NULL CHECK (expiry_origin IN ('captured_run','legacy_fallback')),
    retention_seconds bigint, policy_sha256 text, fallback_policy_sha256 text,
    observation_policy_state text NOT NULL CHECK (observation_policy_state IN ('captured','legacy_not_recorded','legacy_fallback')),
    field_policy text NOT NULL CHECK (field_policy='shelf-fields-v1'), shelf_kind text NOT NULL CHECK (shelf_kind IN ('news','images','films','music','books','poems','quotes')),
    content_date_meaning text, content_date_precision text,
    match_kind text, match_evidence text, match_relation text, match_level text,
    link_sha256 text, created_by_actor_id bigint NOT NULL REFERENCES actors(id), inserted_at timestamptz NOT NULL,
    CHECK ((observation_policy_state='captured' AND retention_seconds>0 AND policy_sha256 IS NOT NULL AND fallback_policy_sha256 IS NULL)
    OR (observation_policy_state='legacy_not_recorded' AND policy_sha256 IS NULL AND fallback_policy_sha256 IS NULL)
    OR (observation_policy_state='legacy_fallback' AND policy_sha256 IS NULL AND fallback_policy_sha256 IS NOT NULL))
    );
    """)

    execute(~S"""
    CREATE INDEX curation_shelf_citations_revision_index ON curation_shelf_citations(source_record_revision_id);
    """)

    execute(~S"""
    ALTER TABLE editorial_composition_items ADD COLUMN shelf_citation_id bigint REFERENCES curation_shelf_citations(id) ON DELETE RESTRICT;
    """)

    execute(~S"""
    CREATE INDEX editorial_composition_items_citation_index ON editorial_composition_items(shelf_citation_id);
    """)

    execute(~S"""
    CREATE TABLE curation_item_bases (
    item_id bigint PRIMARY KEY REFERENCES editorial_composition_items(id) ON DELETE RESTRICT,
    origin text NOT NULL CHECK (origin IN ('owner','model','legacy_unknown')),
    origin_item_id bigint NOT NULL, original_reference jsonb NOT NULL,
    attempt_id bigint REFERENCES inference_attempts(id) ON DELETE RESTRICT,
    evidence_kind text, fields_version text, supplied_sha256 text, representation jsonb,
    witness_assertion_revision_id bigint, reviewed_by_actor_id bigint REFERENCES actors(id),
    reason_rewritten boolean NOT NULL DEFAULT false,
    CHECK (origin <> 'model' OR attempt_id IS NOT NULL),
    CHECK (origin='legacy_unknown' OR (fields_version IS NOT NULL AND supplied_sha256 IS NOT NULL)),
    CHECK (origin='legacy_unknown' OR evidence_kind <> 'claim' OR representation IS NOT NULL)
    );
    """)

    execute(~S"""
    CREATE FUNCTION curation_citation_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'citation identity is retained'; END IF;
    IF TG_TABLE_NAME='curation_shelf_citations' THEN
    IF
    (to_jsonb(NEW)-'source_record_id'-'source_record_revision_id')=(to_jsonb(OLD)-'source_record_id'-'source_record_revision_id')
    AND (NEW.source_record_id IS NOT DISTINCT FROM OLD.source_record_id OR NEW.source_record_id IS NULL)
    AND (NEW.source_record_revision_id IS NOT DISTINCT FROM OLD.source_record_revision_id OR NEW.source_record_revision_id IS NULL)
    THEN RETURN NEW; END IF;
    END IF;
    RAISE EXCEPTION 'citation and basis rows are immutable' USING ERRCODE='integrity_constraint_violation';
    END $$;
    """)

    execute(~S"""
    CREATE TRIGGER curation_shelf_citations_immutable BEFORE UPDATE OR DELETE ON curation_shelf_citations FOR EACH ROW EXECUTE FUNCTION curation_citation_immutable();
    """)

    execute(~S"""
    CREATE TRIGGER curation_item_bases_immutable BEFORE UPDATE OR DELETE ON curation_item_bases FOR EACH ROW EXECUTE FUNCTION curation_citation_immutable();
    """)

    execute(~S"""
    CREATE FUNCTION curation_shelf_citation_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE observation record; payload jsonb; fallback jsonb;
    BEGIN
    SELECT d.*, r.mapping_id,r.adapter_version,r.completed_at,r.expires_at,r.status,
    r.retention_seconds,r.retention_policy_sha256,r.display_allowed AS run_allowed,
    m.target_object_id,m.source_id,s.slug AS source_slug,s.active AS source_active,sr.display_allowed AS record_allowed,
    rev.checksum,rev.payload INTO observation
    FROM discovery_results d JOIN discovery_runs r ON r.id=d.run_id
    JOIN discovery_mappings m ON m.id=r.mapping_id JOIN sources s ON s.id=m.source_id
    JOIN source_records sr ON sr.id=d.source_record_id
    JOIN source_record_revisions rev ON rev.id=NEW.cited_revision_id AND rev.source_record_id=sr.id
    WHERE d.id=NEW.discovery_result_id;
    IF NOT FOUND OR observation.status<>'succeeded' OR NOT observation.display_allowed OR NOT observation.run_allowed
    OR NOT observation.source_active OR NOT observation.record_allowed OR NEW.expires_at<=statement_timestamp()
    OR NEW.shelf_kind IS DISTINCT FROM (CASE WHEN observation.source_slug IN ('guardian','bing-news') THEN 'news' WHEN observation.source_slug IN ('pexels','unsplash','openverse','commons','met') THEN 'images' WHEN observation.source_slug='cinegraph' THEN 'films' WHEN observation.source_slug='spotify' THEN 'music' WHEN observation.source_slug='open-library' THEN 'books' WHEN observation.source_slug='poetrydb' THEN 'poems' WHEN observation.source_slug='wikiquote' THEN 'quotes' END)
    OR observation.run_id<>NEW.discovery_run_id OR observation.mapping_id<>NEW.mapping_id
    OR observation.target_object_id<>NEW.target_object_id OR observation.source_id<>NEW.source_id
    OR observation.source_record_id<>NEW.cited_source_record_id
    OR observation.checksum<>NEW.cited_checksum OR observation.adapter_version<>NEW.adapter_version
    OR NEW.external_ref_sha256 IS DISTINCT FROM encode(sha256(convert_to(observation.external_namespace || ':' || observation.external_id,'UTF8')),'hex')
    OR NEW.link_sha256 IS DISTINCT FROM (CASE WHEN observation.preview_metadata->>'source_url' IS NULL THEN NULL ELSE encode(sha256(convert_to(observation.preview_metadata->>'source_url','UTF8')),'hex') END)
    OR (observation.source_record_revision_id IS NULL AND
    (SELECT count(*) FROM source_record_revisions v WHERE v.source_record_id=observation.source_record_id
    AND v.payload->'match_details'=observation.match_details
    AND v.payload->'preview_metadata'=(observation.preview_metadata-'creators')
    AND v.payload->>'external_namespace'=observation.external_namespace
    AND v.payload->>'external_id'=observation.external_id)<>1)
    OR observation.object_id IS DISTINCT FROM NEW.cited_object_id
    OR NEW.source_record_id IS DISTINCT FROM NEW.cited_source_record_id
    OR NEW.source_record_revision_id IS DISTINCT FROM NEW.cited_revision_id
    OR observation.completed_at IS DISTINCT FROM NEW.observed_at
    OR (observation.source_record_revision_id IS NOT NULL AND observation.source_record_revision_id<>NEW.cited_revision_id)
    OR observation.payload->'match_details' IS DISTINCT FROM observation.match_details
    OR observation.payload->'preview_metadata' IS DISTINCT FROM (observation.preview_metadata-'creators')
    OR observation.payload->>'external_namespace' IS DISTINCT FROM observation.external_namespace
    OR observation.payload->>'external_id' IS DISTINCT FROM observation.external_id
    OR (observation.retention_policy_sha256 IS NOT NULL AND
    (NEW.policy_sha256 IS DISTINCT FROM observation.retention_policy_sha256
    OR NEW.retention_seconds IS DISTINCT FROM observation.retention_seconds
    OR NEW.observation_policy_state<>'captured' OR NEW.expires_at IS DISTINCT FROM observation.expires_at))
    THEN RAISE EXCEPTION 'citation must bind the exact eligible observation' USING ERRCODE='check_violation'; END IF;
    IF observation.retention_policy_sha256 IS NOT NULL THEN
    IF NEW.observation_policy_state<>'captured' OR NEW.expiry_origin<>'captured_run' THEN
     RAISE EXCEPTION 'captured policy classification required'; END IF;
    ELSIF observation.expires_at>observation.completed_at THEN
    IF NEW.observation_policy_state<>'legacy_not_recorded' OR NEW.policy_sha256 IS NOT NULL
      OR NEW.retention_seconds IS NOT NULL OR NEW.fallback_policy_sha256 IS NOT NULL
      OR NEW.expiry_origin<>'captured_run' OR NEW.expires_at IS DISTINCT FROM observation.expires_at THEN
     RAISE EXCEPTION 'legacy stored expiry is preserved without an invented policy'; END IF;
    ELSE
    fallback := (NULLIF(current_setting('devils_dictionary.citation_policy_context',true),'')::jsonb)->observation.source_slug;
    IF fallback IS NULL OR NEW.observation_policy_state<>'legacy_fallback' OR NEW.expiry_origin<>'legacy_fallback'
      OR NEW.policy_sha256 IS NOT NULL OR NEW.retention_seconds IS DISTINCT FROM (fallback->>'seconds')::bigint
      OR NEW.fallback_policy_sha256 IS DISTINCT FROM fallback->>'hash'
      OR NEW.expires_at IS DISTINCT FROM (observation.completed_at+((fallback->>'seconds')::bigint*interval '1 second')) THEN
     RAISE EXCEPTION 'legacy fallback requires the transaction policy context and its exact deadline'; END IF;
    END IF;
    RETURN NEW;
    END $$;
    """)

    execute(~S"""
    CREATE TRIGGER curation_shelf_citation_insert BEFORE INSERT ON curation_shelf_citations FOR EACH ROW EXECUTE FUNCTION curation_shelf_citation_insert();
    """)

    execute(~S"""
    CREATE FUNCTION discovery_run_retention_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
    IF OLD.retention_policy_sha256 IS NOT NULL AND
    ROW(NEW.retention_seconds,NEW.retention_policy_sha256,NEW.completed_at,NEW.expires_at)
    IS DISTINCT FROM ROW(OLD.retention_seconds,OLD.retention_policy_sha256,OLD.completed_at,OLD.expires_at)
    THEN RAISE EXCEPTION 'captured observation policy is immutable'; END IF;
    RETURN NEW;
    END $$;
    """)

    execute(~S"""
    CREATE TRIGGER discovery_run_retention_guard BEFORE UPDATE ON discovery_runs FOR EACH ROW EXECUTE FUNCTION discovery_run_retention_guard();
    """)

    execute(~S"""
    ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape;
    """)

    execute(~S"""
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
    """)

    execute(~S"""
    CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      author record;
      subject_kind text;
      version record;
      source record;
    BEGIN

    -- A work pinned from a committed catalog may have no registry
    -- object yet; everything else names the object it shows.
    IF NEW.item_object_id IS NULL AND
       NOT (NEW.item_kind = 'work' AND (NEW.catalog_manifest IS NOT NULL OR NEW.shelf_citation_id IS NOT NULL)) THEN
      RAISE EXCEPTION 'an item names its registry object'
        USING ERRCODE = 'check_violation';
    END IF;

    IF (NEW.meaning_sense_revision_id IS NULL) = (NEW.meaning_lexeme_id IS NULL) THEN
      RAISE EXCEPTION 'an item has exactly one intended meaning'
        USING ERRCODE = 'check_violation';
    END IF;

    IF (NEW.item_kind = 'content' AND NEW.content_revision_id IS NULL)
       OR (NEW.item_kind IN ('sense_quotation','sense_definition') AND
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

    IF NEW.item_kind = 'claim' AND NOT EXISTS (
      SELECT 1 FROM assertion_revisions a JOIN predicates p ON p.id=a.predicate_id
      WHERE a.id=NEW.assertion_revision_id AND a.subject_object_id=NEW.item_object_id
      AND p.key IN ('instance_of','refers_to','lexeme_entity_candidate')) THEN
      RAISE EXCEPTION 'a linked claim names its exact supported claim' USING ERRCODE='check_violation';
    END IF;
    IF NEW.shelf_citation_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM curation_shelf_citations c
      JOIN editorial_composition_versions v ON v.id=NEW.composition_version_id
      JOIN editorial_composition_memberships m ON m.composition_id=v.composition_id AND m.object_id=c.target_object_id
      WHERE c.id=NEW.shelf_citation_id
        AND NEW.source_record_revision_id=c.cited_revision_id
        AND NEW.item_object_id IS NOT DISTINCT FROM c.cited_object_id
        AND NEW.meaning_lexeme_id=c.target_object_id AND NEW.meaning_sense_revision_id IS NULL
    ) THEN
      RAISE EXCEPTION 'a shelf item matches its observation and scope' USING ERRCODE='check_violation';
    END IF;
    NEW.required_references := curation_item_references(NEW);


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

        IF NEW.shelf_citation_id IS DISTINCT FROM source.shelf_citation_id
           OR NEW.item_kind IS DISTINCT FROM source.item_kind
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

    execute(~S"""
    CREATE OR REPLACE FUNCTION editorial_arrangement_hash(version_id bigint) RETURNS text AS $$
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
                       curation_field(i.note_author_label) || CASE WHEN i.shelf_citation_id IS NULL THEN '' ELSE curation_field(i.shelf_citation_id::text) END,
                       '' ORDER BY i.role, i.position), ''), 'UTF8')), 'hex')
                FROM editorial_composition_items i
               WHERE i.composition_version_id = version_id;
            $$ LANGUAGE sql STABLE;
    """)

    execute(~S"""
    CREATE FUNCTION discovery_retained_payload(slug text, payload jsonb, redaction_at timestamptz) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE retained jsonb; metadata jsonb; allowed text[];
    BEGIN
    IF slug IN ('poetrydb','wikiquote','commons','met') OR NOT (payload ?& ARRAY['external_namespace','external_id','preview_metadata','match_details'] OR payload ? '_discovery_redaction') THEN RETURN payload; END IF;
    retained := jsonb_build_object('external_namespace',payload->'external_namespace');
    IF slug IN ('cinegraph','open-library') THEN
    retained := retained || jsonb_build_object('external_id',payload->'external_id','identifiers',COALESCE(payload->'identifiers','[]'::jsonb));
    ELSE
    retained := retained || jsonb_build_object('external_ref_sha256',COALESCE(payload->>'external_ref_sha256',encode(sha256(convert_to((payload->>'external_namespace') || ':' || (payload->>'external_id'),'UTF8')),'hex')));
    END IF;
    IF slug='open-library' THEN
    allowed := ARRAY['title','year','author','author_keys','olid','ia','source_url','read_url','cover_url'];
    SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) INTO metadata FROM jsonb_each(COALESCE(payload->'preview_metadata','{}')) WHERE key=ANY(allowed);
    retained := retained || jsonb_build_object('preview_metadata',metadata);
    END IF;
    IF payload ? '_discovery_redaction' AND (payload-'_discovery_redaction')=retained THEN RETURN payload; END IF;
    RETURN retained || jsonb_build_object('_discovery_redaction',COALESCE(payload->'_discovery_redaction',jsonb_build_object('policy','shelf-fields-v1','at',redaction_at,'removed_fields',ARRAY['provider_payload'])));
    END $$;
    """)

    execute(~S"""
    CREATE FUNCTION discovery_retained_record(slug text, record jsonb, redaction_at timestamptz) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN slug='cinegraph' THEN record || jsonb_build_object('url',NULL) WHEN slug IN ('open-library','poetrydb','wikiquote','commons','met') THEN record
    ELSE record || jsonb_build_object('url',NULL,'external_id',CASE WHEN record->>'external_id' LIKE 'redacted-discovery:%' THEN record->>'external_id' ELSE 'redacted-discovery:' || encode(sha256(convert_to(record->>'external_id','UTF8')),'hex') END) END;
    $$;
    """)

    execute(~S"""
    CREATE FUNCTION curation_citations_rollback_eligible() RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT (EXISTS(SELECT 1 FROM curation_shelf_citations) OR EXISTS(SELECT 1 FROM curation_item_bases)
    OR EXISTS(SELECT 1 FROM editorial_composition_items WHERE item_kind IN ('claim','sense_definition') OR shelf_citation_id IS NOT NULL)
    OR EXISTS(SELECT 1 FROM curation_refresh_states WHERE shelf_focus IS NOT NULL)
    OR EXISTS(SELECT 1 FROM curation_configuration_versions WHERE manifest ? 'refresh_window_seconds')
    OR EXISTS(SELECT 1 FROM discovery_runs WHERE retention_seconds IS NOT NULL OR retention_policy_sha256 IS NOT NULL)
    OR EXISTS(SELECT 1 FROM source_record_revisions WHERE discovery_retain_until IS NOT NULL OR discovery_retention_policy_sha256 IS NOT NULL OR discovery_last_observed_at IS NOT NULL OR revision_key LIKE 'redacted-discovery:%')
    OR EXISTS(SELECT 1 FROM source_records WHERE external_id LIKE 'redacted-discovery:%'));
    $$;
    """)
  end

  @doc false
  def down_guard,
    do: ~S"""
    DO $$ BEGIN IF NOT curation_citations_rollback_eligible() THEN RAISE EXCEPTION 'citation/retention state exists: roll forward, code revert and migration down are unsafe'; END IF; END $$;
    """

  def down do
    execute(down_guard())

    execute(~S"""
    CREATE OR REPLACE FUNCTION editorial_composition_items_complete() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      author record;
      subject_kind text;
      version record;
      source record;
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

    execute(~S"""
    ALTER TABLE editorial_composition_items DROP CONSTRAINT editorial_composition_items_shape;
    """)

    execute(~S"""
    ALTER TABLE editorial_composition_items ADD CONSTRAINT editorial_composition_items_shape CHECK (
    role IN ('lead', 'highlight')
    AND item_kind IN ('content', 'sense_quotation', 'work', 'exemplar')
    AND selection_origin IN ('manual','model') 
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
    );
    """)

    execute(~S"""
    CREATE OR REPLACE FUNCTION editorial_arrangement_hash(version_id bigint) RETURNS text AS $$
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
    """)

    execute(~S"""
    DROP FUNCTION curation_citations_rollback_eligible();
    """)

    execute(~S"""
    DROP TRIGGER discovery_run_retention_guard ON discovery_runs;
    """)

    execute(~S"""
    DROP FUNCTION discovery_run_retention_guard();
    """)

    execute(~S"""
    DROP TABLE curation_item_bases;
    """)

    execute(~S"""
    ALTER TABLE editorial_composition_items DROP COLUMN shelf_citation_id;
    """)

    execute(~S"""
    DROP TABLE curation_shelf_citations;
    """)

    execute(~S"""
    DROP FUNCTION curation_shelf_citation_insert();
    """)

    execute(~S"""
    DROP FUNCTION curation_citation_immutable();
    """)

    execute(~S"""
    ALTER TABLE discovery_results DROP COLUMN source_record_revision_id;
    """)

    execute(~S"""
    ALTER TABLE discovery_runs DROP COLUMN retention_seconds,DROP COLUMN retention_policy_sha256;
    """)

    execute(~S"""
    ALTER TABLE source_record_revisions DROP COLUMN discovery_retain_until,DROP COLUMN discovery_retention_policy_sha256,DROP COLUMN discovery_last_observed_at;
    """)

    execute(~S"""
    ALTER TABLE curation_refresh_states DROP COLUMN shelf_focus;
    """)

    execute(~S"""
    DROP FUNCTION discovery_retained_payload(text,jsonb,timestamptz);
    """)

    execute(~S"""
    DROP FUNCTION discovery_retained_record(text,jsonb,timestamptz);
    """)
  end
end
