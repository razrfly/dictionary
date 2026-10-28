defmodule DevilsDictionary.Curation.CitationCompatibilityTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.{Repo, WordFixtures}
  @module DevilsDictionary.Repo.Migrations.CreateCurationCitations
  setup do
    unless Code.ensure_loaded?(@module),
      do: Code.require_file("priv/repo/migrations/20261028041101_create_curation_citations.exs")

    world = world!()
    assert %{rows: [[true]]} = Repo.query!("SELECT curation_citations_rollback_eligible()")
    assert %Postgrex.Result{} = Repo.query!(apply(@module, :down_guard, []))
    world
  end

  for state <- ~w(run_policy revision_policy record_tombstone revision_tombstone) do
    test "only #{state} independently fences both old-code eligibility and migration down",
         world do
      case unquote(state) do
        "run_policy" ->
          o = observation!(world)

          Repo.query!(
            "UPDATE source_record_revisions SET discovery_retain_until=NULL,discovery_last_observed_at=NULL,discovery_retention_policy_sha256=NULL WHERE id=$1",
            [o.revision.id]
          )

        state ->
          record = WordFixtures.record!(world, "wikidata", raw: %{"native" => "fixture"})

          revision =
            Repo.one!(
              from r in DevilsDictionary.Corpus.SourceRecordRevision,
                where: r.source_record_id == ^record.id
            )

          case state do
            "revision_policy" ->
              Repo.query!(
                "UPDATE source_record_revisions SET discovery_last_observed_at=statement_timestamp() WHERE id=$1",
                [revision.id]
              )

            "record_tombstone" ->
              Repo.query!(
                "UPDATE source_records SET external_id='redacted-discovery:fixture' WHERE id=$1",
                [record.id]
              )

            "revision_tombstone" ->
              Repo.query!(
                "UPDATE source_record_revisions SET revision_key='redacted-discovery:fixture' WHERE id=$1",
                [revision.id]
              )
          end
      end

      assert %{rows: [[false]]} = Repo.query!("SELECT curation_citations_rollback_eligible()")

      assert {:refused, _, message} =
               refused(fn -> Repo.query!(apply(@module, :down_guard, [])) end)

      assert message =~ "roll forward"
      assert Repo.aggregate(DevilsDictionary.Curation.ShelfCitation, :count) == 0
      assert Repo.aggregate(DevilsDictionary.Curation.ItemBasis, :count) == 0
    end
  end
end
