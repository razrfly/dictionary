defmodule DevilsDictionary.Repo.Migrations.AddReviewerRoleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :reviewer, :boolean, null: false, default: false
    end
  end
end
