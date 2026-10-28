defmodule DevilsDictionary.Curation.CitationProvidersTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.CurationFixtures, only: [refused: 1]
  alias DevilsDictionary.Curation.{Shelf, ShelfCitations, ShelfCitation, Digest}
  alias DevilsDictionary.Repo
  setup do: editor_world!()

  @namespaces %{
    "guardian" => "guardian_article",
    "bing-news" => "news_article",
    "spotify" => "spotify_track",
    "pexels" => "pexels_photo",
    "unsplash" => "unsplash_photo",
    "openverse" => "openverse_media",
    "commons" => "commons_file",
    "met" => "met_object",
    "cinegraph" => "tmdb_movie",
    "open-library" => "olid",
    "poetrydb" => "poetrydb_poem",
    "wikiquote" => "wikiquote_item"
  }

  for slug <- Shelf.providers() do
    test "#{slug}: exact citation and pure bounded payload/record projection", world do
      slug = unquote(slug)

      o =
        observation!(world, slug,
          namespace: @namespaces[slug],
          metadata: %{
            "title" => "A distinct fixture title for this provider",
            "author" => "Fixture creator",
            "year" => "2026",
            "published_at" => "2026-10-27T00:00:00Z",
            "release_date" => "2026-10-27",
            "source_url" => "https://example.test/chosen",
            "snippet" => "A fixture snippet never permitted as a choice quote."
          }
        )

      assert {:ok, c} =
               ShelfCitations.cite(o.spec, %{
                 composition_id: world.composition.id,
                 actor_id: o.actor.id
               })

      assert c.shelf_kind == Shelf.kind(slug)
      assert c.cited_revision_id == o.revision.id
      assert ShelfCitations.check(c) == :ok

      %{rows: [[payload, record]]} =
        Repo.query!(
          "SELECT discovery_retained_payload($1,$2::jsonb,$4),discovery_retained_record($1,$3::jsonb,$4)",
          [
            slug,
            o.raw,
            %{
              "external_id" => @namespaces[slug] <> ":" <> o.result.external_id,
              "url" => "https://example.test/chosen"
            },
            DateTime.utc_now()
          ]
        )

      case slug do
        s when s in ["commons", "met", "poetrydb", "wikiquote"] ->
          assert payload == o.raw

        "open-library" ->
          assert payload["preview_metadata"]["title"] == o.raw["preview_metadata"]["title"]
          refute payload["preview_metadata"]["snippet"]

        "cinegraph" ->
          assert payload["external_id"] == o.result.external_id
          refute payload["preview_metadata"]
          refute record["url"]

        _ ->
          refute payload["external_id"]
          refute payload["preview_metadata"]
          assert record["external_id"] == "redacted-discovery:" <> o.digest
          refute record["url"]
      end

      %{rows: [[again]]} =
        Repo.query!("SELECT discovery_retained_payload($1,$2::jsonb,$3)", [
          slug,
          payload,
          DateTime.add(DateTime.utc_now(), 60)
        ])

      assert again == payload
      assert Repo.get!(ShelfCitation, c.id).cited_checksum == o.revision.checksum
    end
  end

  test "database rejects forged copied observation identity and policy", world do
    o = observation!(world)

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    # Immutable rows cannot be retargeted, renamed, or made eligible again.
    for {column, value} <- [
          {"cited_revision_id", o.revision.id + 1},
          {"external_ref_sha256", Digest.sha256("forged")},
          {"policy_sha256", Digest.sha256("invented")}
        ] do
      assert {:refused, _, _} =
               refused(fn ->
                 Repo.query!("UPDATE curation_shelf_citations SET #{column}=$1 WHERE id=$2", [
                   value,
                   c.id
                 ])
               end)
    end
  end
end
