defmodule DevilsDictionary.Repo.Migrations.AddCurrentClaimPageIndexes do
  use Ecto.Migration

  def change do
    create index(:assertion_revisions, [:subject_object_id, :id],
             where: "is_current",
             name: :assertion_revisions_subject_page_index
           )

    create index(:assertion_revisions, [:object_object_id, :id],
             where: "is_current",
             name: :assertion_revisions_object_page_index
           )
  end
end
