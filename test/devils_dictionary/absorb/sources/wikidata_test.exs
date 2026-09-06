defmodule DevilsDictionary.Absorb.Sources.WikidataTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Fixtures

  @lemmas ~w(cat dog oyster seal)

  defp records(lemma), do: Fixtures.raw("wikidata", lemma)
  defp all_records, do: Enum.flat_map(@lemmas, &records/1)

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
    test "an everyday concept keeps kind :thing and bridges to its taxon item" do
      assert [concept] = out(entity("cat", "Q146")).concepts

      assert concept.qid == "Q146"
      assert concept.label == "cat"
      assert concept.kind == :thing
      assert concept.wikipedia_title == "Cat"
      assert concept.wordnet_ili == "i46593"
      assert concept.image_url =~ "upload.wikimedia.org/wikipedia/commons/thumb/"

      # Q146 *cat* and Q20980826 *Felis catus* are different entities; P13176 is
      # the bridge and it is what `taxon_concept_id` is for.
      assert concept.taxon_concept == "Q20980826"
      assert concept.taxon == %{}
    end

    test "a taxon item carries its rank, binomial and English common names" do
      assert [concept] = out(entity("cat", "Q20980826")).concepts

      assert concept.kind == :taxon
      assert concept.label == "Felis catus"
      assert concept.taxon["scientific_name"] == "Felis catus"
      assert concept.taxon["rank"] == "Q7432"
      assert "cat" in concept.taxon["common_names"]

      # It already is the taxon, so there is nothing to bridge to.
      assert concept.taxon_concept == nil

      # And it has no English Wikipedia article of its own — the article lives
      # on the everyday concept. §3's `wikidata_taxon` rule assumes otherwise.
      assert concept.wikipedia_title == nil
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
end
