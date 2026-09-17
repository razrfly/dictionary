defmodule DevilsDictionary.Artworks.Corpus.SeederTest do
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Registry.{Entity, Object, WorkDetails}

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  defp met_manifest(rows), do: Manifest.new("met-highlights", rows)
  defp famous_manifest(rows), do: Manifest.new("wikidata-famous", rows)

  defp met_row(attrs \\ %{}) do
    Map.merge(
      %{
        "met_object_id" => "436535",
        "title" => "Wheat Field with Cypresses",
        "artist" => "Vincent van Gogh",
        "date" => "1889",
        "medium" => "Oil on canvas",
        "image_url" => "https://images.metmuseum.org/436535.jpg",
        "credit_line" => "Purchase, The Annenberg Foundation Gift, 1993",
        "source_url" => "https://www.metmuseum.org/art/collection/search/436535",
        "tags" => [%{"term" => "Cypress", "qid" => "Q147065"}]
      },
      attrs
    )
  end

  defp famous_row(attrs \\ %{}) do
    Map.merge(
      %{
        "qid" => "Q12418",
        "title" => "Mona Lisa",
        "sitelinks" => 146,
        "date" => "1503",
        "image_url" => "https://upload.wikimedia.org/wikipedia/commons/thumb/x/xx/Mona.jpg",
        "commons_file" => "Mona Lisa.jpg",
        "credit_line" => "Mona Lisa.jpg · Wikimedia Commons",
        "source_url" => "https://www.wikidata.org/wiki/Q12418",
        "creators" => [%{"qid" => "Q762", "term" => "Leonardo da Vinci"}],
        "depicts" => [%{"qid" => "Q26513196", "term" => "Lisa del Giocondo"}]
      },
      attrs
    )
  end

  test "a Met row seeds onto the #86 structures and a rerun changes nothing" do
    manifest = met_manifest([met_row(%{"qid" => "Q1621239"})])

    assert {:ok, first} = Seeder.run(manifest)
    assert first.newly_created == 1
    assert first.matched == 0

    object_id = Registry.by_external_id("met_object_id", "436535")
    assert object_id == Registry.by_external_id("wikidata", "Q1621239")
    assert Repo.get!(WorkDetails, object_id).work_kind == "artwork"

    entity = Repo.get!(Entity, object_id)
    assert entity.entity_kind == :work
    assert entity.preferred_label == "Wheat Field with Cypresses"
    assert entity.metadata["catalog_source"] == "met"
    assert entity.metadata["depicts_qids"] == ["Q147065"]
    assert entity.metadata["image_attribution"] =~ "Annenberg"
    assert entity.metadata["artist_display_name"] == "Vincent van Gogh"

    objects = Repo.aggregate(Object, :count)

    assert {:ok, again} = Seeder.run(met_manifest([met_row(%{"qid" => "Q1621239"})]))
    assert again.matched == 1
    assert again.newly_created == 0
    assert Repo.aggregate(Object, :count) == objects

    assert Repo.aggregate(
             from(details in WorkDetails, where: details.work_kind == "artwork"),
             :count
           ) == 1
  end

  test "a dry run counts what it would seed and writes nothing" do
    assert {:ok, summary} = Seeder.run(met_manifest([met_row()]), dry_run: true)

    assert summary.would_seed == 1
    assert summary.with_image == 1
    assert summary.with_depicts == 1
    assert summary.depicted_qids == 1

    assert Repo.aggregate(
             from(details in WorkDetails, where: details.work_kind == "artwork"),
             :count
           ) == 0
  end

  test "a Wikidata row identifies by QID and carries its depictions and sitelinks" do
    assert {:ok, summary} = Seeder.run(famous_manifest([famous_row()]))
    assert summary.newly_created == 1

    object_id = Registry.by_external_id("wikidata", "Q12418")
    entity = Repo.get!(Entity, object_id)

    assert Repo.get!(WorkDetails, object_id).work_kind == "artwork"
    assert entity.metadata["catalog_source"] == "wikidata"
    assert entity.metadata["sitelinks"] == 146
    assert entity.metadata["depicts_qids"] == ["Q26513196"]
    assert entity.metadata["artist_display_name"] == "Leonardo da Vinci"
    assert entity.metadata["creator_qids"] == ["Q762"]
    assert Repo.get!(WorkDetails, object_id).first_published_year == 1503
  end

  test "a row with no identity is counted invalid rather than half-seeded" do
    assert {:ok, summary} =
             Seeder.run(met_manifest([met_row()]) |> put_in(["rows", Access.at(0), "title"], ""))

    assert summary.invalid == 1
    assert summary.invalid_reasons == %{"missing_required_field" => 1}

    assert Repo.aggregate(
             from(details in WorkDetails, where: details.work_kind == "artwork"),
             :count
           ) == 0
  end

  describe "Artworks.suggestions/1 QID path" do
    setup ctx do
      war = word!(ctx, "war", ["wordnet"])
      sense = sense!(ctx, war, "wordnet", gloss: "the waging of armed conflict")
      entity = concept!("Q198", "War")
      link!(war, entity, sense: sense, confidence: 0.95)

      {:ok, _} =
        Seeder.run(
          met_manifest([met_row(%{"tags" => [%{"term" => "Soldiers", "qid" => "Q198"}]})])
        )

      Map.merge(ctx, %{war: war, sense: sense, entity: entity})
    end

    test "a depicted QID equal to a sense's refers_to entity is a direct candidate", ctx do
      assert [candidate] = Artworks.suggestions([ctx.war.object_id])

      assert candidate.sense_id == ctx.sense.object_id
      assert candidate.match_type == "direct"
      assert candidate.match_reason.kind == "depicted_qid"
      assert candidate.match_reason.provider == "The Met"
      assert candidate.match_reason.qid == "Q198"
      assert candidate.match_reason.scope == :sense
      assert candidate.match_reason.detail =~ "depiction of"
      assert candidate.match_reason.detail =~ "Q198"
      assert candidate.artwork.title == "Wheat Field with Cypresses"
      assert candidate.artwork.catalog_source == "met"
      assert candidate.artwork.artist == "Vincent van Gogh"
      assert candidate.artwork.collection == "The Metropolitan Museum of Art"
    end

    test "a word-level entity candidate is offered, and says it is about the word", ctx do
      love = word!(ctx, "love", ["wordnet"])
      _sense = sense!(ctx, love, "wordnet", gloss: "a strong affection")
      entity = concept!("Q316", "love")
      link!(love, entity, method: :title_match)

      {:ok, _} =
        Seeder.run(
          famous_manifest([famous_row(%{"depicts" => [%{"qid" => "Q316", "term" => "love"}]})])
        )

      assert [candidate] = Artworks.suggestions([love.object_id])

      assert candidate.match_type == "related"
      assert candidate.match_reason.scope == :lexeme
      assert candidate.match_reason.provider == "Wikidata"
      assert candidate.match_reason.detail =~ "matched to the word and not to this meaning"
      assert candidate.artwork.title == "Mona Lisa"
    end

    test "a QID nothing in the catalog depicts yields nothing", ctx do
      ship = word!(ctx, "ship", ["wordnet"])
      sense = sense!(ctx, ship, "wordnet", gloss: "a large vessel")
      link!(ship, concept!("Q11446", "ship"), sense: sense)

      assert Artworks.suggestions([ship.object_id]) == []
    end

    test "a Met object already on the page's shelf is not offered twice", ctx do
      assert [_candidate] = Artworks.suggestions([ctx.war.object_id])

      assert Artworks.suggestions([ctx.war.object_id], exclude_met_object_ids: ["436535"]) == []
    end

    test "the page's own persisted Met results are excluded by default", ctx do
      shelve_met_result!(ctx, "436535")

      assert Artworks.suggestions([ctx.war.object_id]) == []
    end
  end

  # The 2a shelf, as the database holds it: a Met run against this page's target
  # with one result carrying the object id the catalog also has.
  defp shelve_met_result!(ctx, met_object_id) do
    actor =
      Repo.insert!(
        %DevilsDictionary.Sources.Actor{}
        |> DevilsDictionary.Sources.Actor.changeset(%{actor_kind: :import, label: "corpus test"})
      )

    mapping =
      Repo.insert!(
        Mapping.create_changeset(%Mapping{}, %{
          mapping_key: "met:#{ctx.war.object_id}",
          version: 1,
          target_object_id: ctx.war.object_id,
          source_id: ctx.sources["met"].id,
          operation: "tag_qid_discovery",
          parameters: %{},
          configured_by_actor_id: actor.id,
          enabled: true
        })
      )

    now = DateTime.utc_now()

    run =
      Repo.insert!(
        Run.create_changeset(%Run{}, %{
          mapping_id: mapping.id,
          adapter_version: "met.openaccess.v1",
          request_parameters: %{},
          request_key: "test-request",
          position_key: "test-position",
          page_context: Ecto.UUID.generate(),
          page: 0,
          status: :pending
        })
      )

    run =
      Repo.update!(
        Run.lifecycle_changeset(run, %{
          status: :succeeded,
          started_at: now,
          completed_at: now,
          refresh_after: DateTime.add(now, 3_600),
          expires_at: DateTime.add(now, 86_400),
          completion_reason: :results,
          result_count: 1,
          request_count: 1
        })
      )

    Repo.insert!(
      Result.changeset(%Result{}, %{
        run_id: run.id,
        external_namespace: "met_object",
        external_id: met_object_id,
        position: 0,
        match_details: %{},
        preview_metadata: %{},
        display_allowed: true,
        resolution_state: :matched
      })
    )
  end
end
