defmodule DevilsDictionary.Repo.Migrations.AddDiscoveryIdentityResolution do
  use Ecto.Migration

  def change do
    alter table(:discovery_results) do
      add :resolution_state, :string, null: false, default: "insufficient_evidence"
    end

    create constraint(:discovery_results, :discovery_results_resolution_state,
             check:
               "resolution_state IN ('matched','newly_created','insufficient_evidence','conflicting_identifiers')"
           )

    create index(:discovery_results, [:resolution_state, :id])

    # One open identity disagreement per source record is enough to put the
    # complete assertion set in front of a reviewer. Re-running a discovery or
    # backfill refreshes that case instead of filling the queue with copies.
    create unique_index(:reconciliation_cases, [:source_record_id, :kind],
             where:
               "source_record_id IS NOT NULL AND kind = 'external_identifier_conflict' AND status = 'open'",
             name: :reconciliation_cases_open_external_identifier_conflict_index
           )
  end
end
