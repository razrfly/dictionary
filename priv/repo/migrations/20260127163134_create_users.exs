defmodule DevilsDictionary.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # User role enum
    execute(
      "CREATE TYPE user_role AS ENUM ('user', 'editor', 'admin')",
      "DROP TYPE user_role"
    )

    create table(:users) do
      # Clerk integration
      add :clerk_id, :string, null: false  # Clerk's user ID
      add :email, :string, null: false
      add :username, :string
      add :display_name, :string
      add :avatar_url, :string

      # App-specific fields
      add :role, :user_role, default: "user"
      add :bio, :text

      # Clerk sync metadata
      add :clerk_created_at, :utc_datetime
      add :clerk_updated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:clerk_id])
    create unique_index(:users, [:email])
    create unique_index(:users, [:username])
    create index(:users, [:role])
  end
end
