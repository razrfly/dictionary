defmodule DevilsDictionary.Repo.Migrations.CreateDefinitions do
  use Ecto.Migration

  def change do
    create table(:definitions) do
      add :topic_id, references(:topics, on_delete: :delete_all), null: false
      add :author_id, references(:people, on_delete: :nilify_all)

      add :content, :text, null: false
      add :source_name, :string  # "The Devil's Dictionary", "Merriam-Webster", etc.
      add :source_url, :string
      add :source_year, :integer  # 1911, 2024, etc.
      add :tier, :tier, null: false, default: "middle"
      add :position, :integer, default: 0  # Display order within tier

      timestamps(type: :utc_datetime)
    end

    create index(:definitions, [:topic_id])
    create index(:definitions, [:author_id])
    create index(:definitions, [:tier])
    create index(:definitions, [:topic_id, :tier, :position])

    # Trigger to update topic.definition_count
    execute(
      """
      CREATE OR REPLACE FUNCTION update_topic_definition_count()
      RETURNS TRIGGER AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          UPDATE topics SET definition_count = definition_count + 1 WHERE id = NEW.topic_id;
        ELSIF TG_OP = 'DELETE' THEN
          UPDATE topics SET definition_count = definition_count - 1 WHERE id = OLD.topic_id;
        ELSIF TG_OP = 'UPDATE' AND OLD.topic_id != NEW.topic_id THEN
          UPDATE topics SET definition_count = definition_count - 1 WHERE id = OLD.topic_id;
          UPDATE topics SET definition_count = definition_count + 1 WHERE id = NEW.topic_id;
        END IF;
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION IF EXISTS update_topic_definition_count()"
    )

    execute(
      """
      CREATE TRIGGER definitions_count_trigger
      AFTER INSERT OR UPDATE OR DELETE ON definitions
      FOR EACH ROW EXECUTE FUNCTION update_topic_definition_count();
      """,
      "DROP TRIGGER IF EXISTS definitions_count_trigger ON definitions"
    )
  end
end
