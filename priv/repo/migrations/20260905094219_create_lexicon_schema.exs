defmodule DevilsDictionary.Repo.Migrations.CreateLexiconSchema do
  @moduledoc """
  The MVP-0 baseline. Thirteen tables, issue #69 §4.

  Conventions: bigint ids; `timestamps(type: :utc_datetime_usec)`; enum-like
  columns are plain strings backed by `Ecto.Enum`, never Postgres enum types;
  `lemma` is case-sensitive text with a `lower(lemma)` index; slugs lowercase;
  raw payloads are JSONB.
  """

  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm"

    # ── sources ────────────────────────────────────────────────────────────
    # One row per provider, human channel or bot. Tier, kind, access and
    # license live HERE, never on content rows.
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

    # ── people ─────────────────────────────────────────────────────────────
    # Authors of layers. Bierce in MVP-0; Johnson, Webster later.
    create table(:people) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :birth_date, :date
      add :death_date, :date
      add :bio, :text
      add :wikidata_id, :string
      add :source_id, references(:sources, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:people, [:slug])

    # ── scopes ─────────────────────────────────────────────────────────────
    # A scope is data. "animals" is one row.
    create table(:scopes) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :rules, :map, null: false, default: %{}
      add :stats, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scopes, [:slug])

    # ── source_records ─────────────────────────────────────────────────────
    # The truth we fetched, trimmed to what we use. One row per
    # (source, external_id). Replaced, never edited.
    create table(:source_records) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :external_id, :string, null: false
      add :url, :string
      add :raw, :map, null: false, default: %{}
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

    # ── lexemes ────────────────────────────────────────────────────────────
    # A word as a lexical unit: (lang, lemma, pos). The full English index
    # lives here. Any source may create one.
    create table(:lexemes) do
      add :lang, :string, null: false, default: "en"
      add :lemma, :text, null: false
      add :pos, :string, null: false, default: "unknown"
      add :slug, :string, null: false
      add :forms, :map, null: false, default: fragment("'[]'::jsonb")
      add :pronunciations, :map, null: false, default: fragment("'[]'::jsonb")
      add :etymology, :text
      add :etymology_source_id, :bigint
      add :canonical_lexeme_id, references(:lexemes, on_delete: :nilify_all)
      add :origin_source_id, references(:sources, on_delete: :nilify_all)
      add :source_ids, {:array, :bigint}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :enriched_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:lexemes, [:lang, :lemma, :pos])
    create index(:lexemes, [:slug])
    create index(:lexemes, [:canonical_lexeme_id])
    create index(:lexemes, [:enriched_at])

    execute "CREATE INDEX lexemes_lower_lemma_index ON lexemes (lower(lemma))",
            "DROP INDEX lexemes_lower_lemma_index"

    execute "CREATE INDEX lexemes_lemma_trgm_index ON lexemes USING gin (lemma gin_trgm_ops)",
            "DROP INDEX lexemes_lemma_trgm_index"

    execute "CREATE INDEX lexemes_forms_index ON lexemes USING gin (forms)",
            "DROP INDEX lexemes_forms_index"

    # Carries wikt_categories for the scope rules; see #70 S0b.
    execute "CREATE INDEX lexemes_metadata_index ON lexemes USING gin (metadata)",
            "DROP INDEX lexemes_metadata_index"

    # ── concepts ───────────────────────────────────────────────────────────
    # A thing, keyed by Wikidata QID. Encyclopedias attach here; words reach
    # here through concept_links.
    create table(:concepts) do
      add :qid, :string, null: false
      add :label, :string
      add :description, :text
      add :kind, :string, null: false, default: "thing"
      add :wikipedia_title, :string
      add :wikipedia_pageid, :integer
      add :image_url, :string
      add :image_attribution, :string
      add :wordnet_ili, :string
      add :taxon, :map, null: false, default: %{}
      add :taxon_concept_id, references(:concepts, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:concepts, [:qid])
    create index(:concepts, [:wikipedia_title])
    create index(:concepts, [:taxon_concept_id])

    # ── senses ─────────────────────────────────────────────────────────────
    # One meaning as asserted by ONE source. Always short; always linked.
    create table(:senses) do
      add :lexeme_id, references(:lexemes, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :source_record_id, references(:source_records, on_delete: :nilify_all)
      add :external_id, :string, null: false
      add :group_key, :string
      add :gloss, :text
      add :url, :string
      add :position, :integer, null: false, default: 0
      add :tags, {:array, :string}, null: false, default: []
      add :topics, {:array, :string}, null: false, default: []
      add :examples, :map, null: false, default: fragment("'[]'::jsonb")
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:senses, [:source_id, :external_id])
    create index(:senses, [:lexeme_id, :source_id, :position])
    create index(:senses, [:group_key])

    # ── entries ────────────────────────────────────────────────────────────
    # A text a source published about a word or a thing. Prose sources
    # (Bierce, Wikipedia summaries) land here.
    create table(:entries) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :source_record_id, references(:source_records, on_delete: :nilify_all)
      add :lexeme_id, references(:lexemes, on_delete: :delete_all)
      add :concept_id, references(:concepts, on_delete: :delete_all)
      add :author_id, references(:people, on_delete: :nilify_all)
      add :headword, :string
      add :pos, :string
      add :body, :text
      add :body_format, :string, null: false, default: "text"
      add :url, :string
      add :thumbnail_url, :string
      add :year, :integer
      add :position, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:entries, :entries_lexeme_or_concept,
             check: "lexeme_id IS NOT NULL OR concept_id IS NOT NULL"
           )

    create unique_index(:entries, [:source_record_id, :position])
    create index(:entries, [:lexeme_id, :source_id])
    create index(:entries, [:concept_id, :source_id])

    # ── lexical_relations ──────────────────────────────────────────────────
    # Typed edges between words, with provenance, tolerant of targets we have
    # not seen yet. `to_lemma` is kept forever.
    create table(:lexical_relations) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :from_lexeme_id, references(:lexemes, on_delete: :delete_all), null: false
      add :from_sense_id, references(:senses, on_delete: :nilify_all)
      add :to_lemma, :text, null: false
      add :to_pos, :string
      add :to_lexeme_id, references(:lexemes, on_delete: :nilify_all)
      add :to_sense_id, references(:senses, on_delete: :nilify_all)
      add :to_group_key, :string
      add :type, :string, null: false
      add :subtype, :string
      add :weight, :float, null: false, default: 1.0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            CREATE UNIQUE INDEX lexical_relations_unique_index ON lexical_relations
              (source_id, from_lexeme_id, coalesce(from_sense_id, 0), to_lemma, type)
            """,
            "DROP INDEX lexical_relations_unique_index"

    execute """
            CREATE INDEX lexical_relations_unresolved_index ON lexical_relations
              (lower(to_lemma)) WHERE to_lexeme_id IS NULL
            """,
            "DROP INDEX lexical_relations_unresolved_index"

    create index(:lexical_relations, [:from_lexeme_id, :type])
    # The scope closure CTE and the word-page graph panel both join here.
    create index(:lexical_relations, [:from_sense_id])
    create index(:lexical_relations, [:to_lexeme_id, :type])
    create index(:lexical_relations, [:to_group_key])

    # ── concept_relations ──────────────────────────────────────────────────
    # Encyclopedic edges. In MVP-0: the Wikidata taxonomy.
    create table(:concept_relations) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :from_concept_id, references(:concepts, on_delete: :delete_all), null: false
      add :to_concept_id, references(:concepts, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :property, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:concept_relations, [:from_concept_id, :to_concept_id, :type, :source_id])
    create index(:concept_relations, [:to_concept_id, :type])

    # ── concept_links ──────────────────────────────────────────────────────
    # The word ↔ thing bridge. Every link records how we know and how sure we
    # are. The template for every later edge.
    create table(:concept_links) do
      add :lexeme_id, references(:lexemes, on_delete: :delete_all), null: false
      add :sense_id, references(:senses, on_delete: :delete_all)
      add :concept_id, references(:concepts, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :nilify_all)
      add :method, :string, null: false
      add :confidence, :float
      add :status, :string, null: false, default: "auto"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    execute """
            CREATE UNIQUE INDEX concept_links_unique_index ON concept_links
              (lexeme_id, coalesce(sense_id, 0), concept_id, method)
            """,
            "DROP INDEX concept_links_unique_index"

    create index(:concept_links, [:concept_id])
    create index(:concept_links, [:lexeme_id, :status])

    # ── scope_lexemes ──────────────────────────────────────────────────────
    # Composite primary key (scope_id, lexeme_id).
    create table(:scope_lexemes, primary_key: false) do
      add :scope_id, references(:scopes, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :lexeme_id, references(:lexemes, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :reasons, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scope_lexemes, [:lexeme_id])

    # ── import_runs ────────────────────────────────────────────────────────
    # Every task run leaves a row. The dashboard and dd.score read these.
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
  end
end
