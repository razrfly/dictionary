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

  test "a checkpoint matches its own manifest and never a different selection" do
    one = %{"qid" => "Q1", "artsy_artwork_slug" => "one", "kind" => "painting"}
    two = %{"qid" => "Q2", "artsy_artwork_slug" => "two", "kind" => "painting"}

    base = Manifest.new([one, two])

    # A checkpoint is the same selection with import state moved on. Its own
    # checksum differs, but its identities must not.
    checkpoint = Manifest.update_candidate(base, 0, %{"status" => "matched"})
    refute checkpoint["checksum"] == base["checksum"]
    assert Manifest.same_selection?(checkpoint, base)

    refute Manifest.same_selection?(Manifest.new([one]), base)
    refute Manifest.same_selection?(Manifest.new([two, one]), base)

    renamed = %{"qid" => "Q2", "artsy_artwork_slug" => "two-b", "kind" => "painting"}
    refute Manifest.same_selection?(Manifest.new([one, renamed]), base)
  end

  test "completed statuses are resumable while quota is retried" do
    for status <- ~w(matched created skipped conflict unavailable) do
      assert Manifest.completed?(%{"import" => %{"status" => status}})
    end

    refute Manifest.completed?(%{"import" => %{"status" => "quota_exhausted"}})
  end
end
