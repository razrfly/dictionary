defmodule DevilsDictionary.Repo.Migrations.CreateTopicRelationships do
  use Ecto.Migration

  def change do
    # Enum type for relationship types
    execute(
      """
      CREATE TYPE relationship_type AS ENUM (
        'word_form',
        'synonym',
        'related',
        'see_also',
        'antonym',
        'broader',
        'narrower',
        'disambiguates'
      )
      """,
      "DROP TYPE relationship_type"
    )

    create table(:topic_relationships) do
      add :topic_id, references(:topics, on_delete: :delete_all), null: false
      add :related_topic_id, references(:topics, on_delete: :delete_all), null: false

      add :relationship_type, :relationship_type, null: false
      add :bidirectional, :boolean, default: true
      add :weight, :float, default: 1.0

      timestamps(type: :utc_datetime)
    end

    create index(:topic_relationships, [:topic_id])
    create index(:topic_relationships, [:related_topic_id])
    create index(:topic_relationships, [:relationship_type])

    # Prevent duplicate relationships in the same direction
    create unique_index(:topic_relationships, [:topic_id, :related_topic_id, :relationship_type])

    # Constraint to prevent self-referential relationships
    create constraint(:topic_relationships, :no_self_reference,
      check: "topic_id != related_topic_id"
    )
  end
end
