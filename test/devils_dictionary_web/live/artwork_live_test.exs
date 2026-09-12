defmodule DevilsDictionaryWeb.ArtworkLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Artworks, Claims, Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Claims.AssertionEvidence
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.{MaterializedOutput, Source}

  setup ctx do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()

    {:ok, work} =
      Registry.create_work(%{
        preferred_label: "The Fixture of War",
        description: "A painting used to verify the reusable artwork flow.",
        work_kind: "artwork"
      })

    {:ok, creator} = Registry.create_person(%{preferred_label: "Fixture Painter"})
    {:ok, claim} = Claims.assert(work.object_id, "authored_by", creator.object_id)
    {:ok, _} = Registry.add_external_id(work.object_id, "wikidata", "Q860086")
    {:ok, _} = Registry.add_external_id(work.object_id, "artsy_artwork_slug", "fixture-of-war")

    {:ok, record} =
      Sources.upsert_record(sources["artsy"], %{
        external_id: "artwork:opaque-live-86",
        url: "https://www.artsy.net/artwork/fixture-of-war",
        raw: %{
          "artwork" => %{
            "id" => "opaque-live-86",
            "slug" => "fixture-of-war",
            "title" => "The Fixture of War",
            "permalink" => "https://www.artsy.net/artwork/fixture-of-war"
          },
          "genes" => [%{"id" => "gene-conflict", "name" => "Conflict"}]
        }
      })

    Repo.insert!(%MaterializedOutput{
      source_record_id: record.id,
      output_role: "concept",
      output_key: "Q860086",
      output_object_id: work.object_id
    })

    revision = Claims.current_revision(claim.id)

    {:ok, _evidence} =
      Claims.add_evidence(revision.id, %{
        source_record_revision_id: record.current_revision.id,
        evidence_role: :supports,
        attribution_text: "Fixture provider citation"
      })

    Map.merge(ctx, %{
      sources: sources,
      animals: scopes["animals"],
      work: work,
      creator: creator,
      record: record,
      claim: claim
    })
  end

  test "catalog search links both the work and its creator", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/artworks")
    assert has_element?(view, "#artwork-#{ctx.work.object_id}")

    assert has_element?(
             view,
             "#artwork-#{ctx.work.object_id} a[href^='/entities/#{ctx.work.object_id}/']"
           )

    assert has_element?(
             view,
             "#artwork-#{ctx.work.object_id} a[href^='/entities/#{ctx.creator.object_id}/']"
           )

    html = view |> form("#artwork-search", search: %{q: "Fixture Painter"}) |> render_change()
    assert html =~ ~s(id="artwork-#{ctx.work.object_id}")

    html = view |> form("#artwork-search", search: %{q: "no such work"}) |> render_change()
    refute html =~ ~s(id="artwork-#{ctx.work.object_id}")
  end

  test "a contributor opens the existing composer with the exact artwork selected", ctx do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
    _user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    {:ok, view, _html} = live(conn, ~p"/connect?subject=#{ctx.work.object_id}")
    assert has_element?(view, "#composer-subject-chosen")
    assert render(view) =~ "The Fixture of War"
    assert has_element?(view, "#predicate-illustrates")
  end

  test "a direct gene produces a labeled candidate for the exact sense, never a claim", ctx do
    war = word!(ctx, "war", ["wordnet"])
    sense = sense!(ctx, war, "wordnet", gloss: "organized armed conflict or warfare")

    {:ok, view, _html} = live(ctx.conn, ~p"/define/war")
    assert has_element?(view, "#artwork-candidates")

    assert has_element?(
             view,
             "#artwork-candidate-#{ctx.work.object_id}-#{sense.object_id}"
           )

    assert render(view) =~ "not yet reviewed"
  end

  test "provider withdrawal deletes Artsy payloads but preserves Wikidata identity", ctx do
    assert {:ok, summary} = Artworks.withdraw_artsy("fixture terms ended")
    assert summary.payloads_deleted == 1
    assert summary.records_disabled == 1
    assert summary.evidence_removed == 1

    assert Registry.by_external_id("wikidata", "Q860086") == ctx.work.object_id
    assert Repo.get!(Source, ctx.sources["artsy"].id).active == false
    assert Repo.get(SourceRecordRevision, ctx.record.current_revision.id) == nil
    assert Repo.aggregate(AssertionEvidence, :count) == 0
    assert Claims.current_revision(ctx.claim.id).lifecycle_state == :active

    record = Repo.get!(DevilsDictionary.Sources.SourceRecord, ctx.record.id)
    refute record.display_allowed
    assert record.url == nil
    assert record.content_hash == nil
    assert Artworks.search("Fixture") |> Enum.any?(&(&1.object_id == ctx.work.object_id))
    assert Artworks.get(ctx.work.object_id).artsy == nil
  end
end
