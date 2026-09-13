defmodule DevilsDictionary.Artworks.SeederTest do
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Artsy.Client
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.{Manifest, Seeder}
  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, WorkDetails}
  alias DevilsDictionary.Sources
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

  test "a provider artwork without both opaque id and slug is unavailable and never stored" do
    for malformed <- [
          artwork(nil, "fixture-work", "Painting"),
          artwork("opaque-work-86", nil, "Painting")
        ] do
      {manifest, summary} =
        Seeder.run(Manifest.new([candidate()]),
          artsy_client: client([token(), response(200, malformed)]),
          record_limit: 1
        )

      assert summary.unavailable == 1

      assert get_in(manifest, ["candidates", Access.at(0), "import", "reason"]) ==
               "artsy_artwork_missing_identity"
    end

    refute Repo.exists?(
             from(record in SourceRecord, where: record.source_id == ^sources_artsy_id())
           )
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

  @tag :tmp_dir
  test "progress is saved to a separate resumable checkpoint without mutating the base manifest",
       %{tmp_dir: directory} do
    base_path = Path.join(directory, "portable.json")
    checkpoint_path = base_path <> ".checkpoint.json"
    base = Manifest.save!(Manifest.new([candidate()]), base_path)
    base_bytes = File.read!(base_path)

    {_manifest, first} =
      Seeder.run(base,
        artsy_client: client(unavailable_responses()),
        record_limit: 1,
        manifest_path: checkpoint_path
      )

    assert first.unavailable == 1
    assert File.exists?(checkpoint_path)
    assert File.read!(base_path) == base_bytes

    {_manifest, resumed} =
      Seeder.run(Manifest.load!(checkpoint_path),
        artsy_client: client([]),
        record_limit: 1,
        resume: true,
        manifest_path: checkpoint_path
      )

    assert resumed.processed == 0
    assert resumed.requests == 0
  end

  test "request exhaustion checkpoints artwork and resumes the same manifest without duplicates" do
    {partial_manifest, partial_summary} =
      Seeder.run(Manifest.new([candidate()]),
        artsy_client:
          client(
            [token(), response(200, artwork("opaque-work-86", "fixture-work", "Painting"))],
            request_limit: 2
          ),
        record_limit: 1
      )

    assert partial_summary.request_exhausted
    assert partial_summary.partial == 1
    refute Manifest.completed?(hd(partial_manifest["candidates"]))

    assert get_in(partial_manifest, [
             "candidates",
             Access.at(0),
             "import",
             "stages",
             "artists",
             "status"
           ]) == "partial"

    {completed_manifest, resumed} =
      Seeder.run(partial_manifest,
        artsy_client:
          client([
            token(),
            Enum.at(painting_responses(), 2),
            Enum.at(painting_responses(), 3)
          ]),
        record_limit: 1,
        resume: true
      )

    assert resumed.matched == 1
    assert Manifest.completed?(hd(completed_manifest["candidates"]))

    {_same_manifest, rerun} =
      Seeder.run(completed_manifest,
        artsy_client: client([]),
        record_limit: 1,
        resume: true
      )

    assert rerun.requests == 0
    assert rerun.processed == 0

    assert Repo.aggregate(
             from(identifier in ExternalIdentifier,
               where: identifier.namespace == "artsy_artwork_id"
             ),
             :count
           ) == 1
  end

  test "seeding materializes but never replaces a rich current Wikidata record" do
    %{sources: sources} = Sources.Catalog.seed!()

    rich = %{
      "id" => "Q900086",
      "labels" => %{"en" => %{"language" => "en", "value" => "Fixture Work"}},
      "descriptions" => %{"en" => %{"language" => "en", "value" => "Source description"}},
      "claims" => %{
        "P31" => [entity_statement("Q3305213")],
        "P18" => [string_statement("Picture.jpg")],
        "P11005" => [string_statement("fixture-work")]
      }
    }

    {:ok, record} =
      Sources.upsert_record(sources["wikidata"], %{external_id: "Q900086", raw: rich})

    original_hash = record.content_hash

    {_manifest, _summary} =
      Seeder.run(Manifest.new([candidate()]), artsy_client: client(painting_responses()))

    record = Repo.get!(SourceRecord, record.id)
    assert record.content_hash == original_hash
    assert Sources.raw(record) == rich
  end

  test "Wikidata creator link remains when the exact Artsy artwork endpoint is missing" do
    {_manifest, summary} =
      Seeder.run(Manifest.new([candidate()]),
        artsy_client: client(unavailable_responses()),
        record_limit: 1
      )

    assert summary.unavailable == 1
    work_id = Registry.by_external_id("wikidata", "Q900086")
    creator_id = Registry.by_external_id("wikidata", "Q900087")
    assert Enum.any?(Artworks.get(work_id).creators, &(&1.object_id == creator_id))
  end

  test "artist collection pagination retains multiple exact creators" do
    candidate =
      put_in(candidate()["creators"], [
        %{
          "qid" => "Q900087",
          "name" => "Fixture Artist",
          "artsy_artist_slug" => "fixture-artist"
        },
        %{
          "qid" => "Q900088",
          "name" => "Second Artist",
          "artsy_artist_slug" => "second-artist"
        }
      ])

    first_page =
      response(200, %{
        "_embedded" => %{
          "artists" => [artist("opaque-artist-87", "fixture-artist", "Fixture Artist")]
        },
        "_links" => %{
          "next" => %{
            "href" =>
              "https://api.artsy.net/api/artists?artwork_id=opaque-work-86&size=50&offset=1"
          }
        }
      })

    second_page =
      response(200, %{
        "_embedded" => %{
          "artists" => [artist("opaque-artist-88", "second-artist", "Second Artist")]
        }
      })

    genes = response(200, %{"_embedded" => %{"genes" => []}})

    {_manifest, summary} =
      Seeder.run(Manifest.new([candidate]),
        artsy_client:
          client([
            token(),
            response(200, artwork("opaque-work-86", "fixture-work", "Painting")),
            first_page,
            second_page,
            genes
          ])
      )

    assert summary.creators_resolved == 2
    work_id = Registry.by_external_id("wikidata", "Q900086")

    assert Enum.map(Artworks.get(work_id).creators, & &1.label) == [
             "Fixture Artist",
             "Second Artist"
           ]
  end

  test "missing and malformed provider artists are counted without losing Wikidata creators" do
    candidate =
      put_in(candidate()["creators"], [
        %{
          "qid" => "Q900087",
          "name" => "Fixture Artist",
          "artsy_artist_slug" => "fixture-artist"
        },
        %{
          "qid" => "Q900088",
          "name" => "Missing Artist",
          "artsy_artist_slug" => "missing-artist"
        }
      ])

    malformed_artist_page =
      response(200, %{
        "_embedded" => %{
          "artists" => [artist(nil, "fixture-artist", "Fixture Artist")]
        }
      })

    genes = response(200, %{"_embedded" => %{"genes" => []}})

    {_manifest, summary} =
      Seeder.run(Manifest.new([candidate]),
        artsy_client:
          client([
            token(),
            response(200, artwork("opaque-work-86", "fixture-work", "Painting")),
            malformed_artist_page,
            genes
          ])
      )

    assert summary.missing_links == 2
    assert summary.creators_resolved == 0
    assert Registry.by_external_id("wikidata", "Q900087")
    assert Registry.by_external_id("wikidata", "Q900088")
    assert Registry.by_external_id("artsy_artist_id", "") == nil
  end

  test "operator limits outside the documented bounds are rejected" do
    assert_raise ArgumentError, ~r/supported bound 1\.\.5000/, fn ->
      Seeder.run(Manifest.new([candidate()]), record_limit: 0)
    end
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
    assert summary.claims_withdrawn == 0
    assert summary.evidence_removed == 1
    # Artwork collection checkpoints are immutable revisions too; withdrawal
    # removes the entire provider-owned history, not only its final snapshot.
    assert summary.payloads_deleted >= 2
    assert Registry.by_external_id("wikidata", "Q900086") == work_id
    assert Registry.by_external_id("wikidata", "Q900087") == artist_id
    assert Registry.by_external_id("artsy_artwork_slug", "fixture-work") == work_id
    assert Registry.by_external_id("artsy_artist_slug", "fixture-artist") == artist_id
    assert Registry.by_external_id("artsy_artwork_id", "opaque-work-86") == nil
    assert Registry.by_external_id("artsy_artist_id", "opaque-artist-87") == nil

    record_count = Repo.aggregate(SourceRecord, :count)

    {_manifest, stopped} =
      Seeder.run(Manifest.new([candidate()]),
        artsy_client: client(painting_responses()),
        record_limit: 1
      )

    assert stopped.provider_disabled
    assert stopped.requests == 0
    assert stopped.processed == 0
    assert Repo.aggregate(SourceRecord, :count) == record_count
  end

  defp client(responses, opts \\ []) do
    queue = start_supervised!({Agent, fn -> responses end}, id: make_ref())

    request_fun = fn _options ->
      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, %Req.TransportError{reason: :timeout}}, []}
      end)
    end

    Client.new(
      Keyword.merge(
        [
          client_id: "fixture-id",
          client_secret: "fixture-secret",
          request_fun: request_fun,
          sleep_fun: fn _ -> :ok end,
          rate_limit_ms: 0,
          request_limit: 20,
          availability_fun: fn -> :ok end,
          coordinator: nil
        ],
        opts
      )
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

  defp sources_artsy_id do
    %{sources: sources} = Sources.Catalog.seed!()
    sources["artsy"].id
  end

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

  defp artist(id, slug, name) do
    %{
      "id" => id,
      "slug" => slug,
      "name" => name,
      "_links" => %{
        "permalink" => %{"href" => "https://www.artsy.net/artist/#{slug}"}
      }
    }
  end

  defp token, do: response(201, %{"token" => "fixture-token"})
  defp response(status, body), do: %Req.Response{status: status, body: body}

  defp entity_statement(qid) do
    %{
      "type" => "statement",
      "rank" => "normal",
      "mainsnak" => %{
        "datavalue" => %{"value" => %{"id" => qid}, "type" => "wikibase-entityid"}
      }
    }
  end

  defp string_statement(value) do
    %{
      "type" => "statement",
      "rank" => "normal",
      "mainsnak" => %{"datavalue" => %{"value" => value, "type" => "string"}}
    }
  end
end
