defmodule DevilsDictionary.Repo.Migrations.CreateTopics do
  use Ecto.Migration

  def change do
    # Enum type for topic types
    execute(
      "CREATE TYPE topic_type AS ENUM ('concept', 'thing', 'place', 'event', 'action', 'person', 'organization', 'other')",
      "DROP TYPE topic_type"
    )

    # Enum type for display types
    execute(
      "CREATE TYPE display_type AS ENUM ('standard', 'redirect', 'disambiguation')",
      "DROP TYPE display_type"
    )

    create table(:topics) do
      add :title, :string, null: false
      add :slug, :string, null: false
      add :type, :topic_type, default: "concept"
      add :pronunciation, :string
      add :part_of_speech, :string
      add :definition_count, :integer, default: 0

      # Display handling for disambiguation/redirects
      add :display_type, :display_type, default: "standard"
      add :redirect_to_id, references(:topics, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:topics, [:slug])
    create index(:topics, [:type])
    create index(:topics, [:display_type])
    create index(:topics, [:redirect_to_id])

    # Full-text search index on title
    execute(
      "CREATE INDEX topics_title_trgm_idx ON topics USING gin (title gin_trgm_ops)",
      "DROP INDEX topics_title_trgm_idx"
    )
  end
end
