defmodule DevilsDictionary.Sources.ManifestTest do
  @moduledoc """
  The manifest's job is to fail. #74: "Verify checksum before import and fail
  clearly on mismatch. … Test altered bytes and missing archives."

  So the interesting cases are the two failures, and they are exercised against
  a manifest written into a tmp directory rather than the real one — a test that
  moved `data/raw-wiktextract-data.jsonl.gz` aside to prove `:missing` would be
  a test that can lose a 2.6 GB unreproducible file.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Sources.Manifest

  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  setup do
    dir = Path.join(System.tmp_dir!(), "manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "the real manifest" do
    test "pins every input, and every digest matches the file on disk" do
      assert {:ok, rows} = Manifest.verify()
      assert length(rows) == 5
      assert Enum.all?(rows, &(&1.status == :ok))
    end

    test "agrees with the sha256 Sources.Catalog already pinned for Johnson" do
      # Johnson has been checksum-gated since S5 (`Johnson.verify!/2`). The
      # manifest is only trustworthy if it reproduces the one digest that was
      # already independently pinned — that is what makes this a generalisation
      # of a working mechanism rather than a new set of unverified numbers.
      from_catalog =
        DevilsDictionary.Sources.Catalog.sources()
        |> Enum.find(&(&1.slug == "johnson"))
        |> get_in([Access.key(:config), "sha256"])

      from_manifest = Manifest.input("priv/sources/johnson/johnson-1755-leme.xml.gz")["sha256"]

      assert from_catalog == from_manifest
    end

    test "records that the Wiktionary dump's URL is rolling" do
      # The one input a re-download cannot reproduce. If this flag is ever
      # dropped the manifest starts implying the file is re-fetchable, which is
      # the failure mode #74 calls "a rolling latest URL … is insufficient".
      wikt = Manifest.input("data/raw-wiktextract-data.jsonl.gz")
      assert wikt["url_is_rolling"] == true
      assert wikt["committed"] == false
    end
  end

  describe "digest/1" do
    test "streams rather than reading whole, and matches shasum", %{dir: dir} do
      path = Path.join(dir, "big.bin")
      # Larger than the 1 MB read chunk, so the reduce actually iterates.
      File.write!(path, :binary.copy("wordhoard", 400_000))

      assert Manifest.digest(path) ==
               :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    end

    test "an empty file digests to the known empty hash", %{dir: dir} do
      path = Path.join(dir, "empty.bin")
      File.write!(path, "")
      assert Manifest.digest(path) == @empty_sha
    end
  end

  describe "verify/1 against a written manifest" do
    test "passes when the bytes are the pinned bytes", %{dir: dir} do
      path = write_input(dir, "hello")
      write_manifest(dir, path, Manifest.digest(path))

      assert {:ok, [%{status: :ok}]} = verify(dir)
    end

    test "altered bytes fail, and the failure names both digests", %{dir: dir} do
      path = write_input(dir, "hello")
      pinned = Manifest.digest(path)
      write_manifest(dir, path, pinned)

      File.write!(path, "hello!")

      assert {:error, [row]} = verify(dir)
      assert row.status == :mismatch
      assert row.detail =~ "expected"
      assert row.detail =~ String.slice(pinned, 0, 12)
    end

    test "a single flipped byte is caught — size alone would not be", %{dir: dir} do
      path = write_input(dir, "aaaaaaaaaa")
      write_manifest(dir, path, Manifest.digest(path))

      File.write!(path, "aaaaaaaaab")

      assert File.stat!(path).size == 10
      assert {:error, [%{status: :mismatch}]} = verify(dir)
    end

    test "a missing archive fails and says where to get it", %{dir: dir} do
      path = write_input(dir, "hello")
      write_manifest(dir, path, Manifest.digest(path))

      File.rm!(path)

      assert {:error, [row]} = verify(dir)
      assert row.status == :missing
      assert row.detail =~ "https://example.invalid/input.txt"
    end

    test "an entry with no sha256 is :unpinned, not silently ok", %{dir: dir} do
      path = write_input(dir, "hello")
      write_manifest(dir, path, nil)

      assert {:error, [%{status: :unpinned}]} = verify(dir)
    end

    test "verify/1 filters by source slug", %{dir: dir} do
      path = write_input(dir, "hello")
      write_manifest(dir, path, Manifest.digest(path))

      assert {:ok, [_]} = verify(dir, source: "fixture")
      assert {:ok, []} = verify(dir, source: "nobody")
    end
  end

  defp write_input(dir, body) do
    path = Path.join(dir, "input.txt")
    File.write!(path, body)
    path
  end

  # `Manifest.verify/1` takes the manifest path and a root to resolve locators
  # against, so a fixture manifest needs no `File.cd!` — which changes the
  # working directory of the whole OS process and would make `async: true` a
  # race with every other test in the suite.
  defp write_manifest(dir, input_path, sha) do
    File.mkdir_p!(Path.join(dir, "priv/sources"))

    entry =
      %{
        "source" => "fixture",
        "archive_locator" => Path.relative_to(input_path, dir),
        "acquisition_url" => "https://example.invalid/input.txt",
        "sha256" => sha
      }

    File.write!(
      Path.join(dir, "priv/sources/MANIFEST.json"),
      Jason.encode!(%{"inputs" => [entry]})
    )
  end

  defp verify(dir, opts \\ []) do
    Manifest.verify(
      Keyword.merge([path: Path.join(dir, "priv/sources/MANIFEST.json"), root: dir], opts)
    )
  end
end
