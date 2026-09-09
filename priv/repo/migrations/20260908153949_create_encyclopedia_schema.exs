defmodule DevilsDictionary.Repo.Migrations.CreateEncyclopediaSchema do
  @moduledoc """
  The encyclopedia model of #74. An addressable-object registry with typed
  domain tables, and relationships that are first-class, attributed and
  revisioned.

  Decisions and the evidence behind them: `docs/adr/0001-encyclopedia-model.md`
  and `docs/spikes/2026-09-gate0/`. Everything structural here was run against
  the full 1.16 M-assertion corpus before it was written down.

  Conventions carried forward from the MVP-0 baseline, unchanged, because they
  are why a new source costs no migration: bigint identity ids;
  `timestamps(type: :utc_datetime_usec)`; enum-like columns are plain strings
  backed by `Ecto.Enum`, never Postgres enum types; `lemma` is case-sensitive
  text; raw payloads are JSONB.

  ## One baseline, not a rebuild path

  This replaces the MVP-0 baseline migration outright rather than transforming
  it. ADR decision 9: nothing is deployed and the data is disposable, so writing
  a rebuild path over thirteen tables we are deleting would be work spent on
  rows nobody wants. No row is migrated anywhere, and there is no compatibility
  layer to read from.
  """

  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", ""

    # ── the source registry, retained from MVP-0 ─────────────────────────────
    # #74 §B: "Keep the existing source registry, import runs and archived
    # inputs." These four tables are unchanged in shape; what changes is what
    # hangs off them.

    # One row per provider, human channel or bot. Tier, kind, access and licence
    # live HERE, never on content rows — that is what lets a new source arrive
    # with the UI already knowing how to dress it.
    create table(:sources) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :tier, :string, null: false
      add :kind, :string, null: false
      add :access, :string, null: false
      add :era_year, :integer
      add :license, :string
      add :license_url, :string
      add :homepage, :string
      add :url_template, :string
      add :attribution, :string
      add :active, :boolean, null: false, default: true
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:slug])

    # A scope is data: `priv/scopes/<slug>.json`, read by `Catalog.scopes/0`.
    # `rules["bars"]` holds the scope's own scorecard thresholds, because
    # grading an 809-word scope of abstract nouns by Animals' numbers grades the
    # scope rather than the pipeline.
    create table(:scopes) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :rules, :map, null: false, default: %{}
      add :stats, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scopes, [:slug])

    # Stable source-native record identity. The payload has moved out to
    # `source_record_revisions` -- see below.
    create table(:source_records) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :external_id, :string, null: false
      add :url, :string
      add :content_hash, :string
      add :fetched_at, :utc_datetime_usec
      add :changed_at, :utc_datetime_usec
      add :materialized_at, :utc_datetime_usec
      add :absent_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_records, [:source_id, :external_id])
    create index(:source_records, [:source_id, :materialized_at])
    create index(:source_records, [:absent_until])
    create index(:source_records, [:changed_at])

    create table(:import_runs) do
      add :source_id, references(:sources, on_delete: :delete_all)
      add :scope_id, references(:scopes, on_delete: :nilify_all)
      add :task, :string, null: false
      add :status, :string, null: false, default: "running"
      add :stats, :map, null: false, default: %{}
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
    end

    create index(:import_runs, [:source_id, :started_at])

    # ── source inputs: the manifest, in the database ─────────────────────────
    # `mix dd.manifest` verifies the file; this records which input an import
    # run actually read, so a row can be traced to the bytes it came from.
    create table(:source_inputs) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :edition, :string
      add :archive_locator, :string, null: false
      add :acquisition_url, :string
      add :acquired_on, :date
      add :byte_count, :bigint
      add :sha256, :string
      add :parser_version, :string
      add :license, :string
      add :url_is_rolling, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_inputs, [:source_id, :archive_locator, :sha256])

    # ── source record revisions ──────────────────────────────────────────────
    # The audit's finding #1 and #2 both trace back to `source_records.raw`
    # being overwritten in place: a cited revision could not be retained, so
    # "what did this claim actually rest on" had no answer. Identity stays in
    # `source_records`; the payload moves here and is never updated.
    create table(:source_record_revisions) do
      add :source_record_id, references(:source_records, on_delete: :delete_all), null: false
      # The content hash, still taken on the payload *as fetched*, before
      # `trim/1` — so tightening what we keep never reads as a change upstream.
      add :revision_key, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :checksum, :string
      add :observed_at, :utc_datetime_usec
      add :import_run_id, references(:import_runs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_record_revisions, [:source_record_id, :revision_key])
    create index(:source_record_revisions, [:source_record_id, :observed_at])

    # ── the registry ─────────────────────────────────────────────────────────
    create table(:objects) do
      add :kind, :string, null: false
      add :lifecycle_state, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:objects, :objects_kind,
             check: "kind IN ('lexeme','sense','entity','content')"
           )

    create constraint(:objects, :objects_lifecycle_state,
             check: "lifecycle_state IN ('active','retired','merged','split')"
           )

    # The handle every subtype's composite foreign key hangs off. This is what
    # gives an assertion a real FK to "whatever kind of thing this endpoint is".
    create unique_index(:objects, [:id, :kind], name: :objects_id_kind_index)
    create index(:objects, [:kind, :lifecycle_state])

    # ── lexemes ──────────────────────────────────────────────────────────────
    create table(:lexemes, primary_key: false) do
      add :object_id, :bigint, primary_key: true
      # GENERATED, so no writer can set it wrong, and the composite FK below
      # cannot be satisfied by an object of another kind.
      add :kind, :string, generated: "ALWAYS AS ('lexeme') STORED"
      add :language_tag, :string, null: false, default: "en"
      add :lemma, :text, null: false
      add :part_of_speech, :string, null: false, default: "unknown"
      # Case- and punctuation-preserving. This is the `C++` fix: `C++`, `C+`
      # and `c` are three identities, and a slug never asserts equivalence.
      add :lexical_key, :text, null: false
      add :slug, :string, null: false
      add :canonical_lexeme_id, :bigint
      add :etymology, :text
      # Which source wrote the etymology, and which source introduced the word.
      # Both are real facts a reader is shown -- the word page prints "Wiktionary"
      # beside an etymology, and A8's index-hit rate is "how many of Bierce's
      # headwords did some other source already attest". They were columns in
      # MVP-0 and stay columns: burying a queried fact in `metadata` to keep a
      # table narrow is how a schema stops answering questions.
      add :etymology_source_id, references(:sources, on_delete: :nilify_all)
      add :origin_source_id, references(:sources, on_delete: :nilify_all)
      # The list of `%{"ipa" => ..., "tags" => [...]}` lives under "items": a bare
      # JSON array is legal jsonb but not a legal Ecto `:map`.
      add :pronunciations, :map, null: false, default: %{}
      add :source_ids, {:array, :bigint}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :enriched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE lexemes
              ADD CONSTRAINT lexemes_object_fkey
              FOREIGN KEY (object_id, kind) REFERENCES objects (id, kind) ON DELETE CASCADE
            """,
            "ALTER TABLE lexemes DROP CONSTRAINT lexemes_object_fkey"

    execute """
            ALTER TABLE lexemes
              ADD CONSTRAINT lexemes_canonical_fkey
              FOREIGN KEY (canonical_lexeme_id) REFERENCES lexemes (object_id) ON DELETE SET NULL
            """,
            "ALTER TABLE lexemes DROP CONSTRAINT lexemes_canonical_fkey"

    create unique_index(:lexemes, [:lexical_key])
    create index(:lexemes, [:slug])
    create index(:lexemes, [:canonical_lexeme_id])
    create index(:lexemes, [:origin_source_id])
    create index(:lexemes, [:enriched_at])
    # `lookup/2`'s first step.
    execute "CREATE INDEX lexemes_lower_lemma_index ON lexemes (lower(lemma))",
            "DROP INDEX lexemes_lower_lemma_index"

    # Search. Measured at 43 ms against `similarity() > 0.3`'s 420 ms on the
    # 1.5 M-row index, because the `%` operator uses this and the function does
    # not — see `Lexicon.Browse`.
    execute "CREATE INDEX lexemes_lemma_trgm_index ON lexemes USING gin (lemma gin_trgm_ops)",
            "DROP INDEX lexemes_lemma_trgm_index"

    # Carries `wikt_categories`, which the scope rules query.
    execute "CREATE INDEX lexemes_metadata_index ON lexemes USING gin (metadata)",
            "DROP INDEX lexemes_metadata_index"

    # ── lexeme forms ─────────────────────────────────────────────────────────
    # Forms leave `lexemes.forms` JSONB and become rows, so each carries the
    # source revision that attested it.
    create table(:lexeme_forms) do
      add :lexeme_id, references(:lexemes, column: :object_id, on_delete: :delete_all),
        null: false

      add :written_form, :text, null: false
      add :form_kind, :string
      add :language_tag, :string, null: false, default: "en"
      add :tags, {:array, :string}, null: false, default: []

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lexeme_forms, [:lexeme_id, :written_form, :form_kind])

    execute "CREATE INDEX lexeme_forms_lower_written_form_index ON lexeme_forms (lower(written_form))",
            "DROP INDEX lexeme_forms_lower_written_form_index"

    # ── senses ───────────────────────────────────────────────────────────────
    create table(:senses, primary_key: false) do
      add :object_id, :bigint, primary_key: true
      add :kind, :string, generated: "ALWAYS AS ('sense') STORED"

      add :lexeme_id, references(:lexemes, column: :object_id, on_delete: :delete_all),
        null: false

      add :source_id, references(:sources, on_delete: :delete_all), null: false
      # What the source called it. Provenance, NOT identity — identity is
      # matched on content, so a reordered source cannot repoint an attachment.
      add :external_key, :string, null: false
      add :identity_state, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE senses
              ADD CONSTRAINT senses_object_fkey
              FOREIGN KEY (object_id, kind) REFERENCES objects (id, kind) ON DELETE CASCADE
            """,
            "ALTER TABLE senses DROP CONSTRAINT senses_object_fkey"

    create constraint(:senses, :senses_identity_state,
             check: "identity_state IN ('active','needs_review','retired')"
           )

    # **Not unique**, and that is the point. `external_key` is what the source
    # called this meaning — provenance — and a position-based key is reusable by
    # construction: delete a Wiktionary sense from the middle and the key that
    # said `#5` now says `#4`. A meaning that keeps its identity through a
    # reorder therefore takes a key another sense still holds until its own
    # retirement lands, and a unique index would refuse the very case #74 exists
    # to make safe. Identity is `object_id`; this is an index for lookup.
    create index(:senses, [:source_id, :external_key])
    create index(:senses, [:lexeme_id, :source_id])
    create index(:senses, [:lexeme_id, :identity_state])

    create table(:sense_revisions) do
      add :sense_id, references(:senses, column: :object_id, on_delete: :delete_all), null: false
      add :revision_number, :integer, null: false
      add :gloss, :text
      add :group_key, :string
      # Ordering only. Never identity — this is the audit's finding #2.
      add :position, :integer, null: false, default: 0
      add :tags, {:array, :string}, null: false, default: []
      add :topics, {:array, :string}, null: false, default: []
      add :examples, :map, null: false, default: %{}
      add :url, :string
      add :metadata, :map, null: false, default: %{}
      add :lifecycle_state, :string, null: false, default: "active"
      add :is_current, :boolean, null: false, default: false

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:sense_revisions, :sense_revisions_lifecycle_state,
             check: "lifecycle_state IN ('active','withdrawn','superseded')"
           )

    create unique_index(:sense_revisions, [:sense_id, :revision_number])
    create index(:sense_revisions, [:group_key])
    # At most one current revision per sense. "At least one" is the deferred
    # constraint trigger below; a partial unique index cannot prove it, and #74
    # is explicit about the difference.
    create unique_index(:sense_revisions, [:sense_id],
             where: "is_current",
             name: :sense_revisions_one_current_index
           )

    # ── entities ─────────────────────────────────────────────────────────────
    create table(:entities, primary_key: false) do
      add :object_id, :bigint, primary_key: true
      add :kind, :string, generated: "ALWAYS AS ('entity') STORED"
      add :entity_kind, :string, null: false
      add :preferred_label, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE entities
              ADD CONSTRAINT entities_object_fkey
              FOREIGN KEY (object_id, kind) REFERENCES objects (id, kind) ON DELETE CASCADE
            """,
            "ALTER TABLE entities DROP CONSTRAINT entities_object_fkey"

    create constraint(:entities, :entities_entity_kind,
             check:
               "entity_kind IN ('person','organization','concept','event','work','edition','place','artifact','taxon','other')"
           )

    # What the person/work/edition subtypes hang their own composite FK off, so
    # a subtype cannot attach to an entity of the wrong kind.
    create unique_index(:entities, [:object_id, :entity_kind],
             name: :entities_object_id_entity_kind_index
           )

    create index(:entities, [:entity_kind])

    execute "CREATE INDEX entities_label_trgm_index ON entities USING gin (preferred_label gin_trgm_ops)",
            "DROP INDEX entities_label_trgm_index"

    create table(:person_details, primary_key: false) do
      add :entity_id, :bigint, primary_key: true
      add :entity_kind, :string, generated: "ALWAYS AS ('person') STORED"
      add :birth_date, :date
      add :death_date, :date

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE person_details
              ADD CONSTRAINT person_details_entity_fkey
              FOREIGN KEY (entity_id, entity_kind)
              REFERENCES entities (object_id, entity_kind) ON DELETE CASCADE
            """,
            "ALTER TABLE person_details DROP CONSTRAINT person_details_entity_fkey"

    create table(:work_details, primary_key: false) do
      add :entity_id, :bigint, primary_key: true
      add :entity_kind, :string, generated: "ALWAYS AS ('work') STORED"
      add :work_kind, :string
      add :original_language, :string
      add :first_published_year, :integer

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE work_details
              ADD CONSTRAINT work_details_entity_fkey
              FOREIGN KEY (entity_id, entity_kind)
              REFERENCES entities (object_id, entity_kind) ON DELETE CASCADE
            """,
            "ALTER TABLE work_details DROP CONSTRAINT work_details_entity_fkey"

    create table(:edition_details, primary_key: false) do
      add :entity_id, :bigint, primary_key: true
      add :entity_kind, :string, generated: "ALWAYS AS ('edition') STORED"
      # An edition belongs to a work, and the FK targets `work_details` rather
      # than `entities`, so an edition of a person is not expressible.
      add :work_id, references(:work_details, column: :entity_id, on_delete: :restrict)
      add :edition_label, :string
      add :publication_year, :integer
      add :language_tag, :string

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE edition_details
              ADD CONSTRAINT edition_details_entity_fkey
              FOREIGN KEY (entity_id, entity_kind)
              REFERENCES entities (object_id, entity_kind) ON DELETE CASCADE
            """,
            "ALTER TABLE edition_details DROP CONSTRAINT edition_details_entity_fkey"

    create index(:edition_details, [:work_id])

    # ── content ──────────────────────────────────────────────────────────────
    create table(:content_items, primary_key: false) do
      add :object_id, :bigint, primary_key: true
      add :kind, :string, generated: "ALWAYS AS ('content') STORED"
      add :content_kind, :string, null: false
      add :original_language, :string
      add :source_id, references(:sources, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            ALTER TABLE content_items
              ADD CONSTRAINT content_items_object_fkey
              FOREIGN KEY (object_id, kind) REFERENCES objects (id, kind) ON DELETE CASCADE
            """,
            "ALTER TABLE content_items DROP CONSTRAINT content_items_object_fkey"

    create constraint(:content_items, :content_items_content_kind,
             check:
               "content_kind IN ('definition','article','quotation','passage','image','media','other')"
           )

    create index(:content_items, [:content_kind])
    create index(:content_items, [:source_id])

    create table(:content_revisions) do
      add :content_id, references(:content_items, column: :object_id, on_delete: :delete_all),
        null: false

      add :revision_number, :integer, null: false
      add :body, :text
      add :body_format, :string, null: false, default: "text"
      add :canonical_url, :string
      add :headword, :string
      add :position, :integer, null: false, default: 0
      add :year, :integer
      # Attribution and permission to reproduce are separate questions, and
      # rights can change without invalidating the identity or the relationships.
      add :rights_metadata, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :lifecycle_state, :string, null: false, default: "active"
      add :is_current, :boolean, null: false, default: false

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:content_revisions, :content_revisions_lifecycle_state,
             check: "lifecycle_state IN ('active','withdrawn','superseded')"
           )

    create unique_index(:content_revisions, [:content_id, :revision_number])

    create unique_index(:content_revisions, [:content_id],
             where: "is_current",
             name: :content_revisions_one_current_index
           )

    # ── names and external identifiers ───────────────────────────────────────
    create table(:object_names) do
      add :object_id, references(:objects, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :language_tag, :string
      add :name_kind, :string, null: false, default: "alias"

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:object_names, [:object_id, :name, :name_kind, :language_tag],
             name: :object_names_unique_index
           )

    execute "CREATE INDEX object_names_lower_name_index ON object_names (lower(name))",
            "DROP INDEX object_names_lower_name_index"

    create table(:external_identifiers) do
      add :object_id, references(:objects, on_delete: :delete_all), null: false
      add :namespace, :string, null: false
      add :external_id, :string, null: false
      add :status, :string, null: false, default: "verified"
      add :metadata, :map, null: false, default: %{}

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:external_identifiers, :external_identifiers_status,
             check: "status IN ('verified','candidate','rejected')"
           )

    # One *verified* mapping per namespace/id. Candidates coexist deliberately:
    # an uncertain QID match is evidence, not a claim of identity.
    create unique_index(:external_identifiers, [:namespace, :external_id],
             where: "status = 'verified'",
             name: :external_identifiers_verified_index
           )

    create index(:external_identifiers, [:object_id, :namespace])

    # ── actors ───────────────────────────────────────────────────────────────
    # A login account, a curator bot, an importing process and a historical
    # claimant are four different things, and "unknown" is a valid answer that
    # must not be filled in by inventing a person.
    create table(:actors) do
      add :actor_kind, :string, null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :bot_source_id, references(:sources, on_delete: :nilify_all)
      # The public entity this actor IS, when that is genuinely established.
      # An account is never automatically the person it claims to be.
      add :entity_id, references(:entities, column: :object_id, on_delete: :nilify_all)
      add :label, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:actors, :actors_actor_kind,
             check: "actor_kind IN ('user','bot','import','external','unknown')"
           )

    # Exactly one typed principal per kind — an OR would permit an actor that is
    # both a human and a bot, which the community sketch's voter check allowed.
    create constraint(:actors, :actors_typed_principal,
             check: """
             (actor_kind = 'user'     AND user_id IS NOT NULL AND bot_source_id IS NULL) OR
             (actor_kind = 'bot'      AND bot_source_id IS NOT NULL AND user_id IS NULL) OR
             (actor_kind = 'import'   AND user_id IS NULL AND bot_source_id IS NULL) OR
             (actor_kind = 'external' AND user_id IS NULL AND bot_source_id IS NULL) OR
             (actor_kind = 'unknown'  AND user_id IS NULL AND bot_source_id IS NULL
                                      AND entity_id IS NULL)
             """
           )

    create unique_index(:actors, [:user_id], where: "user_id IS NOT NULL")
    create unique_index(:actors, [:bot_source_id], where: "bot_source_id IS NOT NULL")
    create index(:actors, [:entity_id])

    # ── identity lifecycle ───────────────────────────────────────────────────
    create table(:identity_events) do
      add :operation, :string, null: false
      add :actor_id, references(:actors, on_delete: :nilify_all)
      add :reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:identity_events, :identity_events_operation,
             check: "operation IN ('retire','merge','split','restore')"
           )

    create table(:identity_event_members, primary_key: false) do
      add :event_id, references(:identity_events, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :object_id, references(:objects, on_delete: :restrict),
        null: false,
        primary_key: true

      # A split has several outputs, so this is not a two-column event.
      add :role, :string, null: false, primary_key: true
    end

    create constraint(:identity_event_members, :identity_event_members_role,
             check: "role IN ('input','output')"
           )

    create index(:identity_event_members, [:object_id])

    # `source_id` is nullable because not every case comes from a source: an
    # identity split is a curatorial operation, and #74 requires its ambiguous
    # attachments to enter explicit review rather than be guessed onto an
    # output. Such a case names the `object_id` being split and, per row, the
    # `assertion_id` nobody may reassign automatically.
    create table(:reconciliation_cases) do
      add :source_id, references(:sources, on_delete: :delete_all)
      add :source_record_id, references(:source_records, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :object_id, references(:objects, on_delete: :nilify_all)
      # Plain bigint here and a foreign key further down: `assertions` does not
      # exist yet at this point in the migration.
      add :assertion_id, :bigint
      add :lexeme_id, references(:lexemes, column: :object_id, on_delete: :delete_all)
      add :sense_id, references(:senses, column: :object_id, on_delete: :nilify_all)
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      add :opened_run_id, references(:import_runs, on_delete: :nilify_all)
      add :resolved_by_actor_id, references(:actors, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:reconciliation_cases, :reconciliation_cases_status,
             check: "status IN ('open','resolved','dismissed')"
           )

    create index(:reconciliation_cases, [:status, :source_id])
    create index(:reconciliation_cases, [:sense_id])

    # ── predicates ───────────────────────────────────────────────────────────
    create table(:predicates) do
      add :key, :string, null: false
      add :forward_label, :string, null: false
      add :reverse_label, :string, null: false
      # Named this way deliberately: SYMMETRIC is a reserved word in SQL.
      add :is_symmetric, :boolean, null: false, default: false
      add :is_transitive, :boolean, null: false, default: false
      add :cycles_allowed, :boolean, null: false, default: true
      add :source_native, :boolean, null: false, default: false
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:predicates, [:key])

    # Subkinds are '-' rather than NULL: a foreign key with a NULL column is not
    # enforced under MATCH SIMPLE, which would silently disable this check for
    # every lexeme and sense endpoint.
    create table(:predicate_endpoint_rules, primary_key: false) do
      add :predicate_id, references(:predicates, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :subject_kind, :string, null: false, primary_key: true
      add :subject_subkind, :string, null: false, default: "-", primary_key: true
      add :object_kind, :string, null: false, primary_key: true
      add :object_subkind, :string, null: false, default: "-", primary_key: true
    end

    # ── assertions ───────────────────────────────────────────────────────────
    create table(:assertions) do
      add :source_id, references(:sources, on_delete: :nilify_all)
      # Derived from a stable source-native identifier where one exists; this
      # is what makes a re-import idempotent rather than duplicating.
      add :origin_key, :string
      add :origin_actor_id, references(:actors, on_delete: :nilify_all)
      add :submitted_by_actor_id, references(:actors, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:assertions, [:source_id, :origin_key],
             where: "origin_key IS NOT NULL",
             name: :assertions_origin_index
           )

    # The other half of `reconciliation_cases.assertion_id`, declared above as a
    # plain bigint because this table did not exist yet.
    execute """
            ALTER TABLE reconciliation_cases
              ADD CONSTRAINT reconciliation_cases_assertion_id_fkey
              FOREIGN KEY (assertion_id) REFERENCES assertions (id) ON DELETE SET NULL
            """,
            "ALTER TABLE reconciliation_cases DROP CONSTRAINT reconciliation_cases_assertion_id_fkey"

    create index(:reconciliation_cases, [:object_id])
    create index(:reconciliation_cases, [:assertion_id])

    create table(:assertion_revisions) do
      add :assertion_id, references(:assertions, on_delete: :delete_all), null: false
      add :revision_number, :integer, null: false
      add :subject_object_id, references(:objects, on_delete: :restrict), null: false
      add :predicate_id, references(:predicates, on_delete: :restrict), null: false
      add :object_object_id, references(:objects, on_delete: :restrict), null: false

      # Denormalised endpoint kinds, filled by a BEFORE trigger, so that
      # compatibility is a real foreign key and therefore holds for insert_all,
      # COPY and the linker's raw SQL — not only for changesets.
      add :subject_kind, :string, null: false, default: "-"
      add :subject_subkind, :string, null: false, default: "-"
      add :object_kind, :string, null: false, default: "-"
      add :object_subkind, :string, null: false, default: "-"

      add :rationale, :text
      add :valid_from, :utc_datetime_usec
      add :valid_to, :utc_datetime_usec
      add :language_tag, :string

      add :jurisdiction_entity_id,
          references(:entities, column: :object_id, on_delete: :nilify_all)

      add :context_object_id, references(:objects, on_delete: :nilify_all)
      add :method, :string
      # Explicitly heuristic. A source's own weight is a different quantity and
      # lives in metadata; 0.85 is not an 85% probability of anything.
      add :confidence, :float
      # Separate from currentness, deliberately: the designated current
      # revision of a claim may say `withdrawn`.
      add :lifecycle_state, :string, null: false, default: "active"
      add :is_current, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:assertion_revisions, :assertion_revisions_confidence,
             check: "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)"
           )

    create constraint(:assertion_revisions, :assertion_revisions_lifecycle_state,
             check: "lifecycle_state IN ('active','withdrawn','superseded','rejected')"
           )

    create constraint(:assertion_revisions, :assertion_revisions_valid_interval,
             check: "valid_from IS NULL OR valid_to IS NULL OR valid_from <= valid_to"
           )

    create unique_index(:assertion_revisions, [:assertion_id, :revision_number])

    create unique_index(:assertion_revisions, [:assertion_id],
             where: "is_current",
             name: :assertion_revisions_one_current_index
           )

    execute """
            ALTER TABLE assertion_revisions
              ADD CONSTRAINT assertion_revisions_endpoints
              FOREIGN KEY (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind)
              REFERENCES predicate_endpoint_rules
                (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind)
            """,
            "ALTER TABLE assertion_revisions DROP CONSTRAINT assertion_revisions_endpoints"

    # The read indexes. Partial on is_current, which Gate 0 measured at 0.256 ms
    # p95 against the pointer's 2.576 ms — 41 buffers against 7,957 — because a
    # partial index contains only the rows the read wants.
    create index(:assertion_revisions, [:subject_object_id, :predicate_id],
             where: "is_current",
             name: :assertion_revisions_subject_current_index
           )

    create index(:assertion_revisions, [:object_object_id, :predicate_id],
             where: "is_current",
             name: :assertion_revisions_object_current_index
           )

    # History reads, which are rare and bounded.
    create index(:assertion_revisions, [:subject_object_id])
    create index(:assertion_revisions, [:object_object_id])

    # ── edges whose other end we do not have yet ─────────────────────────────
    # `materialize/1` is pure and per record, so when Wiktionary says *cat* has
    # the hypernym *feline* all it can write is the string. MVP-0 kept that in
    # `lexical_relations.to_lemma` with a nullable `to_lexeme_id`; here both
    # endpoints of an assertion are real objects and NOT NULL, so an unresolved
    # edge cannot be one.
    #
    # It is not dropped either — #69 §4 keeps `to_lemma` forever and #74 forbids
    # silently flattening what a source said. It waits here with its evidence
    # until the target word exists, and `Resolver.run/1` drains it into
    # assertions. This table **is** the unresolved population scorecard row R2
    # reports: 15,718 of 1,179,377 at the last measurement.
    create table(:pending_relations) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :source_record_id, references(:source_records, on_delete: :delete_all)
      add :subject_object_id, references(:objects, on_delete: :delete_all), null: false
      add :predicate_id, references(:predicates, on_delete: :restrict), null: false
      add :to_lemma, :text, null: false
      add :to_pos, :string
      add :origin_key, :string
      add :confidence, :float
      add :method, :string
      add :metadata, :map, null: false, default: %{}
      add :last_seen_run_id, references(:import_runs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    # `source_record_id` is part of the key, not incidental to it: three
    # Wiktionary records — `bear/noun/2`, `/3`, `/4` — assert the same edge, and
    # each of them really does attest it. Keyed by the edge alone, two of those
    # records lose their pending row, the resolver never sees them, and the
    # assertion ends up with one owner where it should have three.
    create unique_index(
             :pending_relations,
             [
               :source_id,
               :source_record_id,
               :subject_object_id,
               :predicate_id,
               :to_lemma,
               :to_pos
             ],
             nulls_distinct: false,
             name: :pending_relations_edge_index
           )

    create index(:pending_relations, ["lower(to_lemma)"])
    create index(:pending_relations, [:last_seen_run_id])

    # The materializer's second pass deletes by origin key the moment an edge
    # becomes an assertion; without this it seq-scans half a million rows once
    # per batch.
    create index(:pending_relations, [:source_id, :origin_key])

    # ── evidence, review contexts, reviews, votes ────────────────────────────
    create table(:assertion_evidence) do
      add :assertion_revision_id, references(:assertion_revisions, on_delete: :delete_all),
        null: false

      add :source_record_revision_id,
          references(:source_record_revisions, on_delete: :nilify_all)

      add :content_revision_id, references(:content_revisions, on_delete: :nilify_all)
      add :sense_revision_id, references(:sense_revisions, on_delete: :nilify_all)
      add :evidence_role, :string, null: false, default: "supports"
      add :locator, :string
      add :attribution_text, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:assertion_evidence, :assertion_evidence_role,
             check: "evidence_role IN ('supports','contradicts')"
           )

    # At least one target. Two sources can support one proposition without
    # losing their individual attribution, so this is not a one-of.
    create constraint(:assertion_evidence, :assertion_evidence_has_target,
             check: """
             source_record_revision_id IS NOT NULL OR
             content_revision_id IS NOT NULL OR
             sense_revision_id IS NOT NULL
             """
           )

    create index(:assertion_evidence, [:assertion_revision_id, :evidence_role])
    create index(:assertion_evidence, [:source_record_revision_id])

    # An immutable manifest of the endpoint revisions a reviewer actually saw.
    # Without it, editing an endpoint's text silently inherits its approval.
    create table(:review_contexts) do
      add :assertion_revision_id, references(:assertion_revisions, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Lets a review's FK prove it belongs to the revision it claims to.
    create unique_index(:review_contexts, [:assertion_revision_id, :id],
             name: :review_contexts_revision_id_index
           )

    create table(:review_context_items, primary_key: false) do
      add :context_id, references(:review_contexts, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :endpoint_role, :string, null: false, primary_key: true
      add :content_revision_id, references(:content_revisions, on_delete: :restrict)
      add :sense_revision_id, references(:sense_revisions, on_delete: :restrict)
    end

    create constraint(:review_context_items, :review_context_items_endpoint_role,
             check: "endpoint_role IN ('subject','object','context')"
           )

    # Exactly one revision target per row. An entity endpoint has no textual
    # revision and simply contributes no row — that is not the same as a row
    # with both columns null.
    create constraint(:review_context_items, :review_context_items_one_target,
             check: """
             (content_revision_id IS NOT NULL AND sense_revision_id IS NULL) OR
             (content_revision_id IS NULL AND sense_revision_id IS NOT NULL)
             """
           )

    create table(:assertion_reviews) do
      add :assertion_revision_id, references(:assertion_revisions, on_delete: :delete_all),
        null: false

      add :review_context_id, :bigint
      add :reviewer_actor_id, references(:actors, on_delete: :nilify_all)
      add :decision, :string, null: false
      add :reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:assertion_reviews, :assertion_reviews_decision,
             check: "decision IN ('accepted','disputed','rejected','withdrawn','needs_review')"
           )

    # The composite FK makes "the context must belong to the revision being
    # reviewed" a foreign key rather than an application check.
    execute """
            ALTER TABLE assertion_reviews
              ADD CONSTRAINT assertion_reviews_context_fkey
              FOREIGN KEY (assertion_revision_id, review_context_id)
              REFERENCES review_contexts (assertion_revision_id, id) ON DELETE SET NULL
            """,
            "ALTER TABLE assertion_reviews DROP CONSTRAINT assertion_reviews_context_fkey"

    create index(:assertion_reviews, [:assertion_revision_id, :inserted_at])

    create table(:assertion_votes) do
      add :assertion_revision_id, references(:assertion_revisions, on_delete: :delete_all),
        null: false

      add :review_context_id, :bigint
      add :actor_id, references(:actors, on_delete: :delete_all), null: false
      add :value, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:assertion_votes, :assertion_votes_value, check: "value IN (-1, 1)")

    # A vote is on a revision, not on a claim: changing what a claim says must
    # not inherit approval of what it used to say.
    create unique_index(:assertion_votes, [:assertion_revision_id, :actor_id])

    execute """
            ALTER TABLE assertion_votes
              ADD CONSTRAINT assertion_votes_context_fkey
              FOREIGN KEY (assertion_revision_id, review_context_id)
              REFERENCES review_contexts (assertion_revision_id, id) ON DELETE SET NULL
            """,
            "ALTER TABLE assertion_votes DROP CONSTRAINT assertion_votes_context_fkey"

    # ── source output ownership ──────────────────────────────────────────────
    # The audit's finding #1: the materializer upserts what it emits and never
    # reconciles what disappeared. `last_seen_run_id` is how a run knows which
    # of its own previous outputs it did not re-emit — and only its own, so
    # retracting one source never removes another source's support.
    create table(:source_materialized_outputs, primary_key: false) do
      add :source_record_id, references(:source_records, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :output_role, :string, null: false, primary_key: true
      add :output_key, :string, null: false, primary_key: true
      add :output_object_id, references(:objects, on_delete: :delete_all), null: false
      add :last_seen_run_id, references(:import_runs, on_delete: :nilify_all)
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:source_materialized_outputs, [:output_object_id])
    create index(:source_materialized_outputs, [:last_seen_run_id])

    create table(:source_assertion_outputs, primary_key: false) do
      add :source_record_id, references(:source_records, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :output_key, :string, null: false, primary_key: true
      add :assertion_id, references(:assertions, on_delete: :delete_all), null: false
      add :last_seen_run_id, references(:import_runs, on_delete: :nilify_all)
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:source_assertion_outputs, [:assertion_id])
    create index(:source_assertion_outputs, [:last_seen_run_id])

    # ── scope membership, re-pointed at lexeme object ids ────────────────────
    create table(:scope_lexeme_members, primary_key: false) do
      add :scope_id, references(:scopes, on_delete: :delete_all), null: false, primary_key: true

      add :lexeme_id, references(:lexemes, column: :object_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :reasons, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scope_lexeme_members, [:lexeme_id])

    # `import_runs` gains the input it replayed. An `alter` rather than a column
    # in the table above, because `source_inputs` references `sources` and is
    # created after it.
    alter table(:import_runs) do
      add :source_input_id, references(:source_inputs, on_delete: :nilify_all)
    end

    triggers()
  end

  # ── functions and triggers ─────────────────────────────────────────────────
  #
  # Three rules that no single declarative constraint can express. All three
  # were built and tested in `docs/spikes/2026-09-gate0/` before being written
  # here, and one of them exists because the spike found the first draft's gap.
  defp triggers do
    # 1. `objects.kind` is immutable. The composite FKs already block a change
    #    while a subtype row exists; this covers the window before one is
    #    inserted, and gives a readable error rather than an FK violation.
    execute """
            CREATE FUNCTION objects_kind_is_immutable() RETURNS trigger AS $$
            BEGIN
              IF NEW.kind IS DISTINCT FROM OLD.kind THEN
                RAISE EXCEPTION 'objects.kind is immutable (% -> %) for object %',
                  OLD.kind, NEW.kind, OLD.id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS objects_kind_is_immutable() CASCADE"

    execute """
            CREATE TRIGGER objects_kind_immutable BEFORE UPDATE ON objects
              FOR EACH ROW EXECUTE FUNCTION objects_kind_is_immutable();
            """,
            "DROP TRIGGER IF EXISTS objects_kind_immutable ON objects"

    # 2. Exactly one subtype per object, checked at COMMIT. Deferred because the
    #    object row must exist before the subtype row can reference it, so it is
    #    legitimately orphaned for the length of the transaction.
    execute """
            CREATE FUNCTION object_has_subtype() RETURNS trigger AS $$
            DECLARE found boolean;
            BEGIN
              -- The object may have been deleted later in the same transaction,
              -- which is a legitimate create-then-drop. Checking a row that no
              -- longer exists would reject the cascade path. Found by the
              -- "deleting the object itself cascades" test.
              IF NOT EXISTS (SELECT 1 FROM objects WHERE id = NEW.id) THEN
                RETURN NULL;
              END IF;

              SELECT EXISTS (
                SELECT 1 FROM lexemes       WHERE object_id = NEW.id UNION ALL
                SELECT 1 FROM senses        WHERE object_id = NEW.id UNION ALL
                SELECT 1 FROM entities      WHERE object_id = NEW.id UNION ALL
                SELECT 1 FROM content_items WHERE object_id = NEW.id
              ) INTO found;

              IF NOT found THEN
                RAISE EXCEPTION 'object % (kind %) has no % row', NEW.id, NEW.kind, NEW.kind
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS object_has_subtype() CASCADE"

    execute """
            CREATE CONSTRAINT TRIGGER objects_require_subtype
              AFTER INSERT ON objects DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION object_has_subtype();
            """,
            "DROP TRIGGER IF EXISTS objects_require_subtype ON objects"

    # 2b. The other direction, and the one the Gate 0 spike's first draft
    #     missed: deleting a subtype row leaves the object behind, still
    #     referenced by every assertion that named it. Measured — deleting
    #     Bierce's entity row left object 101 typed `entity` with no entity row
    #     while `authored_by` still pointed at it.
    #
    #     Skipped when the object went too, which is the ordinary cascade. The
    #     rule this leaves standing is the one #74 asks for: an identity is
    #     RETIRED via lifecycle_state, never deleted out from under its claims.
    execute """
            CREATE FUNCTION subtype_delete_leaves_object_typed() RETURNS trigger AS $$
            DECLARE still_there boolean; has_subtype boolean;
            BEGIN
              SELECT EXISTS (SELECT 1 FROM objects WHERE id = OLD.object_id) INTO still_there;
              IF NOT still_there THEN RETURN NULL; END IF;

              SELECT EXISTS (
                SELECT 1 FROM lexemes       WHERE object_id = OLD.object_id UNION ALL
                SELECT 1 FROM senses        WHERE object_id = OLD.object_id UNION ALL
                SELECT 1 FROM entities      WHERE object_id = OLD.object_id UNION ALL
                SELECT 1 FROM content_items WHERE object_id = OLD.object_id
              ) INTO has_subtype;

              IF NOT has_subtype THEN
                RAISE EXCEPTION 'object % would be left with no subtype row; retire it instead',
                  OLD.object_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NULL;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS subtype_delete_leaves_object_typed() CASCADE"

    for table <- ~w(lexemes senses entities content_items) do
      execute """
              CREATE CONSTRAINT TRIGGER #{table}_delete_keeps_object_typed
                AFTER DELETE ON #{table} DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION subtype_delete_leaves_object_typed();
              """,
              "DROP TRIGGER IF EXISTS #{table}_delete_keeps_object_typed ON #{table}"
    end

    # 3. Endpoint kinds, filled before the row lands so the composite FK to
    #    predicate_endpoint_rules can do the checking. This is what makes the
    #    rule survive insert_all, COPY and raw SQL.
    execute """
            CREATE FUNCTION assertion_endpoint_kinds() RETURNS trigger AS $$
            BEGIN
              SELECT o.kind, COALESCE(e.entity_kind, c.content_kind, '-')
                INTO NEW.subject_kind, NEW.subject_subkind
                FROM objects o
                LEFT JOIN entities e      ON e.object_id = o.id
                LEFT JOIN content_items c ON c.object_id = o.id
               WHERE o.id = NEW.subject_object_id;

              SELECT o.kind, COALESCE(e.entity_kind, c.content_kind, '-')
                INTO NEW.object_kind, NEW.object_subkind
                FROM objects o
                LEFT JOIN entities e      ON e.object_id = o.id
                LEFT JOIN content_items c ON c.object_id = o.id
               WHERE o.id = NEW.object_object_id;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS assertion_endpoint_kinds() CASCADE"

    execute """
            CREATE TRIGGER assertion_revisions_kinds
              BEFORE INSERT OR UPDATE ON assertion_revisions
              FOR EACH ROW EXECUTE FUNCTION assertion_endpoint_kinds();
            """,
            "DROP TRIGGER IF EXISTS assertion_revisions_kinds ON assertion_revisions"

    # 4. Exactly one current revision, at COMMIT. The partial unique indexes
    #    above prove AT MOST one; #74 is explicit that this is not the same
    #    thing, and this is the other half.
    #
    #    Two functions per parent, not one shared: `assertions` names the key
    #    `id` and `assertion_revisions` names it `assertion_id`, and plpgsql
    #    resolves NEW.<col> at run time — a shared function raises
    #    `record "new" has no field "assertion_id"`. Found by running it.
    for {parent, child, fk} <- [
          {"assertions", "assertion_revisions", "assertion_id"},
          {"senses", "sense_revisions", "sense_id"},
          {"content_items", "content_revisions", "content_id"}
        ] do
      parent_key = if parent == "assertions", do: "id", else: "object_id"

      execute """
              CREATE FUNCTION #{child}_current_count(target bigint) RETURNS void AS $$
              DECLARE n int;
              BEGIN
                IF NOT EXISTS (SELECT 1 FROM #{parent} WHERE #{parent_key} = target) THEN
                  RETURN;
                END IF;

                SELECT count(*) INTO n FROM #{child} WHERE #{fk} = target AND is_current;

                IF n <> 1 THEN
                  RAISE EXCEPTION '#{parent} % has % current revisions, expected exactly 1', target, n
                    USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END;
              $$ LANGUAGE plpgsql;
              """,
              "DROP FUNCTION IF EXISTS #{child}_current_count(bigint) CASCADE"

      execute """
              CREATE FUNCTION #{parent}_exactly_one_current() RETURNS trigger AS $$
              BEGIN
                PERFORM #{child}_current_count(NEW.#{parent_key});
                RETURN NULL;
              END;
              $$ LANGUAGE plpgsql;
              """,
              "DROP FUNCTION IF EXISTS #{parent}_exactly_one_current() CASCADE"

      execute """
              CREATE FUNCTION #{child}_exactly_one_current() RETURNS trigger AS $$
              BEGIN
                PERFORM #{child}_current_count(COALESCE(NEW.#{fk}, OLD.#{fk}));
                RETURN NULL;
              END;
              $$ LANGUAGE plpgsql;
              """,
              "DROP FUNCTION IF EXISTS #{child}_exactly_one_current() CASCADE"

      execute """
              CREATE CONSTRAINT TRIGGER #{parent}_exactly_one_current
                AFTER INSERT ON #{parent} DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION #{parent}_exactly_one_current();
              """,
              "DROP TRIGGER IF EXISTS #{parent}_exactly_one_current ON #{parent}"

      execute """
              CREATE CONSTRAINT TRIGGER #{child}_exactly_one_current
                AFTER INSERT OR UPDATE OR DELETE ON #{child} DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION #{child}_exactly_one_current();
              """,
              "DROP TRIGGER IF EXISTS #{child}_exactly_one_current ON #{child}"
    end

    # 5. A review context item must cite a revision of the endpoint it names.
    #
    #    The `one_target` check above proves a row cites exactly one revision;
    #    it does not prove that revision has anything to do with the claim. The
    #    audit's finding: nothing stopped a reviewer's "subject" item from
    #    pointing at an unrelated passage, which would make the pinned manifest
    #    a record of something nobody looked at.
    #
    #    BEFORE, not a constraint trigger, and resolving through the revision's
    #    owning object — so it holds for `insert_all`, for COPY and for a
    #    multi-row INSERT, the same reason the endpoint rule is a foreign key.
    execute """
            CREATE FUNCTION review_context_item_owns_endpoint() RETURNS trigger AS $$
            DECLARE
              endpoint_id bigint;
              owner_id bigint;
            BEGIN
              SELECT CASE NEW.endpoint_role
                       WHEN 'subject' THEN ar.subject_object_id
                       WHEN 'object'  THEN ar.object_object_id
                       WHEN 'context' THEN ar.context_object_id
                     END
                INTO endpoint_id
                FROM review_contexts rc
                JOIN assertion_revisions ar ON ar.id = rc.assertion_revision_id
               WHERE rc.id = NEW.context_id;

              IF endpoint_id IS NULL THEN
                RAISE EXCEPTION
                  'review context % has no % endpoint to pin', NEW.context_id, NEW.endpoint_role
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              IF NEW.content_revision_id IS NOT NULL THEN
                SELECT content_id INTO owner_id
                  FROM content_revisions WHERE id = NEW.content_revision_id;
              ELSE
                SELECT sense_id INTO owner_id
                  FROM sense_revisions WHERE id = NEW.sense_revision_id;
              END IF;

              IF owner_id IS DISTINCT FROM endpoint_id THEN
                RAISE EXCEPTION
                  'review context item cites revision of object %, but the % endpoint is %',
                  owner_id, NEW.endpoint_role, endpoint_id
                  USING ERRCODE = 'integrity_constraint_violation';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS review_context_item_owns_endpoint() CASCADE"

    execute """
            CREATE TRIGGER review_context_items_own_endpoint
              BEFORE INSERT OR UPDATE ON review_context_items
              FOR EACH ROW EXECUTE FUNCTION review_context_item_owns_endpoint();
            """,
            "DROP TRIGGER IF EXISTS review_context_items_own_endpoint ON review_context_items"
  end
end
