defmodule DevilsDictionary.SourceIdentityTest do
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.{Wikidata, Wikipedia}
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, WorkDetails}
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.ReconciliationCase

  setup do
    %{sources: sources} = DevilsDictionary.Fixtures.seed_catalog!()
    %{sources: sources}
  end

  describe "film identity resolution" do
    test "CineGraph then Wikidata preserves one Titanic object and URL", ctx do
      movie = cinegraph_movie(597)
      wikidata = wikidata_movie("Q44578")

      first = resolve_cinegraph!(ctx.sources["cinegraph"], movie)
      assert first.state == :newly_created
      original_path = entity_path(first.object_id, "Titanic")

      resolve_wikidata!(ctx.sources["wikidata"], wikidata)

      wikipedia_content =
        resolve_wikipedia!(ctx.sources["wikipedia"], wikipedia_movie("Q44578"))

      assert Registry.by_external_id("wikidata", "Q44578") == first.object_id
      assert Registry.by_external_id("wikidata", "Q44578") == wikipedia_content.about_object_id
      assert_film(first.object_id, "Titanic", 1997)
      assert_identifiers(first.object_id, "597", "tt0120338", "Q44578")
      assert entity_path(first.object_id, "Titanic") == original_path

      assert wikipedia_content.source_url ==
               "https://en.wikipedia.org/wiki/Titanic_(1997_film)"

      page = EntityPage.build(first.object_id)
      assert Enum.map(page.sources, & &1.slug) == ["cinegraph", "wikidata"]
      assert Enum.any?(page.biography, &(&1.url == wikipedia_content.source_url))
    end

    test "Wikidata then CineGraph preserves one Everest object and URL", ctx do
      wikidata = wikidata_movie("Q15631013")
      movie = cinegraph_movie(253_412)

      wikipedia_id =
        resolve_wikipedia!(ctx.sources["wikipedia"], wikipedia_movie("Q15631013")).about_object_id

      first_id = resolve_wikidata!(ctx.sources["wikidata"], wikidata)
      result = resolve_cinegraph!(ctx.sources["cinegraph"], movie)

      assert result.state == :matched
      assert result.object_id == first_id
      assert wikipedia_id == first_id
      assert_film(first_id, "Everest", 2015)
      assert_identifiers(first_id, "253412", "tt2719848", "Q15631013")
      assert entity_path(first_id, "Everest") == "/entities/#{first_id}/everest"
    end

    test "TMDb-only and IMDb-only proposals reuse supported exact identifiers", ctx do
      tmdb = entry!(ctx, "tmdb-only", [%{namespace: "tmdb_movie", external_id: "700"}])
      imdb = entry!(ctx, "imdb-only", [%{namespace: "imdb_title", external_id: "tt0000700"}])

      tmdb_created = SourceIdentity.resolve(tmdb)
      imdb_created = SourceIdentity.resolve(imdb)

      assert SourceIdentity.resolve(tmdb).object_id == tmdb_created.object_id
      assert SourceIdentity.resolve(imdb).object_id == imdb_created.object_id
      refute tmdb_created.object_id == imdb_created.object_id
    end

    test "missing Wikidata and Wikipedia still creates a useful source-backed film", ctx do
      result =
        resolve_cinegraph!(ctx.sources["cinegraph"], %{
          "tmdbId" => 991_001,
          "imdbId" => nil,
          "title" => "Fixture Without Crosswalk",
          "releaseDate" => "2024-01-01",
          "posterPath" => nil,
          "cinegraphUrl" => "https://cinegraph.org/movies/991001"
        })

      assert result.state == :newly_created
      assert_film(result.object_id, "Fixture Without Crosswalk", 2024)
      assert Registry.by_external_id("wikidata", "Q991001") == nil

      page = EntityPage.build(result.object_id)
      assert page.entity.label == "Fixture Without Crosswalk"
      assert page.details.work_kind == "film"
      assert Enum.map(page.sources, & &1.slug) == ["cinegraph"]

      assert {:error, :stable_identifier_required} =
               Entry.new(%{
                 source_slug: "fixture",
                 object_kind: :entity,
                 entity_kind: :work,
                 work_kind: "film",
                 label: "Film without any source identity",
                 eligibility: :eligible,
                 retention: :durable
               })
    end

    test "contradictory identifiers open one rerunnable review case", ctx do
      a = entry!(ctx, "conflict-a", [%{namespace: "tmdb_movie", external_id: "810"}])
      b = entry!(ctx, "conflict-b", [%{namespace: "imdb_title", external_id: "tt0000811"}])
      first = SourceIdentity.resolve(a)
      second = SourceIdentity.resolve(b)

      conflict =
        entry!(ctx, "conflict-record", [
          %{namespace: "tmdb_movie", external_id: "810"},
          %{namespace: "imdb_title", external_id: "tt0000811"}
        ])

      resolution = SourceIdentity.resolve(conflict)
      again = SourceIdentity.resolve(conflict)

      assert resolution.state == :conflicting_identifiers
      assert resolution.object_id == nil
      assert resolution.conflict_id == again.conflict_id
      assert Repo.aggregate(ReconciliationCase, :count) == 1
      assert first.object_id != second.object_id
    end

    test "titles and years never merge remakes or a non-film namesake", ctx do
      first = entry!(ctx, "same-title-a", [%{namespace: "tmdb_movie", external_id: "820"}])
      second = entry!(ctx, "same-title-b", [%{namespace: "tmdb_movie", external_id: "821"}])

      first = SourceIdentity.resolve(%{first | label: "Titanic", year: 1953})
      second = SourceIdentity.resolve(%{second | label: "Titanic", year: 1997})
      {:ok, ship} = Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Titanic"})

      assert first.object_id != second.object_id
      assert ship.object_id not in [first.object_id, second.object_id]
    end
  end

  @tag :unboxed
  test "concurrent creation and retries converge on one object", ctx do
    entry = entry!(ctx, "concurrent", [%{namespace: "tmdb_movie", external_id: "830"}])
    parent = self()
    gate = make_ref()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: ({:go, ^gate} -> SourceIdentity.resolve(entry))
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, {:go, gate}))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [object_id] = results |> Enum.map(& &1.object_id) |> Enum.uniq()
    assert Registry.by_external_id("tmdb_movie", "830") == object_id
  end

  describe "shared adapter contract" do
    test "an artwork reuses Wikidata while a reproduction remains distinct", ctx do
      {:ok, artwork} =
        Registry.create_work(%{preferred_label: "Fixture Artwork", work_kind: "artwork"})

      {:ok, _} = Registry.add_external_id(artwork.object_id, "wikidata", "Q900100")

      proposal =
        entry!(
          ctx,
          "artwork",
          [
            %{namespace: "museum_artwork", external_id: "A-1"},
            %{namespace: "wikidata", external_id: "Q900100"}
          ],
          work_kind: "artwork"
        )

      reproduction =
        entry!(ctx, "reproduction", [%{namespace: "museum_object", external_id: "R-1"}],
          work_kind: "reproduction",
          relationships: [
            %{role: :reproduction_of, target_object_id: artwork.object_id, certainty: :verified}
          ]
        )

      assert SourceIdentity.resolve(proposal).object_id == artwork.object_id
      refute SourceIdentity.resolve(reproduction).object_id == artwork.object_id
    end

    test "an ineligible quotation can still reference an independently resolved author", ctx do
      author =
        entry!(ctx, "author", [%{namespace: "wikidata", external_id: "Q900200"}],
          entity_kind: :person,
          work_kind: nil,
          label: "Fixture Author"
        )

      author_resolution = SourceIdentity.resolve(author)

      assert {:ok, quotation} =
               Entry.new(%{
                 source_slug: "fixture",
                 object_kind: :content,
                 content_kind: :quotation,
                 entity_kind: nil,
                 eligibility: :insufficient_evidence,
                 eligibility_reason: "wording_has_no_stable_identity",
                 # #164 C2: a content proposal carries its text, eligible or not.
                 content: %{body: "A fixture line."},
                 retention: :durable,
                 relationships: [
                   %{
                     role: :author,
                     target_object_id: author_resolution.object_id,
                     certainty: :verified
                   }
                 ]
               })

      assert SourceIdentity.resolve(quotation).state == :insufficient_evidence
      assert hd(quotation.relationships).target_object_id == author_resolution.object_id
      assert Repo.get!(Entity, author_resolution.object_id).entity_kind == :person
      assert Claims.count_incoming(author_resolution.object_id) == 0

      assert {:ok, uncertain} =
               Entry.new(%{
                 source_slug: "fixture",
                 object_kind: :content,
                 content_kind: :quotation,
                 entity_kind: nil,
                 eligibility: :insufficient_evidence,
                 eligibility_reason: "uncertain_attribution",
                 content: %{body: "A fixture line."},
                 retention: :durable,
                 relationships: [
                   %{
                     role: :author,
                     target_object_id: author_resolution.object_id,
                     certainty: :candidate
                   }
                 ]
               })

      assert SourceIdentity.resolve(uncertain).state == :insufficient_evidence
      assert Claims.count_incoming(author_resolution.object_id) == 0
    end
  end

  defp resolve_cinegraph!(source, movie) do
    tmdb_id = Integer.to_string(movie["tmdbId"])

    item = %{
      external_namespace: "tmdb_movie",
      external_id: tmdb_id,
      identifiers:
        [%{namespace: "tmdb_movie", external_id: tmdb_id}] ++
          if(movie["imdbId"],
            do: [%{namespace: "imdb_title", external_id: movie["imdbId"]}],
            else: []
          ),
      preview_metadata: %{
        "title" => movie["title"],
        "year" => String.slice(movie["releaseDate"], 0, 4),
        "release_date" => movie["releaseDate"],
        "poster_url" => movie["posterPath"],
        "source_url" => movie["cinegraphUrl"]
      }
    }

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "tmdb_movie:#{tmdb_id}",
        url: movie["cinegraphUrl"],
        raw: movie
      })

    {:ok, entry} = CineGraph.identity_record(item)

    SourceIdentity.resolve(%{
      entry
      | source_id: source.id,
        source_record_id: record.id,
        source_record_revision_id: record.current_revision.id
    })
  end

  defp resolve_wikidata!(source, raw) do
    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: raw["id"],
        url: "https://www.wikidata.org/wiki/#{raw["id"]}",
        raw: Wikidata.trim(raw)
      })

    assert {:ok, %{concepts: 1}} = Materializer.run(record, Wikidata)
    Registry.by_external_id("wikidata", raw["id"])
  end

  defp resolve_wikipedia!(source, raw) do
    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "concept:#{get_in(raw, ["pageprops", "wikibase_item"])}",
        url: raw["fullurl"],
        raw: Wikipedia.trim(raw)
      })

    assert {:ok, %{concepts: 1, entries: 1}} = Materializer.run(record, Wikipedia)
    [about] = Claims.incoming(Registry.by_external_id("wikidata", qid(raw)), predicate: "about")

    %{
      about_object_id: about.object_object_id,
      source_url: Registry.current_content_revision(about.subject_object_id).canonical_url
    }
  end

  defp entry!(ctx, key, identifiers, opts \\ []) do
    source = ctx.sources["cinegraph"]

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "fixture:#{key}",
        url: "https://example.test/#{key}",
        raw: %{"key" => key}
      })

    stable = hd(identifiers)

    {:ok, entry} =
      Entry.new(%{
        source_slug: source.slug,
        source_id: source.id,
        source_record_id: record.id,
        source_record_revision_id: record.current_revision.id,
        object_kind: :entity,
        entity_kind: Keyword.get(opts, :entity_kind, :work),
        work_kind: Keyword.get(opts, :work_kind, "film"),
        stable_identifier: stable,
        identifiers: identifiers,
        label: Keyword.get(opts, :label, "Fixture Film"),
        year: Keyword.get(opts, :year, 2024),
        metadata: %{},
        eligibility: :eligible,
        retention: :durable,
        relationships: Keyword.get(opts, :relationships, [])
      })

    entry
  end

  defp cinegraph_movie(tmdb_id) do
    DevilsDictionary.Fixtures.raw("cinegraph", "films")
    |> Enum.find(&(&1["tmdbId"] == tmdb_id))
  end

  defp wikidata_movie(qid) do
    DevilsDictionary.Fixtures.raw("wikidata", "films")
    |> Enum.find(&(&1["id"] == qid))
  end

  defp wikipedia_movie(qid) do
    DevilsDictionary.Fixtures.raw("wikipedia", "films")
    |> Enum.find(&(qid(&1) == qid))
  end

  defp qid(raw), do: get_in(raw, ["pageprops", "wikibase_item"])

  defp assert_film(object_id, label, year) do
    assert %Entity{entity_kind: :work, preferred_label: ^label} = Repo.get!(Entity, object_id)

    assert %WorkDetails{work_kind: "film", first_published_year: ^year} =
             Repo.get!(WorkDetails, object_id)
  end

  defp assert_identifiers(object_id, tmdb_id, imdb_id, qid) do
    identifiers =
      Repo.all(
        from identifier in ExternalIdentifier,
          where: identifier.object_id == ^object_id and identifier.status == :verified,
          select: {identifier.namespace, identifier.external_id}
      )
      |> MapSet.new()

    assert identifiers ==
             MapSet.new([
               {"tmdb_movie", tmdb_id},
               {"imdb_title", imdb_id},
               {"wikidata", qid}
             ])
  end

  defp entity_path(object_id, label) do
    "/entities/#{object_id}/#{DevilsDictionary.Claims.Connection.slugify(label)}"
  end
end
