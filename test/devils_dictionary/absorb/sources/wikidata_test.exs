defmodule DevilsDictionary.Absorb.Sources.WikidataTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Fixtures

  @lemmas ~w(cat dog oyster seal)

  defp records(lemma), do: Fixtures.raw("wikidata", lemma)
  defp all_records, do: Enum.flat_map(@lemmas, &records/1)
  defp general_records, do: Fixtures.raw("wikidata", "general_entities")
  defp film_records, do: Fixtures.raw("wikidata", "films")

  defp entity(lemma, qid), do: Enum.find(records(lemma), &(&1["id"] == qid))

  defp out(raw) do
    {:ok, out} =
      raw
      |> Wikidata.trim()
      |> Fixtures.source_record(source_id: 3, id: 99)
      |> Wikidata.materialize()

    out
  end

  defp bytes(term), do: term |> Jason.encode!() |> byte_size()

  describe "trim/1" do
    test "retains declared facts and omits unprojected statement detail" do
      raw = Enum.find(general_records(), &(&1["id"] == "Q191050"))
      trimmed = Wikidata.trim(raw)

      assert Map.has_key?(trimmed["claims"], "P31")
      refute Map.has_key?(trimmed["claims"], "P999999")

      assert [statement] = trimmed["claims"]["P31"]
      assert Map.keys(statement) |> Enum.sort() == ~w(mainsnak rank type)
      refute Map.has_key?(statement, "qualifiers")
      refute Map.has_key?(statement, "references")
    end

    test "keeps only the whitelisted properties" do
      for raw <- all_records() do
        kept = raw |> Wikidata.trim() |> get_in(["claims"]) |> Map.keys()
        assert kept -- Wikidata.kept_properties() == []
      end
    end

    test "strips references and qualifiers from the statements it keeps" do
      trimmed = Wikidata.trim(entity("cat", "Q146"))

      for {_property, statements} <- trimmed["claims"], statement <- statements do
        assert Enum.sort(Map.keys(statement)) -- ~w(mainsnak rank type) == []
      end
    end

    test "keeps the multilingual label, which is where taxon names now live" do
      # Wikidata moved taxon names to `mul`; dropping it left 41% of the taxa in
      # a 590-concept slice with no label at all.
      felis = entity("cat", "Q20980826")
      assert get_in(Wikidata.trim(felis), ["labels", "mul", "value"]) == "Felis catus"
    end

    test "saves the bulk of the payload" do
      raw = all_records() |> Enum.map(&bytes/1) |> Enum.sum()
      trimmed = all_records() |> Enum.map(&bytes(Wikidata.trim(&1))) |> Enum.sum()
      saving = 1 - trimmed / raw

      assert saving >= 0.8, "expected >= 80% smaller, got #{Float.round(saving * 100, 1)}%"
    end

    test "loses nothing materialized" do
      for raw <- all_records() do
        full = Fixtures.source_record(raw, source_id: 3, id: 99)
        lean = Fixtures.source_record(Wikidata.trim(raw), source_id: 3, id: 99)

        assert Wikidata.materialize(full) == Wikidata.materialize(lean)
      end
    end
  end

  describe "materialize/1" do
    test "artwork and artist crosswalks keep Wikidata properties and namespaces exact" do
      artwork =
        %{
          "id" => "Q900086",
          "labels" => %{"en" => %{"value" => "Fixture Work"}},
          "descriptions" => %{},
          "aliases" => %{},
          "sitelinks" => %{},
          "claims" => %{
            "P31" => [entity_statement("Q3305213")],
            "P11005" => [string_statement("fixture-work", "normal")],
            "P170" => [entity_statement("Q900087")]
          }
        }

      artist =
        %{
          "id" => "Q900087",
          "labels" => %{"en" => %{"value" => "Fixture Artist"}},
          "descriptions" => %{},
          "aliases" => %{},
          "sitelinks" => %{},
          "claims" => %{
            "P31" => [entity_statement("Q5")],
            "P2042" => [string_statement("fixture-artist", "normal")]
          }
        }

      assert [work] = out(artwork).concepts
      assert work.kind == :work
      assert work.work_kind == "artwork"
      assert work.metadata["wikidata_creators"] == ["Q900087"]

      assert Enum.any?(
               work.external_identifiers,
               &(&1.namespace == "artsy_artwork_slug" and &1.external_id == "fixture-work")
             )

      assert [person] = out(artist).concepts
      assert person.kind == :person

      assert Enum.any?(
               person.external_identifiers,
               &(&1.namespace == "artsy_artist_slug" and &1.external_id == "fixture-artist")
             )
    end

    test "film records expose exact cross-provider identifiers and release year" do
      titanic = film_records() |> Enum.find(&(&1["id"] == "Q44578")) |> out()
      assert [concept] = titanic.concepts

      assert concept.kind == :work
      assert concept.work_kind == "film"
      assert concept.first_published_year == 1997

      assert MapSet.new(concept.external_identifiers, &{&1.namespace, &1.external_id}) ==
               MapSet.new([
                 {"wikidata", "Q44578"},
                 {"tmdb_movie", "597"},
                 {"imdb_title", "tt0120338"}
               ])
    end

    test "publication years preserve BCE signs" do
      raw = Enum.find(film_records(), &(&1["id"] == "Q44578"))

      bce =
        put_in(
          raw,
          ["claims", "P577", Access.at(0), "mainsnak", "datavalue", "value", "time"],
          "-0500-01-01T00:00:00Z"
        )

      assert [concept] = out(bce).concepts
      assert concept.first_published_year == -500
    end

    test "film crosswalks honor preferred and deprecated Wikidata ranks" do
      raw = Enum.find(film_records(), &(&1["id"] == "Q44578"))

      ranked =
        put_in(raw, ["claims", "P345"], [
          string_statement("tt0000001", "normal"),
          string_statement("tt0120338", "preferred"),
          string_statement("tt9999999", "deprecated")
        ])

      assert [concept] = out(ranked).concepts

      assert Enum.filter(concept.external_identifiers, &(&1.namespace == "imdb_title")) == [
               %{
                 namespace: "imdb_title",
                 external_id: "tt0120338",
                 metadata: %{
                   "statement_policy" => "preferred_else_normal",
                   "wikidata_property" => "P345"
                 }
               }
             ]
    end

    test "projects representative people, works, organizations, places and events" do
      expected = %{
        "Q191050" => :person,
        "Q92640" => :work,
        "Q180" => :organization,
        "Q270" => :place,
        "Q43653" => :event
      }

      visited =
        for raw <- general_records(), Map.has_key?(expected, raw["id"]) do
          assert [concept] = out(raw).concepts
          assert concept.kind == expected[raw["id"]]
          assert [_ | _] = concept.metadata["wikidata_instance_of"]
          raw["id"]
        end

      assert Enum.sort(visited) == expected |> Map.keys() |> Enum.sort()
    end

    test "same-name records remain distinct identities" do
      concepts =
        general_records()
        |> Enum.filter(&(&1["id"] in ["Q9000001", "Q9000002"]))
        |> Enum.map(fn raw -> out(raw).concepts |> List.first() end)

      assert Enum.map(concepts, & &1.label) == ["Same Name", "Same Name"]
      assert Enum.map(concepts, & &1.qid) == ["Q9000001", "Q9000002"]
      assert Enum.map(concepts, & &1.kind) == [:person, :work]
    end

    test "an everyday concept keeps the no-opinion kind and bridges to its taxon" do
      assert [concept] = out(entity("cat", "Q146")).concepts

      assert concept.qid == "Q146"
      assert concept.label == "cat"
      # `:concept` is the no-opinion entity kind — the one another source may
      # sharpen — which is what MVP-0's `:thing` meant.
      assert concept.kind == :concept
      assert concept.metadata["wikipedia_title"] == "Cat"
      assert concept.metadata["wordnet_ili"] == "i46593"
      assert concept.metadata["image_url"] =~ "upload.wikimedia.org/wikipedia/commons/thumb/"

      # Q146 *cat* and Q20980826 *Felis catus* are different entities; P13176 is
      # the bridge, and it becomes a `taxon_item` claim.
      assert concept.taxon_concept == "Q20980826"
      refute Map.has_key?(concept.metadata, "taxon")
    end

    test "a taxon item carries its rank, binomial and English common names" do
      assert [concept] = out(entity("cat", "Q20980826")).concepts

      assert concept.kind == :taxon
      assert concept.label == "Felis catus"
      assert concept.metadata["taxon"]["scientific_name"] == "Felis catus"
      assert concept.metadata["taxon"]["rank"] == "Q7432"
      assert "cat" in concept.metadata["taxon"]["common_names"]

      # It already is the taxon, so there is nothing to bridge to.
      assert concept.taxon_concept == nil

      # And it has no English Wikipedia article of its own — the article lives
      # on the everyday concept. §3's `wikidata_taxon` rule assumes otherwise.
      refute Map.has_key?(concept.metadata, "wikipedia_title")
    end

    test "taxonomy edges are typed by property" do
      relations = out(entity("cat", "Q20980826")).concept_relations

      assert %{
               from_concept: "Q20980826",
               to_concept: "Q228283",
               type: :parent_taxon,
               property: "P171"
             } =
               Enum.find(relations, &(&1.type == :parent_taxon))

      assert Enum.all?(relations, &(&1.type in [:parent_taxon, :subclass_of, :instance_of]))
      refute Enum.any?(relations, &(&1.to_concept == &1.from_concept))
    end

    test "an absent marker materializes to nothing at all" do
      assert {:ok, %{}} == Wikidata.materialize(Fixtures.source_record(%{}, source_id: 3, id: 9))
    end
  end

  describe "thumbnail_url/1" do
    test "the Commons thumbnail path, derived rather than redirected to" do
      # `commons.wikimedia.org/wiki/Special:FilePath/…` resolves to a real image
      # in three hops, but the hops declare `text/html`, and a browser enforcing
      # `nosniff` on an image subresource refuses the load. Every such URL was a
      # broken picture. So the path Commons actually serves is derived: the two
      # directory segments are the first one and two hex characters of the MD5 of
      # the file name with underscores for spaces.
      assert Wikidata.thumbnail_url("Two american alligators.jpg") ==
               "https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/" <>
                 "Two_american_alligators.jpg/500px-Two_american_alligators.jpg"
    end

    test "an SVG is thumbnailed to PNG, so the thumb gains an extension" do
      assert Wikidata.thumbnail_url("Tide overview.svg") ==
               "https://upload.wikimedia.org/wikipedia/commons/thumb/e/eb/" <>
                 "Tide_overview.svg/500px-Tide_overview.svg.png"
    end

    test "a name too long for the column falls back to the original file" do
      # A thumbnail URL names the file twice, so a long name overflows the
      # 255-byte column and would be dropped. The original path names it once.
      long =
        "Die Säugthiere in Abbildungen nach der Natur, mit Beschreibungen (Plate CVIII) (8557366038).jpg"

      url = Wikidata.thumbnail_url(long)

      assert byte_size(url) <= 255
      refute url =~ "/thumb/"
      assert url =~ "/wikipedia/commons/b/bc/"
    end

    test "the width is one Wikimedia will still serve" do
      # It no longer generates arbitrary sizes: 500px answers, 400px does not.
      assert Wikidata.thumbnail_url("Blindshark.jpg") =~ "/500px-"
    end

    test "no image is no URL" do
      assert Wikidata.thumbnail_url(nil) == nil
    end
  end

  describe "the behaviour" do
    test "slug and rate limit" do
      assert Wikidata.slug() == "wikidata"
      assert Wikidata.rate_limit_ms() >= 200
    end
  end

  defp string_statement(value, rank) do
    %{
      "rank" => rank,
      "type" => "statement",
      "mainsnak" => %{
        "snaktype" => "value",
        "datavalue" => %{"type" => "string", "value" => value}
      }
    }
  end

  defp entity_statement(qid) do
    %{
      "rank" => "normal",
      "type" => "statement",
      "mainsnak" => %{
        "datavalue" => %{"value" => %{"id" => qid}, "type" => "wikibase-entityid"}
      }
    }
  end
end
