defmodule Mix.Tasks.Dd.Export.Replay do
  @shortdoc "Export database-only source records to a checksummed replay archive"

  @moduledoc """
  Writes every `source_records` row, payload included, to a checksummed JSONL
  archive under `priv/replay/`.

      mix dd.export.replay
      mix dd.export.replay --source wikipedia
      mix dd.export.replay --out priv/replay

  ## Why this exists

  #74 requires independently recoverable source inputs before a rebuild, and
  four of the six sources have them: WordNet and Wiktionary have their dumps,
  Bierce and Johnson are checked in, and all four are pinned in
  `priv/sources/MANIFEST.json`.

  The two API sources have nothing. Wikipedia's 85,044 records and Wikidata's
  72,770 exist **only** inside the database — they were assembled over roughly
  three hours of batched API calls, and re-fetching them is neither free nor
  guaranteed to return the same bytes, because the upstream articles move.

  So this archive is the API sources' equivalent of a pinned dump: with it, a
  rebuild replays them offline; without it, a rebuild re-fetches and gets
  whatever Wikipedia says today, which is a different corpus and would make
  every measured number incomparable.

  ## Format

  One `<slug>.jsonl.gz` per source, one JSON object per line, plus a
  `MANIFEST.json` recording each file's row count, byte count and SHA-256. The
  digest is what makes it a replay archive rather than a folder of files:
  `mix dd.manifest` cannot verify what it cannot checksum.

  Payloads are read in keyset-paginated batches, because `raw` is
  `load_in_query: false` and the whole set is roughly 660 MB.

  Options:

    * `--source` — restrict to one source slug (default: all)
    * `--out` — output directory (default `priv/replay`)
    * `--quiet` — suppress progress output. A flag rather than
      `Mix.shell(Mix.Shell.Quiet)` because that is process-global state and the
      tests around this run `async: true`.
  """

  use Mix.Task

  import Ecto.Query
  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.Manifest
  alias DevilsDictionary.Sources.SourceRecord

  @requirements ["app.start"]
  @batch 2_000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [source: :string, out: :string, quiet: :boolean])

    quiet? = opts[:quiet] || false
    out = opts[:out] || "priv/replay"
    File.mkdir_p!(out)

    sources =
      case opts[:source] do
        nil -> Sources.list_sources()
        slug -> [Sources.get_source_by_slug!(slug)]
      end

    tell(quiet?, fn ->
      say("exporting to #{out}/…")
      say("")
    end)

    entries = Enum.map(sources, &export(&1, out, quiet?))

    write_manifest(entries, out)

    tell(quiet?, fn ->
      say("")
      row("total records", entries |> Enum.map(& &1.rows) |> Enum.sum())
      say("  #{out}/MANIFEST.json written")
    end)
  end

  defp tell(true, _fun), do: :ok
  defp tell(false, fun), do: fun.()

  defp export(source, out, quiet?) do
    path = Path.join(out, "#{source.slug}.jsonl.gz")
    z = :zlib.open()
    :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
    file = File.open!(path, [:write, :binary])

    rows = stream_records(source.id, file, z)

    tail = :zlib.deflate(z, "", :finish)
    IO.binwrite(file, tail)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    File.close(file)

    bytes = File.stat!(path).size
    tell(quiet?, fn -> row(source.slug, "#{fmt(rows)} records · #{fmt(bytes)} bytes") end)

    %{
      source: source.slug,
      file: Path.basename(path),
      rows: rows,
      byte_count: bytes,
      sha256: Manifest.digest(path)
    }
  end

  # Keyset pagination rather than Repo.stream/2: a stream needs an enclosing
  # transaction, and holding one open across a 660 MB export is a long-lived
  # snapshot for no benefit. Same reasoning as `Absorb.Batch.stream/2`.
  defp stream_records(source_id, file, z) do
    Stream.unfold(0, fn
      :done ->
        nil

      after_id ->
        records =
          SourceRecord
          |> where([r], r.source_id == ^source_id and r.id > ^after_id)
          |> order_by([r], asc: r.id)
          |> limit(^@batch)
          |> select([r], %{
            id: r.id,
            external_id: r.external_id,
            url: r.url,
            content_hash: r.content_hash,
            fetched_at: r.fetched_at,
            changed_at: r.changed_at,
            absent_until: r.absent_until,
            raw: r.raw
          })
          |> Repo.all()

        case records do
          [] -> nil
          rows -> {rows, if(length(rows) < @batch, do: :done, else: List.last(rows).id)}
        end
    end)
    |> Enum.reduce(0, fn batch, count ->
      chunk = Enum.map_join(batch, "", &(Jason.encode!(&1) <> "\n"))
      IO.binwrite(file, :zlib.deflate(z, chunk))
      count + length(batch)
    end)
  end

  defp write_manifest(entries, out) do
    payload = %{
      "recorded_at" => Date.utc_today() |> Date.to_iso8601(),
      "note" =>
        "Replay archive of source_records. The API sources (wikipedia, wikidata) exist " <>
          "only here outside the database; the dump sources are re-derivable from " <>
          "priv/sources/MANIFEST.json and are exported for convenience, not necessity.",
      "files" => entries
    }

    File.write!(Path.join(out, "MANIFEST.json"), Jason.encode_to_iodata!(payload, pretty: true))
  end
end
