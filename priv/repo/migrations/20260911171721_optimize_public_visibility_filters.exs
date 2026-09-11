defmodule DevilsDictionary.Repo.Migrations.OptimizePublicVisibilityFilters do
  use Ecto.Migration

  def change do
    create index(:content_revisions, [:content_id],
             where: "is_current AND lifecycle_state <> 'active'",
             name: :content_revisions_current_nonactive_index
           )

    create index(:sense_revisions, [:sense_id],
             where: "is_current AND lifecycle_state <> 'active'",
             name: :sense_revisions_current_nonactive_index
           )

    create index(:objects, [:id],
             where: "lifecycle_state IN ('retired', 'split')",
             name: :objects_unresolved_identity_index
           )

    execute "CREATE INDEX object_names_name_trgm_index ON object_names USING gin (name gin_trgm_ops)",
            "DROP INDEX IF EXISTS object_names_name_trgm_index"
  end
end
