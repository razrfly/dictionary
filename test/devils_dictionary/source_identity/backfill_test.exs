defmodule DevilsDictionary.SourceIdentity.BackfillTest do
  use DevilsDictionary.DataCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Result
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Backfill

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    %{sources: catalog.sources, animals: catalog.scopes["animals"]}
  end

  test "legacy CineGraph rows are reconciled in bounded, idempotent batches", ctx do
    word = word!(ctx, "legacy-film", ~w(wordnet))
    assert {:queued, run} = Discovery.request(target(word), "cinegraph")

    legacy =
      %Result{}
      |> Result.changeset(%{
        run_id: run.id,
        external_namespace: "tmdb_movie",
        external_id: "597",
        position: 0,
        match_details: %{"query" => "legacy-film", "keywords" => []},
        preview_metadata: %{
          "title" => "Titanic",
          "year" => "1997",
          "release_date" => "1997-11-18",
          "poster_url" => "https://image.tmdb.org/t/p/w342/titanic.jpg",
          "source_url" => "https://cinegraph.org/movies/597",
          "content_type" => "film"
        }
      })
      |> Repo.insert!()

    object_count = Repo.aggregate(Object, :count)
    legacy_id = legacy.id

    assert %{
             scanned: 1,
             newly_created: 1,
             matched: 0,
             conflicting_identifiers: 0,
             next_after: ^legacy_id
           } = Backfill.run(limit: 1)

    resolved = Repo.get!(Result, legacy.id)
    assert resolved.object_id
    assert resolved.resolution_state == :newly_created
    assert resolved.source_record_id
    assert Repo.aggregate(Object, :count) == object_count + 1

    assert %{scanned: 1, matched: 1, newly_created: 0} = Backfill.run(limit: 1)
    assert Repo.get!(Result, legacy.id).object_id == resolved.object_id
    assert Repo.aggregate(Object, :count) == object_count + 1

    assert %{scanned: 0, next_after: nil} =
             Backfill.run(limit: 1, after_id: legacy.id)
  end

  test "invalid bounds are rejected before work begins" do
    assert_raise ArgumentError, ~r/limit must be between 1 and 1000/, fn ->
      Backfill.run(limit: 0)
    end

    assert_raise ArgumentError, ~r/after_id must be a positive integer/, fn ->
      Backfill.run(after_id: "1")
    end
  end

  test "legacy Wikidata films queue a deduplicated refresh and current records replay", ctx do
    alias DevilsDictionary.Absorb.Sources.Wikidata
    alias DevilsDictionary.Sources
    alias DevilsDictionary.Registry
    raw = DevilsDictionary.Fixtures.raw("wikidata", "films") |> Enum.find(&(&1["id"] == "Q44578"))

    legacy =
      raw
      |> Wikidata.trim()
      |> Map.delete("_film_identity_version")
      |> update_in(["claims"], &Map.drop(&1, ["P345", "P4947"]))

    {:ok, record} =
      Sources.upsert_record(ctx.sources["wikidata"], %{external_id: "Q44578", raw: legacy})

    {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "Titanic"})
    {:ok, _} = Registry.add_external_id(entity.object_id, "wikidata", "Q44578")
    assert %{queued: 1} = Backfill.wikidata(limit: 100)
    assert %{queued: 1} = Backfill.wikidata(limit: 100)
    assert length(all_enqueued(worker: DevilsDictionary.Workers.EnrichWorker)) == 1

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"entities" => %{"Q44578" => raw}}))
    end)

    assert :ok =
             perform_job(
               DevilsDictionary.Workers.EnrichWorker,
               %{"source" => "wikidata", "target" => record.external_id}
             )

    assert %{current: 1, queued: 0} = Backfill.wikidata(limit: 100)
    assert Registry.by_external_id("tmdb_movie", "597") == entity.object_id
    assert Registry.by_external_id("imdb_title", "tt0120338") == entity.object_id
    assert %{current: 1} = Backfill.wikidata(limit: 100)
  end

  defp target(word) do
    %{object_id: word.object_id, term: word.lemma, language: word.language_tag, relevance: "term"}
  end
end
