defmodule DevilsDictionary.Repo.Migrations.EnablePgExtensions do
  use Ecto.Migration

  def change do
    # Enable pg_trgm extension for fuzzy text search
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm")

    # Enable citext for case-insensitive text (useful for slugs, emails)
    execute("CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext")
  end
end
