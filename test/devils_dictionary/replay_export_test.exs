defmodule DevilsDictionary.ReplayExportTest do
  @moduledoc """
  The replay archive is the API sources' equivalent of a pinned dump: Wikipedia's
  85,044 records and Wikidata's 72,770 exist only inside the database. If this
  round-trip is wrong, #74's P5 re-import silently re-fetches instead of
  replaying, and every measured number becomes incomparable.

  The detail worth guarding is `raw["_probe"]`: Wikipedia's absorb embeds the
  lexeme keys there so `materialize/1` can stay pure. An export that flattened
  or dropped it would look fine and be useless.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Sources

  setup do
    %{sources: sources} = DevilsDictionary.Fixtures.seed_catalog!()
    dir = Path.join(System.tmp_dir!(), "replay-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, sources: sources}
  end

  defp export(dir, extra \\ []) do
    Mix.Tasks.Dd.Export.Replay.run(["--out", dir, "--quiet"] ++ extra)
  end

  defp read_lines(dir, slug) do
    path = Path.join(dir, "#{slug}.jsonl.gz")
    z = :zlib.open()
    :zlib.inflateInit(z, 31)
    data = :zlib.inflate(z, File.read!(path)) |> IO.iodata_to_binary()
    :zlib.inflateEnd(z)
    :zlib.close(z)

    data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "a record round-trips with its payload intact", %{dir: dir} do
    source = Sources.get_source_by_slug!("wikipedia")

    raw = %{
      "pageid" => 12_345,
      "extract" => "A small carnivorous mammal.",
      "_probe" => %{"lemma" => "cat", "lexemes" => [["en", "cat", "noun"]]}
    }

    {:ok, _} =
      Sources.upsert_record(source, %{
        external_id: "cat",
        url: "https://en.wikipedia.org/wiki/Cat",
        raw: raw
      })

    export(dir, ["--source", "wikipedia"])

    assert [record] = read_lines(dir, "wikipedia")
    assert record["external_id"] == "cat"
    assert record["url"] == "https://en.wikipedia.org/wiki/Cat"
    assert record["raw"] == raw
  end

  test "the _probe annotation survives, because materialize/1 reads it", %{dir: dir} do
    source = Sources.get_source_by_slug!("wikipedia")

    probe = %{
      "lemma" => "oyster",
      "lexemes" => [["en", "oyster", "noun"], ["en", "Oyster", "name"]]
    }

    {:ok, _} =
      Sources.upsert_record(source, %{external_id: "oyster", raw: %{"_probe" => probe}})

    export(dir, ["--source", "wikipedia"])

    assert [%{"raw" => %{"_probe" => ^probe}}] = read_lines(dir, "wikipedia")
  end

  test "content_hash is carried, so a replay can tell a change from a re-read", %{dir: dir} do
    source = Sources.get_source_by_slug!("bierce")
    {:ok, stored} = Sources.upsert_record(source, %{external_id: "CAT/n", raw: %{"body" => "…"}})

    export(dir, ["--source", "bierce"])

    assert [record] = read_lines(dir, "bierce")
    assert record["content_hash"] == stored.content_hash
    refute is_nil(record["content_hash"])
  end

  test "the manifest digests every file it names", %{dir: dir} do
    source = Sources.get_source_by_slug!("bierce")
    {:ok, _} = Sources.upsert_record(source, %{external_id: "DOG/n", raw: %{"body" => "…"}})

    export(dir)

    manifest = dir |> Path.join("MANIFEST.json") |> File.read!() |> Jason.decode!()

    assert manifest["recorded_at"] == Date.to_iso8601(Date.utc_today())

    for entry <- manifest["files"] do
      path = Path.join(dir, entry["file"])
      assert File.exists?(path), "manifest names #{entry["file"]}, which is not there"
      assert entry["sha256"] == DevilsDictionary.Sources.Manifest.digest(path)
      assert entry["byte_count"] == File.stat!(path).size
    end

    bierce = Enum.find(manifest["files"], &(&1["source"] == "bierce"))
    assert bierce["rows"] == 1
  end

  test "a source with no records still produces a verifiable empty file", %{dir: dir} do
    # A rebuild reads the manifest to decide what it can replay. A silently
    # absent file would read as "nothing to replay" exactly like a source that
    # genuinely has nothing, and those are different situations.
    export(dir, ["--source", "wordnet"])

    assert read_lines(dir, "wordnet") == []

    manifest = dir |> Path.join("MANIFEST.json") |> File.read!() |> Jason.decode!()
    entry = Enum.find(manifest["files"], &(&1["source"] == "wordnet"))
    assert entry["rows"] == 0

    assert entry["sha256"] ==
             DevilsDictionary.Sources.Manifest.digest(Path.join(dir, entry["file"]))
  end

  test "more records than one batch are all written", %{dir: dir} do
    # The export is keyset-paginated at 2,000. Anything that only ever tested a
    # handful would not exercise the unfold's continuation at all.
    source = Sources.get_source_by_slug!("johnson")

    for n <- 1..25 do
      {:ok, _} = Sources.upsert_record(source, %{external_id: "W#{n}/n. s./0", raw: %{"n" => n}})
    end

    export(dir, ["--source", "johnson"])

    lines = read_lines(dir, "johnson")
    assert length(lines) == 25
    assert lines |> Enum.map(& &1["raw"]["n"]) |> Enum.sort() == Enum.to_list(1..25)
  end
end
