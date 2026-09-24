defmodule DevilsDictionary.Quotations.Corpus.ManifestConformanceTest do
  @moduledoc """
  The committed quotations corpus, held to its own contract (#174; CodeRabbit
  on #178). The artworks conformance suite reads `priv/artworks/manifests/`
  and asks about `work_details` and depicted QIDs, none of which a quotation
  has, so this manifest is checked here: the whole file for its checksums and
  every row's shape, and a slice seeded and found again by the concept it was
  filed under.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Corpus.Seeder
  alias DevilsDictionary.Quotations
  alias DevilsDictionary.Quotations.Corpus.Build
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Registry

  @moduletag :conformance

  @path Quotations.Corpus.manifest_path()
  @slice 25

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    %{manifest: Manifest.load!(@path), sources: catalog.sources, scopes: catalog.scopes}
  end

  describe "the file" do
    test "verifies against its checksum and its set checksum", %{manifest: manifest} do
      assert manifest["kind"] == "wikiquote-pd"
      assert manifest["manifest"] == "wikiquote-pd-v1"
      assert manifest["identity"] == Manifest.identity_field("wikiquote-pd")
      assert Manifest.evidence("wikiquote-pd") == :concept
      assert manifest["row_count"] == length(manifest["rows"])
      assert manifest["set_checksum"] == Build.set_checksum(manifest["rows"])

      # The source row names the file it is.
      assert Quotations.Corpus.source_attrs().config["manifest_checksum"] == manifest["checksum"]
    end

    test "is not an artworks manifest, and the artworks suite never reads it" do
      refute @path in DevilsDictionary.Artworks.Corpus.Conformance.paths()
    end

    test "every row is a Verified quotation, identified by its own fingerprint",
         %{manifest: manifest} do
      rows = manifest["rows"]
      assert length(Enum.uniq_by(rows, & &1["fingerprint"])) == length(rows)

      for row <- rows do
        assert row["fingerprint"] == Fingerprint.fingerprint(row["text"]), row["text"]
        assert row["badge"] == "verified"
        assert "gutenberg" in row["sources"]
        assert Regex.match?(~r/\AQ[1-9]\d*\z/, row["author_qid"])
        assert Regex.match?(~r/\AQ[1-9]\d*\z/, row["work_qid"])
        assert is_integer(row["work_year"]) and row["work_year"] < Build.public_domain_before()
        assert row["work_year_basis"] in ["P577", "P629 P577"]
        assert row["gutenberg"]["locator"] =~ ~r/\(Gutenberg #\d+\), line \d+\z/
        assert is_integer(row["revision_id"])
        assert is_list(row["concept_qids"])
        assert Enum.all?(row["concept_qids"], &Regex.match?(~r/\AQ[1-9]\d*\z/, &1))
        # Every credited author can be minted offline from the file.
        assert Map.has_key?(manifest["selection"]["authors"], row["author_qid"])
      end
    end
  end

  describe "a slice, seeded" do
    test "resolves once, reseeds to nothing new, and reaches the page it was filed under",
         %{manifest: manifest} = ctx do
      assert {:ok, first} = Seeder.run(manifest, limit: @slice)
      assert first.newly_created + first.matched == @slice
      assert first.invalid == 0

      assert {:ok, again} = Seeder.run(manifest, limit: @slice)
      assert again.matched == @slice and again.newly_created == 0

      [row | _] = Enum.filter(Enum.take(manifest["rows"], @slice), &(&1["concept_qids"] != []))
      [qid | _] = row["concept_qids"]

      word = word!(ctx, "corpus-page", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")

      concept =
        case Registry.by_external_id("wikidata", qid) do
          nil -> concept!(qid, "the page's concept")
          id -> %{object_id: id}
        end

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", concept.object_id, %{confidence: 0.9})

      fingerprints =
        [word.object_id] |> Quotations.Corpus.shelf_items() |> Enum.map(& &1.external_id)

      assert row["fingerprint"] in fingerprints
    end
  end
end
