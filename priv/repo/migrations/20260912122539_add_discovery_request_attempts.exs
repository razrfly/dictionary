defmodule DevilsDictionary.Repo.Migrations.AddDiscoveryRequestAttempts do
  use Ecto.Migration

  def change do
    create table(:discovery_request_attempts) do
      add :run_id, references(:discovery_runs, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :restrict), null: false
      add :stage, :string, null: false
      add :attempted_at, :utc_datetime_usec, null: false
    end

    create index(:discovery_request_attempts, [:source_id, :attempted_at])
    create index(:discovery_request_attempts, [:run_id])
  end
end
