defmodule DevilsDictionary.Repo.Migrations.AddInternalContributorRoleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :internal_contributor, :boolean, null: false, default: false
    end
  end
end
