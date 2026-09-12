defmodule DevilsDictionary.Repo.Migrations.AddReviewContextSnapshot do
  use Ecto.Migration

  def change do
    alter table(:review_contexts) do
      # Immutable, canonical description of the assertion, attribution,
      # displayed endpoint revisions and evidence the reviewer acted on. Old
      # rows intentionally remain NULL: there is no honest legacy backfill for
      # a display snapshot that was never recorded.
      add :snapshot, :map
      add :fingerprint, :string
    end

    create index(:review_contexts, [:fingerprint])
  end
end
