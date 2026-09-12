defmodule DevilsDictionary.SourceIdentity.DisplayTest do
  use DevilsDictionary.DataCase, async: false
  alias DevilsDictionary.{Sources, SourceIdentity, Repo}
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.SourceIdentity.Display
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Encyclopedia.EntityPage

  test "withdrawn sole source does not continue serving its image" do
    %{sources: sources} = DevilsDictionary.Fixtures.seed_catalog!()
    source = sources["cinegraph"]

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "audit-film",
        url: "https://cinegraph.org/movies/audit",
        raw: %{
          "title" => "Audit film",
          "preview_metadata" => %{
            "poster_url" => "https://image.tmdb.org/t/p/w342/withdrawn.jpg"
          }
        }
      })

    {:ok, entry} =
      Entry.new(%{
        source_slug: "cinegraph",
        source_id: source.id,
        source_record_id: record.id,
        entity_kind: :work,
        work_kind: "film",
        label: "Audit film",
        stable_identifier: %{namespace: "tmdb_movie", external_id: "999999999"},
        metadata: %{"image_url" => "https://image.tmdb.org/t/p/w342/withdrawn.jpg"}
      })

    resolution = SourceIdentity.resolve(entry)
    assert EntityPage.build(resolution.object_id).entity.image_url

    entity = Repo.get!(Entity, resolution.object_id)
    legacy = %{entity | metadata: Map.delete(entity.metadata, "source_identity_evidence")}
    evidence = Display.preload([legacy])
    assert Display.image_url(legacy, evidence) == entity.metadata["image_url"]

    record |> Ecto.Changeset.change(display_allowed: false) |> Repo.update!()
    page = EntityPage.build(resolution.object_id)
    assert page.sources == []
    assert is_nil(page.entity.image_url)
  end
end
