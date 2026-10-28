defmodule DevilsDictionary.Curation.CitationReviewRegressionTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.{Repo, Sources, Discovery}

  alias DevilsDictionary.Curation.{
    ShelfCitations,
    DiscoveryRetention,
    Eligibility,
    CompositionItem
  }

  alias DevilsDictionary.Installation.DiscoveryProjection
  @moduletag :unboxed
  setup do: editor_world!()

  test "bundle excludes identity after cited revision deletion", world do
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    Repo.query!("DELETE FROM source_record_revisions WHERE id=$1", [o.revision.id])
    assert Repo.reload!(c).source_record_revision_id == nil

    conn =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    sql = DiscoveryProjection.plan(conn, DateTime.utc_now())["source_records"]

    %{rows: [[external_id, url]]} =
      Repo.query!("SELECT external_id,url FROM (" <> sql <> ") projected WHERE id=$1", [
        o.record.id
      ])

    assert url == nil
    assert external_id == "redacted-discovery:" <> o.digest
  end

  test "sweep clears expired record identity with native sibling", world do
    o = observation!(world, "guardian", age: 83_000)
    native = Sources.ensure_revision(o.record, "native-review-fixture", %{"native" => "durable"})
    Discovery.purge_results([o.run.id])
    assert %{deleted_revisions: 1} = DiscoveryRetention.sweep(100)
    assert Repo.get(DevilsDictionary.Corpus.SourceRecordRevision, o.revision.id) == nil
    assert Repo.get(DevilsDictionary.Corpus.SourceRecordRevision, native.id)

    %{rows: [[external_id, url]]} =
      Repo.query!("SELECT external_id,url FROM source_records WHERE id=$1", [o.record.id])

    assert url == nil
    assert external_id == "redacted-discovery:" <> o.digest
  end

  test "citable selects display winner across duplicate pages", world do
    root = observation!(world, "guardian", external_id: "same-page-identity")

    mapping_attrs =
      root.mapping
      |> Map.from_struct()
      |> Map.take(DevilsDictionary.Discovery.Mapping.__schema__(:fields) -- [:id])
      |> Map.merge(%{
        mapping_key: "review-valid-guardian",
        operation: "guardian_attestation",
        parameters: %{"term" => "love", "resolution_strategy" => "attestation_v1"}
      })

    {1, [%{id: mapping_id}]} =
      Repo.insert_all(DevilsDictionary.Discovery.Mapping, [mapping_attrs], returning: [:id])

    Repo.query!("UPDATE discovery_mappings SET enabled=false WHERE id=$1", [root.mapping.id])

    run_attrs =
      root.run
      |> Map.from_struct()
      |> Map.take(DevilsDictionary.Discovery.Run.__schema__(:fields) -- [:id])
      |> Map.put(:mapping_id, mapping_id)

    {1, [%{id: root_id}]} =
      Repo.insert_all(DevilsDictionary.Discovery.Run, [run_attrs], returning: [:id])

    {1, [%{id: page_id}]} =
      Repo.insert_all(
        DevilsDictionary.Discovery.Run,
        [
          Map.merge(run_attrs, %{
            page: 1,
            request_key: "review-second-page",
            position_key: "review-second-page"
          })
        ],
        returning: [:id]
      )

    attrs =
      root.result
      |> Map.from_struct()
      |> Map.take(DevilsDictionary.Discovery.Result.__schema__(:fields) -- [:id])

    {1, [%{id: result_id}]} =
      Repo.insert_all(DevilsDictionary.Discovery.Result, [Map.put(attrs, :run_id, root_id)],
        returning: [:id]
      )

    {1, _} =
      Repo.insert_all(DevilsDictionary.Discovery.Result, [Map.put(attrs, :run_id, page_id)])

    assert Enum.map(Discovery.state(world.love.object_id, "guardian").items, & &1.id) == [
             result_id
           ]

    assert Enum.map(Discovery.citable(world.love.object_id), & &1.result.id) == [result_id]
  end

  test "unsaved expiry precedes deleted cache", world do
    o = observation!(world, "guardian", age: 83_000)

    item = %CompositionItem{
      item_kind: :work,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning_lexeme_id: world.love.object_id
    }

    Discovery.purge_results([o.run.id])
    assert Eligibility.check(item, [world.love.object_id]) == {:error, :retention_expired}
  end

  test "unsaved redaction has precise reason", world do
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    Repo.query!(
      "UPDATE source_record_revisions SET payload=discovery_retained_payload('guardian',payload,$2) WHERE id=$1",
      [o.revision.id, DateTime.utc_now()]
    )

    assert ShelfCitations.check(c) == :payload_redacted

    item = %CompositionItem{
      item_kind: :work,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning_lexeme_id: world.love.object_id
    }

    assert Eligibility.check(item, [world.love.object_id]) == {:error, :payload_redacted}
  end

  test "native current fields and payload survive an older discovery observation cleanup and projection",
       world do
    o = observation!(world, "guardian", age: 83_000)
    native_raw = %{"native" => "independent provenance", "external_namespace" => "native"}

    assert {:ok, native} =
             Sources.upsert_record(o.source, %{
               external_id: o.record.external_id,
               url: "https://native.example.test/durable",
               raw: native_raw
             })

    Discovery.purge_results([o.run.id])
    DiscoveryRetention.sweep(100)
    DiscoveryRetention.sweep(100)
    record = Repo.reload!(native)
    assert record.url == "https://native.example.test/durable"
    assert record.external_id == o.record.external_id
    assert Sources.raw(record) == native_raw

    conn =
      start_supervised!(
        {Postgrex,
         Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
      )

    sql = DiscoveryProjection.plan(conn, DateTime.utc_now())["source_records"]

    assert %{rows: [[id, url]]} =
             Repo.query!("SELECT external_id,url FROM (" <> sql <> ") projected WHERE id=$1", [
               record.id
             ])

    assert id == record.external_id and url == record.url
  end

  test "citable respects source status, provider and mapping validation", world do
    o = observation!(world)
    assert Enum.any?(Discovery.citable(world.love.object_id), &(&1.result.id == o.result.id))
    Repo.query!("UPDATE sources SET active=false WHERE id=$1", [o.source.id])

    assert Enum.find(Discovery.citable(world.love.object_id), &(&1.result.id == o.result.id)).status ==
             :source_inactive

    Repo.query!("UPDATE sources SET active=true WHERE id=$1", [o.source.id])

    attrs =
      o.mapping
      |> Map.from_struct()
      |> Map.take(DevilsDictionary.Discovery.Mapping.__schema__(:fields) -- [:id])
      |> Map.merge(%{version: 2, operation: "invalid-operation"})

    Repo.query!("UPDATE discovery_mappings SET enabled=false WHERE id=$1", [o.mapping.id])

    {1, [%{id: invalid_id}]} =
      Repo.insert_all(DevilsDictionary.Discovery.Mapping, [attrs], returning: [:id])

    Repo.query!("UPDATE discovery_mappings SET enabled=false WHERE id=$1", [o.mapping.id])
    assert Discovery.citable(world.love.object_id) == []
    Repo.query!("UPDATE discovery_mappings SET enabled=false WHERE id=$1", [invalid_id])
    Repo.query!("UPDATE discovery_mappings SET enabled=true WHERE id=$1", [o.mapping.id])
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, providers) end)
    assert Discovery.citable(world.love.object_id) == []
  end

  test "a NULL source record result is unavailable without aborting enumeration or cleanup",
       world do
    o = observation!(world)

    Repo.query!(
      "UPDATE discovery_results SET source_record_id=NULL,source_record_revision_id=NULL WHERE id=$1",
      [o.result.id]
    )

    assert [%{status: :display_restricted}] = Discovery.citable(world.love.object_id)
    DiscoveryRetention.sweep(100)
  end

  test "stricter active policy gives saved and frozen choices the same expiry before and after cleanup",
       world do
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    saved = %CompositionItem{
      item_kind: :work,
      shelf_citation_id: c.id,
      source_record_revision_id: o.revision.id,
      meaning_lexeme_id: world.love.object_id
    }

    unsaved = %{saved | shelf_citation_id: nil, shelf: o.spec}
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})
    guardian = Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 0)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, "guardian", guardian))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)

    for item <- [saved, unsaved],
        do:
          assert(Eligibility.check(item, [world.love.object_id]) == {:error, :retention_expired})

    Discovery.cleanup()

    for item <- [saved, unsaved],
        do:
          assert(Eligibility.check(item, [world.love.object_id]) == {:error, :retention_expired})
  end
end
