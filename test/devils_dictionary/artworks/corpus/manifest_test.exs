defmodule DevilsDictionary.Artworks.Corpus.ManifestTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Artworks.Corpus.Manifest

  @met_row %{
    "met_object_id" => "436535",
    "title" => "Wheat Field with Cypresses",
    "image_url" => "https://images.metmuseum.org/example.jpg",
    "credit_line" => "Purchase, 1993",
    "tags" => [%{"term" => "Trees", "qid" => "Q10884"}]
  }

  test "rows are deduplicated on the kind's identity and ordered numerically" do
    manifest =
      Manifest.new("met-highlights", [
        Map.put(@met_row, "met_object_id", "1000"),
        Map.put(@met_row, "met_object_id", "10065"),
        Map.put(@met_row, "met_object_id", "1000"),
        Map.put(@met_row, "met_object_id", "")
      ])

    assert Enum.map(manifest["rows"], & &1["met_object_id"]) == ["1000", "10065"]
    assert manifest["row_count"] == 2
    assert manifest["identity"] == "met_object_id"
    assert manifest["source"] == "met"
    assert manifest["manifest"] == "met-highlights-v1"
  end

  test "a saved manifest round trips and a tampered one is refused" do
    path =
      Path.join(System.tmp_dir!(), "corpus-manifest-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm_rf!(path) end)

    saved = Manifest.new("met-highlights", [@met_row]) |> Manifest.save!(path)

    assert Manifest.load!(path) == saved
    assert Manifest.corpus_manifest?(path)

    tampered =
      saved
      |> update_in(["rows", Access.at(0), "title"], fn _ -> "A different picture" end)
      |> Map.put("checksum", saved["checksum"])

    File.write!(path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Manifest.load!(path) end
  end

  test "the Artsy pilot's manifests are not corpus manifests" do
    refute Manifest.corpus_manifest?("priv/artworks/manifests/pilot-v1.json")
  end

  test "wikidata rows identify by QID" do
    manifest =
      Manifest.new("wikidata-famous", [
        %{"qid" => "Q12418", "title" => "Mona Lisa", "sitelinks" => 146},
        %{"qid" => "Q12418", "title" => "Mona Lisa", "sitelinks" => 146}
      ])

    assert manifest["identity"] == "qid"
    assert manifest["row_count"] == 1
  end
end
