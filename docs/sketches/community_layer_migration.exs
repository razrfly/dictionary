defmodule DevilsDictionary.Repo.Migrations.CommunityLayerSketch do
  @moduledoc """
  The community layer of #69 §4's sketch, written against the finished MVP-0
  schema to answer scorecard row **E3**: does it fit without changing anything?

  **This migration is not shipped.** It was generated, applied to a full
  development database, diffed against a schema dump taken before it, and rolled
  back; the file then left `priv/repo/migrations/` for `docs/sketches/` so it can
  never run again. Auth, moderation and the UI that would make these tables mean
  something are all out of MVP-0's scope (#69 §1: "no auth, no votes, no
  examples"). The point is the shape of the diff, not the tables.

  Three tables, `users` included because there is no auth scaffolding at all in
  this app: `examples.submitted_by_id` and `votes.user_id` would have nothing to
  point at, and a proof that skipped the awkward half would not be a proof.
  The media half of the sketch (`media_items`, `attachments`) is deliberately
  left out — E3 asks for examples and votes.

  Every one of them is an **edge with provenance**, the shape `concept_links`
  already set: who said so, how sure, what status, and a `metadata` map. So the
  conventions are the baseline's, unchanged — bigint ids,
  `timestamps(type: :utc_datetime_usec)`, enum-like columns as plain strings
  backed by `Ecto.Enum`, JSONB via `:map`, `coalesce(col, 0)` in the expression
  unique index where a key column is nullable.

  One name collides on purpose. `senses.examples` is a JSONB array of the
  *dictionary's* example sentences, quoted from the source. The `examples` table
  below is the *community's*: a claim that some thing, link or sentence is an
  instance of a word. Different authors, different provenance, different table.

  ## What it touches

  Nothing. No `alter table`, no `drop`, no `rename`, no change to any of the
  thirteen. Four foreign keys point *into* the existing schema — `lexemes`,
  `senses`, `concepts`, `sources` — and add no column to any of them.
  """

  # Kept as `.exs` outside `priv/repo/migrations/` on purpose: `mix ecto.migrate`
  # cannot see it, and neither can `mix precommit`, which migrates the test
  # database. To re-run the proof, move it back under a fresh
  # `mix ecto.gen.migration` timestamp.

  use Ecto.Migration

  def change do
    # ── users ──────────────────────────────────────────────────────────────
    # When auth arrives (Clerk or phx.gen.auth) this is what it fills. Roles are
    # a string, like every other enum-like column in this schema.
    create table(:users) do
      add :email, :string, null: false
      add :handle, :string, null: false
      add :display_name, :string
      add :role, :string, null: false, default: "reader"
      add :confirmed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:handle])

    # ── examples ───────────────────────────────────────────────────────────
    # "X is an example of this word." X is a thing we already have (a public
    # figure, a company), a URL (a news story), or a sentence. The submitter is
    # a person or a bot, and a bot is a `sources` row — which is why `source_id`
    # sits beside `submitted_by_id` rather than replacing it: the tier glyph on
    # the card comes from the source, exactly as it does for Bierce.
    create table(:examples) do
      add :lexeme_id, references(:lexemes, on_delete: :delete_all), null: false
      add :sense_id, references(:senses, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :concept_id, references(:concepts, on_delete: :nilify_all)
      add :url, :string
      add :body, :text
      add :source_id, references(:sources, on_delete: :nilify_all)
      add :submitted_by_id, references(:users, on_delete: :nilify_all)
      add :status, :string, null: false, default: "pending"
      add :score, :float, null: false, default: 0.0
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:examples, [:lexeme_id, :status])
    create index(:examples, [:sense_id])
    create index(:examples, [:concept_id])
    create index(:examples, [:status, :score])

    # One claim per submitter per word: the same nullable-key trick
    # `concept_links_unique_index` uses, because a sense-level example and an
    # entry-level one about the same word are different claims.
    execute """
            CREATE UNIQUE INDEX examples_unique_index ON examples
              (lexeme_id, coalesce(sense_id, 0), kind,
               coalesce(concept_id, 0), coalesce(url, ''),
               coalesce(submitted_by_id, 0), coalesce(source_id, 0))
            """,
            "DROP INDEX examples_unique_index"

    # ── votes ──────────────────────────────────────────────────────────────
    # Polymorphic on purpose: the same +1 works on an example, a sense or an
    # entry, and #17's curator bots vote through `bot_source_id` the way people
    # vote through `user_id`. Cached back onto `examples.score`.
    create table(:votes) do
      add :votable_type, :string, null: false
      add :votable_id, :bigint, null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :bot_source_id, references(:sources, on_delete: :delete_all)
      add :value, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:votes, [:votable_type, :votable_id])

    execute """
            CREATE UNIQUE INDEX votes_voter_index ON votes
              (votable_type, votable_id, coalesce(user_id, 0), coalesce(bot_source_id, 0))
            """,
            "DROP INDEX votes_voter_index"

    create constraint(:votes, :votes_value_is_a_vote, check: "value IN (-1, 1)")

    create constraint(:votes, :votes_have_a_voter,
             check: "user_id IS NOT NULL OR bot_source_id IS NOT NULL"
           )
  end
end
