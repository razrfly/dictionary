defmodule DevilsDictionary.Curation.CitationDeletedHistoryTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.{Repo, Sources, Discovery}

  alias DevilsDictionary.Curation.{
    ShelfCitations,
    Eligibility,
    CompositionItem,
    DiscoveryRetention
  }

  alias DevilsDictionary.Installation.DiscoveryProjection
  @moduletag :unboxed
  setup do: editor_world!()

  test "stricter cap survives deletion of disposable run for frozen selection", world do
    o = observation!(world, "guardian", age: 7_300)

    {:ok, c} =
      ShelfCitations.cite(o.spec, %{composition_id: world.composition.id, actor_id: o.actor.id})

    saved = %CompositionItem{
      item_kind: :work,
      shelf_citation_id: c.id,
      source_record_revision_id: o.revision.id,
      meaning_lexeme_id: world.love.object_id
    }

    frozen = %{saved | shelf_citation_id: nil, shelf: o.spec}
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(original, :source_policies, %{})
    policy = Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 0)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(original, :source_policies, Map.put(policies, "guardian", policy))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, original) end)
    Discovery.cleanup()
    assert Repo.get(DevilsDictionary.Discovery.Run, o.run.id) == nil
    assert Eligibility.check(saved, [world.love.object_id]) == {:error, :retention_expired}
    assert Eligibility.check(frozen, [world.love.object_id]) == {:error, :retention_expired}
  end

  test "bundle removes uncited discovery identity when current revision is gone but older revision remains",
       world do
    old =
      observation!(world, "guardian",
        external_id: "review-missing-current",
        metadata: %{
          "title" => "Earlier observation headline",
          "source_url" => "https://provider.example.test/old"
        }
      )

    current =
      observation!(world, "guardian",
        external_id: "review-missing-current",
        metadata: %{
          "title" => "Later observation headline",
          "source_url" => "https://provider.example.test/current"
        }
      )

    assert old.record.id == current.record.id
    Repo.query!("DELETE FROM source_record_revisions WHERE id=$1", [current.revision.id])

    conn =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    plan = DiscoveryProjection.plan(conn, DateTime.utc_now())

    rows =
      Repo.query!(
        "SELECT external_id,url FROM (" <> plan["source_records"] <> ") projected WHERE id=$1",
        [current.record.id]
      ).rows

    assert rows == []
  end

  test "dry-run evidence for native sibling record-field redaction", world do
    o = observation!(world, "guardian", age: 83_000)
    Sources.ensure_revision(o.record, "independent-native", %{"native" => "permitted"})
    plan = DiscoveryRetention.dry_run(100)

    assert Enum.find(
             plan.total_record_field_projections_by_provider,
             &(&1.provider == "guardian")
           ).count == 1

    assert Enum.any?(plan.next_record_field_projections, &(&1.record_id == o.record.id))
    Discovery.purge_results([o.run.id])
    result = DiscoveryRetention.sweep(100)
    assert result.record_field_projections == 1
    assert Repo.reload!(o.record).url == nil
    assert Repo.reload!(o.record).external_id == "redacted-discovery:" <> o.digest
  end

  test "uncited frozen expiry survives complete removal of disposable observation rows", world do
    o = observation!(world, "guardian", age: 7300)

    frozen = %CompositionItem{
      item_kind: :work,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning_lexeme_id: world.love.object_id
    }

    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(
        config,
        :source_policies,
        Map.put(
          policies,
          "guardian",
          Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 0)
        )
      )
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
    Discovery.cleanup()
    assert Repo.get(DevilsDictionary.Discovery.Run, o.run.id) == nil
    assert Repo.get(DevilsDictionary.Corpus.SourceRecordRevision, o.revision.id) == nil
    assert Eligibility.check(frozen, [world.love.object_id]) == {:error, :retention_expired}
  end

  test "dry run predicts a new empty record formed by removing an older revision", world do
    old =
      observation!(world, "guardian",
        age: 83000,
        external_id: "prospective-empty",
        metadata: %{
          "title" => "An earlier source headline",
          "source_url" => "https://example.test/earlier"
        }
      )

    current =
      observation!(world, "guardian",
        external_id: "prospective-empty",
        metadata: %{
          "title" => "A later source headline",
          "source_url" => "https://example.test/later"
        }
      )

    Repo.query!("DELETE FROM source_record_revisions WHERE id=$1", [current.revision.id])
    Discovery.purge_results([old.run.id])
    plan = DiscoveryRetention.dry_run(100)

    assert Enum.find(plan.next_record_field_projections, &(&1.record_id == current.record.id)).also_deleted ==
             false

    assert %{record_field_projections: 1, record_projection_deletion_overlaps: 0} =
             DiscoveryRetention.sweep(100)

    assert Repo.reload!(current.record).url == nil
    assert %{record_field_projections: 0} = DiscoveryRetention.sweep(100)
  end

  test "record projection and subsequent deletion overlap is disclosed once", world do
    o = observation!(world, "guardian", age: 83000)
    Discovery.purge_results([o.run.id])
    plan = DiscoveryRetention.dry_run(100)

    assert Enum.find(plan.next_record_field_projections, &(&1.record_id == o.record.id)).also_deleted

    assert Enum.find(
             plan.total_record_projection_deletion_overlaps_by_provider,
             &(&1.provider == "guardian")
           ).count == 1

    assert %{
             record_field_projections: 1,
             deleted_records: 1,
             record_projection_deletion_overlaps: 1
           } = DiscoveryRetention.sweep(100)

    assert Repo.get(DevilsDictionary.Sources.SourceRecord, o.record.id) == nil
  end
end
