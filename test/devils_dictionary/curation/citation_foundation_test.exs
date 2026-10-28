defmodule DevilsDictionary.Curation.CitationFoundationTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures

  alias DevilsDictionary.Curation.{
    ShelfCitations,
    ShelfCitation,
    Digest,
    ProviderText,
    Configurations
  }

  alias DevilsDictionary.{Repo, Sources}
  alias DevilsDictionary.Discovery.Result
  setup do: editor_world!()

  test "exact shared observation never follows the mutable current revision", world do
    a = observation!(world, "guardian", external_id: "shared")

    b =
      observation!(world, "guardian",
        external_id: "shared",
        metadata: %{
          "title" => "A different headline",
          "source_url" => "https://example.test/shared"
        }
      )

    assert a.record.id == b.record.id
    assert a.revision.id != b.revision.id
    assert ShelfCitations.bound_revision(a.result).id == a.revision.id

    assert {:ok, c} =
             ShelfCitations.cite(a.spec, %{
               composition_id: world.composition.id,
               actor_id: a.actor.id
             })

    assert c.cited_revision_id == a.revision.id
    assert c.external_ref_sha256 == a.digest
    assert c.cited_object_id == nil
    assert c.policy_sha256 == a.run.retention_policy_sha256

    assert {:ok, ^c} =
             ShelfCitations.cite(a.spec, %{
               composition_id: world.composition.id,
               actor_id: a.actor.id
             })
  end

  test "legacy unique binding is exact and missing or ambiguous binding is refused", world do
    o = observation!(world, "guardian", legacy: true)
    assert ShelfCitations.bound_revision(o.result).id == o.revision.id
    raw = Repo.get!(DevilsDictionary.Corpus.SourceRecordRevision, o.revision.id)
    Sources.ensure_revision(o.record, Digest.sha256("different lookup key"), o.raw)
    assert ShelfCitations.bound_revision(o.result) == nil

    assert {:error, _} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    assert raw.checksum == o.revision.checksum
  end

  test "citation identity survives actual revision deletion without revival", world do
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    Repo.delete_all(
      from r in DevilsDictionary.Corpus.SourceRecordRevision, where: r.id == ^o.revision.id
    )

    c = Repo.get!(ShelfCitation, c.id)
    assert c.source_record_revision_id == nil
    assert c.cited_revision_id == o.revision.id
    assert c.cited_checksum == o.revision.checksum
    assert ShelfCitations.check(c) == :revision_deleted
    assert Repo.get!(Result, o.result.id).source_record_revision_id == nil
    assert %{redacted_empty_records: 1} = DevilsDictionary.Discovery.purge_expired_payloads(100)
    record = Repo.reload!(o.record)
    assert record.url == nil
    assert record.external_id == "redacted-discovery:" <> o.digest
    assert ShelfCitations.check(Repo.reload!(c)) == :revision_deleted
  end

  test "provider text is detected under normalization and five-word copying" do
    fields = [
      %{
        field: "title",
        value: "An Unusual Headline With Five Distinctive Words",
        policy: "shelf-fields-v1"
      }
    ]

    assert ProviderText.copied?("AN UNUSUAL HEADLINE WITH FIVE DISTINCTIVE WORDS", fields)

    assert ProviderText.copied?(
             "I selected an unusual headline with five relevant detail.",
             fields
           )

    refute ProviderText.copied?("This reports a recent event relevant to the word.", fields)
  end

  test "configuration windows are versioned, bounded and v1 defaults to 48h", world do
    for seconds <- [86_400, 172_800, 604_800] do
      {:ok, v} =
        Configurations.create_version(world.reviewer, world.configuration.id, %{
          reason: "window #{seconds}",
          refresh_window: seconds
        })

      assert Configurations.refresh_window(v) == seconds
      assert Configurations.ready?(v)
    end

    assert Configurations.refresh_window(%DevilsDictionary.Curation.ConfigurationVersion{
             manifest: %{}
           }) == 172_800

    assert {:error, :invalid_refresh_window} =
             Configurations.create_version(world.reviewer, world.configuration.id, %{
               reason: "bad",
               refresh_window: 1
             })
  end
end
