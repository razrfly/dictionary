defmodule DevilsDictionary.Curation.CitationRetentionTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.{Repo, Sources, Discovery}
  alias DevilsDictionary.Curation.{ShelfCitations, ShelfCitation, DiscoveryRetention}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.SourceRecord
  setup do: editor_world!()

  defp cite(world, o) do
    {:ok, c} =
      ShelfCitations.cite(o.spec, %{composition_id: world.composition.id, actor_id: o.actor.id})

    c
  end

  test "bounded expiry redacts a referenced observation and its source identity, without citation loss",
       world do
    o = observation!(world)
    c = cite(world, o)
    {1, _} = Discovery.withdraw_result(o.result.id)
    future = DateTime.add(c.expires_at, 1)
    assert %{redacted_revisions: 1} = DiscoveryRetention.sweep(1, now: future)

    payload =
      Repo.one(from r in SourceRecordRevision, where: r.id == ^o.revision.id, select: r.payload)

    refute payload["preview_metadata"]
    assert payload["_discovery_redaction"]["policy"] == "shelf-fields-v1"
    assert Repo.get!(SourceRecordRevision, o.revision.id).checksum == c.cited_checksum
    old_key = Repo.get!(SourceRecordRevision, o.revision.id).revision_key
    assert old_key == "redacted-discovery:#{o.revision.id}:#{c.cited_checksum}"
    record = Repo.get!(SourceRecord, o.record.id)
    assert record.external_id == "redacted-discovery:" <> o.digest
    assert record.url == nil
    refute record.display_allowed
    assert ShelfCitations.check(Repo.get!(ShelfCitation, c.id), future) == :retention_expired

    {:ok, fresh} =
      Sources.upsert_record(o.source, %{
        external_id: o.result.external_namespace <> ":" <> o.result.external_id,
        url: o.raw["preview_metadata"]["source_url"],
        raw: o.raw
      })

    assert fresh.id == record.id
    refute fresh.display_allowed
    assert fresh.current_revision.id != o.revision.id
    assert fresh.current_revision.checksum == c.cited_checksum
    assert Repo.get!(SourceRecordRevision, o.revision.id).revision_key == old_key
    assert Repo.get!(ShelfCitation, c.id).cited_revision_id == o.revision.id
  end

  test "a different newer B never postpones or redacts expired A's current record fields",
       world do
    a = observation!(world, "guardian", external_id: "same-record")
    c = cite(world, a)

    b =
      observation!(world, "guardian",
        external_id: "same-record",
        age: -22 * 3600,
        metadata: %{
          "title" => "A fresh second observation",
          "source_url" => "https://example.test/second"
        }
      )

    future = DateTime.add(c.expires_at, 1)
    assert %{redacted_revisions: 1} = DiscoveryRetention.sweep(1, now: future)
    assert Repo.get!(SourceRecord, b.record.id).url == "https://example.test/second"
    assert Repo.get!(SourceRecord, b.record.id).external_id == "guardian_article:same-record"

    assert Repo.one(
             from r in SourceRecordRevision, where: r.id == ^b.revision.id, select: r.payload
           ) == b.raw

    assert ShelfCitations.check(c, future) == :retention_expired
  end

  test "NULL-bound live legacy observations beyond a batch remain protected", world do
    for n <- 1..4 do
      o = observation!(world, "guardian", legacy: true, external_id: "legacy-#{n}")
      assert ShelfCitations.bound_revision(o.result).id == o.revision.id
    end

    count = Repo.aggregate(SourceRecordRevision, :count)
    assert %{deleted_revisions: 0, redacted_revisions: 0} = DiscoveryRetention.sweep(1)
    assert Repo.aggregate(SourceRecordRevision, :count) == count
  end

  test "terminal durable protected rows do not consume the batch", world do
    for n <- 1..3 do
      o = observation!(world, "poetrydb", external_id: "durable-#{n}", namespace: "poetrydb_poem")
      cite(world, o)
    end

    o = observation!(world)
    c = cite(world, o)
    future = DateTime.add(DateTime.utc_now(), 20 * 365 * 86_400)
    assert %{redacted_revisions: 1} = DiscoveryRetention.sweep(1, now: future)
    assert Repo.get!(ShelfCitation, c.id).cited_revision_id == o.revision.id
    assert %{redacted_revisions: 0} = DiscoveryRetention.sweep(1, now: future)
  end

  test "dry run predicts its next bounded action and does not mutate legacy state", world do
    o = observation!(world, "guardian", legacy: true, age: 90_000)
    before = Repo.get!(DevilsDictionary.Discovery.Result, o.result.id)
    plan = DiscoveryRetention.dry_run(1)
    assert [%{revision_id: id, action: :delete_revision}] = plan.next_batch
    assert id == o.revision.id
    assert Repo.get!(DevilsDictionary.Discovery.Result, o.result.id) == before
    assert %{deleted_revisions: 1} = DiscoveryRetention.sweep(1)
  end
end
