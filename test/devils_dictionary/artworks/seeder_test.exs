defmodule DevilsDictionary.Artworks.SeederTest do
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Artsy.Client
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.{Manifest, Seeder}
  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, WorkDetails}
  alias DevilsDictionary.Sources.SourceRecord
  alias DevilsDictionary.Sources.ReconciliationCase

  test "exact Wikidata/P11005/P2042 identities seed once and rerun without duplicate links" do
    candidate = candidate()
    manifest = Manifest.new([candidate])

    {first, summary} =
      Seeder.run(manifest, artsy_client: client(painting_responses()), record_limit: 1)

    assert summary.created == 1
    assert summary.creators_resolved == 1
    assert summary.creator_links == 1
    assert get_in(first, ["candidates", Access.at(0), "import", "status"]) == "created"

    work_id = Registry.by_external_id("wikidata", "Q900086")
    assert work_id == Registry.by_external_id("artsy_artwork_slug", "fixture-work")
    assert work_id == Registry.by_external_id("artsy_artwork_id", "opaque-work-86")
    assert Repo.get!(WorkDetails, work_id).work_kind == "artwork"

    artist_id = Registry.by_external_id("wikidata", "Q900087")
    assert artist_id == Registry.by_external_id("artsy_artist_slug", "fixture-artist")
    assert artist_id == Registry.by_external_id("artsy_artist_id", "opaque-artist-87")
    assert Repo.get!(Entity, artist_id).preferred_label == "Fixture Artist"
    assert Repo.aggregate(Assertion, :count) >= 1

    {_second, again} =
      Seeder.run(Manifest.new([candidate]),
        artsy_client: client(painting_responses()),
        record_limit: 1
      )

    assert again.matched == 1
    assert again.creator_links == 0

    assert Repo.aggregate(
             from(identifier in ExternalIdentifier,
               where: identifier.namespace == "artsy_artwork_id"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(record in SourceRecord, where: record.external_id == "artwork:opaque-work-86"),
             :count
           ) == 1
  end

  test "a search-linked record that is gone remains a useful Wikidata artwork" do
    manifest = Manifest.new([candidate()])

    {_manifest, summary} =
      Seeder.run(manifest, artsy_client: client(unavailable_responses()), record_limit: 1)

    assert summary.unavailable == 1
    work_id = Registry.by_external_id("wikidata", "Q900086")
    assert Registry.by_external_id("artsy_artwork_slug", "fixture-work") == work_id
    assert Registry.by_external_id("artsy_artwork_id", "opaque-work-86") == nil
  end

  test "a print/reproduction never collapses into the painting identity" do
    manifest = Manifest.new([candidate()])

    {_manifest, summary} =
      Seeder.run(manifest, artsy_client: client(print_responses()), record_limit: 1)

    assert summary.skipped == 1
    assert summary.reproductions == 1
    assert Registry.by_external_id("artsy_artwork_id", "opaque-print-86") == nil
    assert Registry.by_external_id("wikidata", "Q900086")
  end

  test "a provider slug that contradicts Wikidata opens one review case" do
    manifest = Manifest.new([candidate()])
    responses = [token(), response(200, artwork("opaque-other-86", "different-work", "Painting"))]

    {_manifest, summary} = Seeder.run(manifest, artsy_client: client(responses), record_limit: 1)
    assert summary.conflicts == 1
    assert Repo.aggregate(ReconciliationCase, :count) == 1
    assert Registry.by_external_id("artsy_artwork_slug", "fixture-work")
    assert Registry.by_external_id("artsy_artwork_slug", "different-work") == nil
  end

  test "resume skips completed records without consuming a provider request" do
    manifest =
      Manifest.new([candidate()])
      |> Manifest.update_candidate(0, %{status: :unavailable, reason: "fixture"})

    {_manifest, summary} =
      Seeder.run(manifest, artsy_client: client([]), record_limit: 1, resume: true)

    assert summary.processed == 0
    assert summary.requests == 0
  end

  test "withdrawal succeeds after a seeded creator citation and keeps durable QIDs" do
    {_manifest, _summary} =
      Seeder.run(Manifest.new([candidate()]),
        artsy_client: client(painting_responses()),
        record_limit: 1
      )

    work_id = Registry.by_external_id("wikidata", "Q900086")
    artist_id = Registry.by_external_id("wikidata", "Q900087")

    assert {:ok, summary} = Artworks.withdraw_artsy("fixture provider shutdown")
    assert summary.claims_withdrawn == 1
    assert summary.evidence_removed == 1
    assert summary.payloads_deleted == 2
    assert Registry.by_external_id("wikidata", "Q900086") == work_id
    assert Registry.by_external_id("wikidata", "Q900087") == artist_id
    assert Registry.by_external_id("artsy_artwork_id", "opaque-work-86") == nil
    assert Registry.by_external_id("artsy_artist_id", "opaque-artist-87") == nil
  end

  defp client(responses) do
    queue = start_supervised!({Agent, fn -> responses end}, id: make_ref())

    request_fun = fn _options ->
      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, %Req.TransportError{reason: :timeout}}, []}
      end)
    end

    Client.new(
      client_id: "fixture-id",
      client_secret: "fixture-secret",
      request_fun: request_fun,
      sleep_fun: fn _ -> :ok end,
      rate_limit_ms: 0,
      request_limit: 20
    )
  end

  defp candidate do
    %{
      "qid" => "Q900086",
      "artsy_artwork_slug" => "fixture-work",
      "title" => "Fixture Work",
      "description" => "A selected fixture painting",
      "wikipedia_title" => "Fixture Work",
      "kind" => "painting",
      "selection_reason" => "test_exact_p11005",
      "creators" => [
        %{
          "qid" => "Q900087",
          "name" => "Fixture Artist",
          "artsy_artist_slug" => "fixture-artist"
        }
      ]
    }
  end

  defp painting_responses do
    [
      token(),
      response(200, artwork("opaque-work-86", "fixture-work", "Painting")),
      response(200, %{
        "_embedded" => %{
          "artists" => [
            %{
              "id" => "opaque-artist-87",
              "slug" => "fixture-artist",
              "name" => "Fixture Artist",
              "_links" => %{
                "permalink" => %{"href" => "https://www.artsy.net/artist/fixture-artist"}
              }
            }
          ]
        }
      }),
      response(200, %{
        "_embedded" => %{
          "genes" => [%{"id" => "gene-war", "name" => "Conflict", "type" => "subject"}]
        }
      })
    ]
  end

  defp unavailable_responses, do: [token(), response(404, %{})]

  defp print_responses,
    do: [token(), response(200, artwork("opaque-print-86", "fixture-work", "Print"))]

  defp artwork(id, slug, category) do
    %{
      "id" => id,
      "slug" => slug,
      "title" => "Fixture Work",
      "category" => category,
      "_links" => %{"permalink" => %{"href" => "https://www.artsy.net/artwork/#{slug}"}}
    }
  end

  defp token, do: response(201, %{"token" => "fixture-token"})
  defp response(status, body), do: %Req.Response{status: status, body: body}
end
