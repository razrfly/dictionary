defmodule DevilsDictionary.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  def change do
    # Enum type for tiers (shared across multiple tables)
    execute(
      "CREATE TYPE tier AS ENUM ('aristocracy', 'middle', 'plebs')",
      "DROP TYPE tier"
    )

    create table(:people) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :birth_date, :date
      add :death_date, :date  # nil = living (Middle Class tier)
      add :bio, :text
      add :photo_url, :string
      add :tier, :tier, default: "middle"

      # External IDs for API enrichment
      add :google_knowledge_id, :string
      add :tmdb_id, :integer
      add :open_library_id, :string
      add :wikidata_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:people, [:slug])
    create index(:people, [:tier])
    create index(:people, [:death_date])  # For finding "dead intellectuals"
  end
end
