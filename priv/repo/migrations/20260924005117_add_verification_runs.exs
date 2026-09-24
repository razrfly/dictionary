defmodule DevilsDictionary.Repo.Migrations.AddVerificationRuns do
  use Ecto.Migration

  # #158 build 5: the one new table in the quotes plan, decided by the spike
  # (docs/integrations/verifier.md). A verification pass is per author — the
  # author's own Wikiquote page, the works Wikidata says they wrote, and the
  # texts of those works are one set of requests for every line credited to
  # them — so a run's subject is the person, not a line.
  #
  # The request ledger stays one ledger: `discovery_request_attempts` gains a
  # `verification_run_id` beside a now-nullable `run_id`, and a check that
  # exactly one is set, so every budget and the operator's view keep counting
  # one table.
  def change do
    create table(:verification_runs) do
      add :subject_object_id, references(:objects, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :refresh_after, :utc_datetime_usec
      add :request_count, :integer, null: false, default: 0
      add :error_code, :string
      add :summary, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:verification_runs, :verification_runs_status,
             check: "status IN ('pending','running','succeeded','deferred','failed')"
           )

    create index(:verification_runs, [:subject_object_id, :completed_at])
    create index(:verification_runs, [:status, :refresh_after])

    alter table(:discovery_request_attempts) do
      modify :run_id, :bigint, null: true, from: {:bigint, null: false}
      add :verification_run_id, references(:verification_runs, on_delete: :delete_all)
    end

    create index(:discovery_request_attempts, [:verification_run_id])

    create constraint(:discovery_request_attempts, :discovery_request_attempts_one_run,
             check: "(run_id IS NULL) <> (verification_run_id IS NULL)"
           )
  end
end
