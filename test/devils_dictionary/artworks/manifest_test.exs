defmodule DevilsDictionary.Artworks.ManifestTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Artworks.Manifest

  test "round trips a checksummed versioned manifest and rejects edits" do
    path =
      Path.join(System.tmp_dir!(), "artwork-manifest-#{System.unique_integer([:positive])}.json")

    candidate = %{"qid" => "Q1", "artsy_artwork_slug" => "one", "kind" => "painting"}

    manifest = [candidate, candidate] |> Manifest.new() |> Manifest.save!(path)
    assert length(manifest["candidates"]) == 1
    assert Manifest.load!(path)["checksum"] == manifest["checksum"]

    edited = path |> File.read!() |> String.replace("\"one\"", "\"two\"")
    File.write!(path, edited)
    assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Manifest.load!(path) end
  end

  test "completed statuses are resumable while quota is retried" do
    for status <- ~w(matched created skipped conflict unavailable) do
      assert Manifest.completed?(%{"import" => %{"status" => status}})
    end

    refute Manifest.completed?(%{"import" => %{"status" => "quota_exhausted"}})
  end
end
