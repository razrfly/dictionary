defmodule DevilsDictionaryWeb.ArtworkLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Artworks, Claims, Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Encyclopedia.EntityPage
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
            "date" => "1814",
            "medium" => "Oil on canvas",
            "collecting_institution" => "Fixture Museum",
            "thumbnail_url" => "https://images.example.test/fixture.jpg",
            "image_rights" => "Fixture credit",
            "permalink" => "https://www.artsy.net/artwork/fixture-of-war"
          },
          "genes" => [
            %{"id" => "4db9b645db68d133c600123e", "name" => "Conflict"}
          ]
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
             "#artwork-#{ctx.work.object_id}-image[phx-hook='ArtworkImage'][data-image-state='loading'] img[data-artwork-image]"
           )

    assert has_element?(
             view,
             "#artwork-#{ctx.work.object_id}-image [data-artwork-fallback][hidden]"
           )

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

    html = view |> form("#artwork-search", search: %{q: "Conflict"}) |> render_change()
    assert html =~ ~s(id="artwork-#{ctx.work.object_id}")

    html = view |> form("#artwork-search", search: %{q: "no such work"}) |> render_change()
    refute html =~ ~s(id="artwork-#{ctx.work.object_id}")

    {:ok, unrelated} =
      Registry.create_work(%{
        preferred_label: "Unrelated Search Target",
        work_kind: "book"
      })

    {:ok, _claim} = Claims.assert(ctx.work.object_id, "adaptation_of", unrelated.object_id)

    html =
      view
      |> form("#artwork-search", search: %{q: "Unrelated Search Target"})
      |> render_change()

    refute html =~ ~s(id="artwork-#{ctx.work.object_id}")
  end

  test "catalog pages beyond the first 24 reusable artworks", ctx do
    for index <- 1..24 do
      {:ok, _work} =
        Registry.create_work(%{
          preferred_label: "Page Fixture #{String.pad_leading(to_string(index), 2, "0")}",
          work_kind: "artwork"
        })
    end

    {:ok, view, _html} = live(ctx.conn, ~p"/artworks")
    assert has_element?(view, "#artwork-pagination")
    refute has_element?(view, "#artwork-#{ctx.work.object_id}")

    view |> element("#artwork-next-page") |> render_click()
    assert has_element?(view, "#artwork-#{ctx.work.object_id}")
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

    sense =
      sense!(ctx, war, "wordnet",
        external_id: "oewn-00975181-n#war",
        gloss: "organized armed conflict or warfare"
      )

    assert %{installed: 1} = Artworks.install_meaning_mappings!()
    assertion_count = Repo.aggregate(Assertion, :count)

    {:ok, view, _html} = live(ctx.conn, ~p"/define/war")

    # The one reader surface (K2 of #109): a gene candidate is a shelf item on
    # the artwork shelf, not a tall card of its own beside it.
    assert has_element?(view, "#culture-filter-artwork", "Artworks")
    assert has_element?(view, "#culture-result-catalog_artwork-c#{ctx.work.object_id}")
    assert has_element?(view, "#culture-about-artwork-catalog", "Artsy gene \u201CConflict\u201D")
    assert has_element?(view, "#culture-about-artwork-catalog", "not yet reviewed")
    refute has_element?(view, "#artwork-candidates")
    assert is_integer(sense.object_id)
    assert Repo.aggregate(Assertion, :count) == assertion_count

    wrong_id_payload =
      Map.put(ctx.record.raw, "genes", [
        %{"id" => "not-the-conflict-gene", "name" => "Conflict"}
      ])

    {:ok, _record} =
      Sources.upsert_record(ctx.sources["artsy"], %{
        external_id: ctx.record.external_id,
        url: ctx.record.url,
        raw: wrong_id_payload
      })

    assert Artworks.suggestions([war.object_id]) == []
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

  test "artwork page exposes rich metadata and a working creator destination", ctx do
    {:ok, view, _html} =
      live(
        ctx.conn,
        ~p"/entities/#{ctx.work.object_id}/#{DevilsDictionary.Claims.Connection.slugify(ctx.work.preferred_label)}"
      )

    assert has_element?(view, "#artwork-metadata")
    assert has_element?(view, "#entity-artwork[phx-hook='ArtworkImage'] img[data-artwork-image]")
    assert has_element?(view, "#entity-artwork [data-artwork-fallback][hidden]")
    assert has_element?(view, "#artwork-metadata a[href^='/entities/#{ctx.creator.object_id}/']")
    assert render(view) =~ "Oil on canvas"
    assert render(view) =~ "Fixture Museum"
  end

  test "candidate link preselects exact meaning, predicate, rationale and provider revision",
       ctx do
    war = word!(ctx, "war", ["wordnet"])

    sense =
      sense!(ctx, war, "wordnet",
        external_id: "oewn-00975181-n#war",
        gloss: "organized armed conflict or warfare"
      )

    %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
    _user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    path =
      ~p"/connect?#{%{subject: ctx.work.object_id, object: sense.object_id, predicate: "illustrates", rationale: "Related provider vocabulary; inspect the depicted event.", evidence_revision: ctx.record.current_revision.id, evidence_locator: "Artsy direct gene 4db9b645db68d133c600123e"}}"

    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#composer-subject-chosen")
    assert has_element?(view, "#composer-object-chosen")
    assert has_element?(view, "#predicate-illustrates")
    assert has_element?(view, "#selected-evidence-source-#{ctx.record.current_revision.id}")

    assert render(view) =~ "Related provider vocabulary; inspect the depicted event."

    refute ctx.work.object_id == sense.object_id
  end

  test "composer ignores non-text and unrelated preselected evidence", ctx do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
    _user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    {:ok, view, _html} =
      live(
        conn,
        "/connect?rationale[]=bad&evidence_locator[]=bad&evidence_revision[]=1"
      )

    refute has_element?(view, "[id^='selected-evidence-source-']")

    {:ok, other_record} =
      Sources.upsert_record(ctx.sources["wikidata"], %{
        external_id: "Q900199",
        raw: %{"id" => "Q900199"}
      })

    path =
      ~p"/connect?#{%{subject: ctx.work.object_id, evidence_revision: other_record.current_revision.id, evidence_locator: "unrelated"}}"

    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, "#selected-evidence-source-#{other_record.current_revision.id}")
  end

  test "related mapping labels and assignments beyond catalog page one remain discoverable",
       ctx do
    love = word!(ctx, "love", ["wordnet"])

    sense =
      sense!(ctx, love, "wordnet",
        external_id: "oewn-07558676-n#love",
        gloss: "a strong positive emotion of regard and affection"
      )

    target =
      Enum.reduce(1..501, nil, fn index, target ->
        label = "Scale Artwork #{String.pad_leading(to_string(index), 3, "0")}"
        slug = "scale-artwork-#{index}"
        {:ok, work} = Registry.create_work(%{preferred_label: label, work_kind: "artwork"})

        genes =
          if index == 501,
            do: [%{"id" => "4de292fcef72520001005fe5", "name" => "Love"}],
            else: [%{"id" => "irrelevant-gene", "name" => "Irrelevant"}]

        {:ok, record} =
          Sources.upsert_record(ctx.sources["artsy"], %{
            external_id: "artwork:scale-#{index}",
            url: "https://www.artsy.net/artwork/#{slug}",
            raw: %{
              "artwork" => %{
                "id" => "scale-#{index}",
                "slug" => slug,
                "title" => label,
                "category" => "Painting"
              },
              "genes" => genes
            }
          })

        Repo.insert!(%MaterializedOutput{
          source_record_id: record.id,
          output_role: "concept",
          output_key: "scale-#{index}",
          output_object_id: work.object_id
        })

        if index == 501, do: work, else: target
      end)

    assert %{installed: 1} = Artworks.install_meaning_mappings!()

    assert [%{artwork: artwork, sense_id: sense_id, match_type: "related"}] =
             Artworks.suggestions([love.object_id])

    assert artwork.object_id == target.object_id
    assert sense_id == sense.object_id

    {:ok, view, _html} = live(ctx.conn, ~p"/define/love")
    assert has_element?(view, "#culture-about-artwork-catalog", "Related Artsy gene")
  end

  test "rejected creator relationship is hidden from cards and search", ctx do
    revision = Claims.current_revision(ctx.claim.id)
    {:ok, _review} = Claims.review(revision.id, :rejected)

    assert Artworks.get(ctx.work.object_id).creators == []
    refute Enum.any?(Artworks.search("Fixture Painter"), &(&1.object_id == ctx.work.object_id))
  end

  test "duplicate source relationships render once while their assertions remain", ctx do
    assertion_count = Repo.aggregate(Assertion, :count)

    {:ok, _wikidata_claim} =
      Claims.assert(ctx.work.object_id, "authored_by", ctx.creator.object_id, %{
        source_id: ctx.sources["wikidata"].id,
        origin_key: "wikidata:duplicate-creator"
      })

    {:ok, _artsy_claim} =
      Claims.assert(ctx.work.object_id, "authored_by", ctx.creator.object_id, %{
        source_id: ctx.sources["artsy"].id,
        origin_key: "artsy:duplicate-creator"
      })

    assert Repo.aggregate(Assertion, :count) == assertion_count + 2
    assert [%{object_id: creator_id}] = Artworks.get(ctx.work.object_id).creators
    assert creator_id == ctx.creator.object_id

    page = EntityPage.build(ctx.creator.object_id)
    assert page.pagination.works.count == 1
    assert [%{object_id: work_id}] = page.works
    assert work_id == ctx.work.object_id

    {:ok, view, _html} =
      live(
        ctx.conn,
        ~p"/entities/#{ctx.work.object_id}/#{DevilsDictionary.Claims.Connection.slugify(ctx.work.preferred_label)}"
      )

    assert has_element?(view, "#artwork-metadata a[href^='/entities/#{ctx.creator.object_id}/']")

    refute has_element?(
             view,
             "#entity-connections a[href^='/entities/#{ctx.creator.object_id}/']"
           )
  end

  test "a retained provider thumbnail is displayed with the provider's own credit", ctx do
    # The independent image projection can be withheld (source-identity gating,
    # or a provider-only record) while its credit string survives in metadata.
    # Pairing them separately printed a Wikimedia credit under an Artsy image.
    Repo.get_by!(Registry.Entity, object_id: ctx.work.object_id)
    |> Ecto.Changeset.change(
      metadata: %{"image_attribution" => "Some_File.jpg \u00b7 Wikimedia Commons"}
    )
    |> Repo.update!()

    artwork = Artworks.get(ctx.work.object_id)

    assert artwork.image_url == "https://images.example.test/fixture.jpg"
    assert artwork.image_attribution == "Fixture credit"
    refute artwork.image_attribution =~ "Wikimedia"
  end

  test "the displayed credit always describes the displayed image", ctx do
    provider_thumbnail = "https://images.example.test/fixture.jpg"

    Repo.get_by!(Registry.Entity, object_id: ctx.work.object_id)
    |> Ecto.Changeset.change(
      metadata: %{
        "image_url" => "https://upload.example.test/independent.jpg",
        "image_attribution" => "Independent_File.jpg \u00b7 Wikimedia Commons"
      }
    )
    |> Repo.update!()

    artwork = Artworks.get(ctx.work.object_id)

    if artwork.image_url == provider_thumbnail do
      assert artwork.image_attribution == "Fixture credit"
    else
      refute artwork.image_attribution == "Fixture credit"
    end
  end

  test "a definition's artwork candidate reaches the composer only for a contributor", ctx do
    war = word!(ctx, "war", ["wordnet"])

    sense =
      sense!(ctx, war, "wordnet",
        external_id: "oewn-00975181-n#war",
        gloss: "organized armed conflict or warfare"
      )

    assert %{installed: 1} = Artworks.install_meaning_mappings!()

    {:ok, anonymous, _html} = live(ctx.conn, ~p"/define/war")

    assert has_element?(anonymous, "#culture-result-catalog_artwork-c#{ctx.work.object_id}")
    refute has_element?(anonymous, "#in-culture a[href^='/connect?']")

    %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
    Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    {:ok, contributor, _html} = live(conn, ~p"/define/war")

    # The composer link followed the candidate onto the shelf, with the exact
    # sense and the evidence locator still preselected.
    assert has_element?(
             contributor,
             "#culture-connect-c#{ctx.work.object_id}[href^='/connect?'][href*='predicate=illustrates']"
           )

    assert has_element?(
             contributor,
             "#culture-connect-c#{ctx.work.object_id}[href*='object=#{sense.object_id}']"
           )
  end

  test "a malformed revision query parameter is rejected, not a crash", ctx do
    # `?revision[]=1` arrives as a list rather than a binary.
    {:ok, malformed, html} = live(ctx.conn, "/connections/#{ctx.claim.id}?revision[]=1")
    assert html =~ "no such connection"
    refute render(malformed) =~ "revision 1"

    {:ok, view, _html} = live(ctx.conn, "/connections/#{ctx.claim.id}?revision=1")
    assert render(view) =~ "revision 1"
  end

  test "with no provider client at all the catalog, search and word page work locally", ctx do
    # #109 Phase 3a retired the Artsy client and the page's live-search form
    # with it. The page is the local catalog and nothing else.
    {:ok, view, _html} = live(ctx.conn, ~p"/artworks")
    refute has_element?(view, "#artsy-lookup")
    refute has_element?(view, "#artsy-search")

    html = view |> form("#artwork-search", search: %{q: "Fixture Painter"}) |> render_change()
    assert html =~ ~s(id="artwork-#{ctx.work.object_id}")

    war = word!(ctx, "war", ["wordnet"])
    sense!(ctx, war, "wordnet", external_id: "oewn-00975181-n#war", gloss: "armed conflict")
    assert %{installed: 1} = Artworks.install_meaning_mappings!()

    {:ok, word_view, _html} = live(ctx.conn, ~p"/define/war")
    assert has_element?(word_view, "#culture-filter-artwork", "Artworks")
  end

  test "an artwork with no image renders an honest placeholder, not a broken entry", ctx do
    {:ok, bare} =
      Registry.create_work(%{preferred_label: "Bare Fixture", work_kind: "artwork"})

    {:ok, view, _html} = live(ctx.conn, ~p"/artworks")

    assert has_element?(view, "#artwork-#{bare.object_id}-image[data-image-state='empty']")

    assert has_element?(
             view,
             "#artwork-#{bare.object_id}-image [data-artwork-fallback]:not([hidden])"
           )

    refute has_element?(view, "#artwork-#{bare.object_id}-image img[data-artwork-image]")
    assert render(view) =~ "Bare Fixture"

    {:ok, page, _html} =
      live(
        ctx.conn,
        ~p"/entities/#{bare.object_id}/#{DevilsDictionary.Claims.Connection.slugify("Bare Fixture")}"
      )

    assert has_element?(page, "#entity-artwork[data-image-state='empty']")
    assert has_element?(page, "#entity-artwork [data-artwork-fallback]:not([hidden])")
  end
end
