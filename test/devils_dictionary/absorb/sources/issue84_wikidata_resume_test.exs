defmodule DevilsDictionary.Absorb.Sources.Issue84WikidataResumeTest do
  @moduledoc "Explicit Wikidata selections resume every durable absorb phase."

  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Absorb.{Batch, Clients}
  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Sources.SourceRecord
  alias DevilsDictionary.{Claims, Encyclopedia, Fixtures, Repo, WordFixtures}

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  test "a selected fetched record resumes materialization without widening or later churn", ctx do
    selected_qid = "Q9900084"
    unrelated_qid = "Q9900085"

    selected =
      WordFixtures.record!(ctx, "wikidata",
        external_id: selected_qid,
        raw: entity(selected_qid, "Resume audit item"),
        materialized_at: nil
      )

    unrelated =
      WordFixtures.record!(ctx, "wikidata",
        external_id: unrelated_qid,
        raw: entity(unrelated_qid, "Outside the selection"),
        materialized_at: nil
      )

    counter = reject_network!()

    assert {:ok, %{requests: 0, fetched: 0}} =
             Wikidata.absorb(nil, qids: [selected_qid], rate_limit_ms: 0)

    materialized = Repo.get!(SourceRecord, selected.id)
    item = Encyclopedia.by_qid!(selected_qid)
    assert materialized.materialized_at
    assert is_nil(Repo.get!(SourceRecord, unrelated.id).materialized_at)

    before = %{
      materialized_at: materialized.materialized_at,
      entity_updated_at: Repo.get!(Entity, item.object_id).updated_at,
      entities: Repo.aggregate(Entity, :count),
      revisions: Repo.aggregate(AssertionRevision, :count)
    }

    assert {:ok, %{requests: 0, fetched: 0, concepts: 0, materialize_passes: 1}} =
             Wikidata.absorb(nil, qids: [selected_qid], rate_limit_ms: 0)

    assert Repo.get!(SourceRecord, selected.id).materialized_at == before.materialized_at
    assert Repo.get!(Entity, item.object_id).updated_at == before.entity_updated_at
    assert Repo.aggregate(Entity, :count) == before.entities
    assert Repo.aggregate(AssertionRevision, :count) == before.revisions
    assert :counters.get(counter, 1) == 0
  end

  test "a run stopped between materialization passes resumes missing relations", ctx do
    child_qid = "Q9900184"
    parent_qid = "Q9900185"

    WordFixtures.record!(ctx, "wikidata",
      external_id: child_qid,
      raw: taxon(child_qid, "Resume child", parent_qid),
      materialized_at: nil
    )

    WordFixtures.record!(ctx, "wikidata",
      external_id: parent_qid,
      raw: taxon(parent_qid, "Resume parent", nil),
      materialized_at: nil
    )

    # One-record batches reproduce a process ending after the stale pass: the
    # child is stamped before its parent entity exists, and no closing pass runs.
    counts =
      Batch.run(Wikidata, ctx.sources["wikidata"],
        batch_size: 1,
        only_stale: true,
        where: dynamic([record], record.external_id in ^[child_qid, parent_qid])
      )

    assert counts.concept_relations_skipped_parent_taxon == 1
    child = Encyclopedia.by_qid!(child_qid)
    parent = Encyclopedia.by_qid!(parent_qid)
    assert Claims.outgoing(child.object_id, predicate: "parent_taxon") == []
    counter = reject_network!()

    assert {:ok, %{requests: 0, parent_taxon_unresolved: 0}} =
             Wikidata.absorb(nil, qids: [child_qid], rate_limit_ms: 0)

    assert [edge] = Claims.outgoing(child.object_id, predicate: "parent_taxon")
    assert edge.object_object_id == parent.object_id
    assert :counters.get(counter, 1) == 0
  end

  test "a budget-truncated walk continues through its stored seed on the next run", ctx do
    _ = ctx
    child_qid = "Q9900284"
    parent_qid = "Q9900285"

    counter =
      stub(%{
        child_qid => taxon(child_qid, "Budget child", parent_qid),
        parent_qid => taxon(parent_qid, "Budget parent", nil)
      })

    assert {:ok, %{fetched: 1, requests: 1, truncated: true, unresolved_references: 1}} =
             Wikidata.absorb(nil,
               qids: [child_qid],
               related_depth: 2,
               entity_budget: 1,
               request_budget: 1,
               rate_limit_ms: 0
             )

    assert is_nil(Encyclopedia.by_qid(parent_qid))

    assert {:ok, %{fetched: 1, requests: 1, truncated: false}} =
             Wikidata.absorb(nil,
               qids: [child_qid],
               related_depth: 2,
               entity_budget: 1,
               request_budget: 1,
               rate_limit_ms: 0
             )

    child = Encyclopedia.by_qid!(child_qid)
    parent = Encyclopedia.by_qid!(parent_qid)
    assert [edge] = Claims.outgoing(child.object_id, predicate: "parent_taxon")
    assert edge.object_object_id == parent.object_id

    records =
      Repo.all(
        from record in SourceRecord,
          where:
            record.source_id == ^ctx.sources["wikidata"].id and
              record.external_id in ^[child_qid, parent_qid],
          select: {record.external_id, record.materialized_at}
      )
      |> Map.new()

    assert {:ok, %{requests: 0, fetched: 0, materialize_passes: 1}} =
             Wikidata.absorb(nil,
               qids: [child_qid],
               related_depth: 2,
               entity_budget: 1,
               request_budget: 1,
               rate_limit_ms: 0
             )

    assert :counters.get(counter, 1) == 2

    assert Repo.all(
             from record in SourceRecord,
               where:
                 record.source_id == ^ctx.sources["wikidata"].id and
                   record.external_id in ^[child_qid, parent_qid],
               select: {record.external_id, record.materialized_at}
           )
           |> Map.new() == records
  end

  defp entity(id, label) do
    %{
      "id" => id,
      "labels" => %{"en" => %{"value" => label}},
      "descriptions" => %{},
      "claims" => %{}
    }
  end

  defp taxon(id, label, parent) do
    claims = %{
      "P225" => [%{"mainsnak" => %{"datavalue" => %{"value" => label, "type" => "string"}}}]
    }

    claims =
      if parent do
        Map.put(claims, "P171", [
          %{
            "mainsnak" => %{
              "datavalue" => %{"value" => %{"id" => parent}, "type" => "wikibase-entityid"}
            }
          }
        ])
      else
        claims
      end

    entity(id, label) |> Map.put("claims", claims)
  end

  defp reject_network! do
    counter = :counters.new(1, [])

    Req.Test.stub(Clients, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.json(conn, %{"entities" => %{}})
    end)

    counter
  end

  defp stub(entities) do
    counter = :counters.new(1, [])

    Req.Test.stub(Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      :counters.add(counter, 1, 1)
      ids = String.split(conn.query_params["ids"] || "", "|", trim: true)
      found = for id <- ids, entity = entities[id], into: %{}, do: {id, entity}
      Req.Test.json(conn, %{"entities" => found})
    end)

    counter
  end
end
