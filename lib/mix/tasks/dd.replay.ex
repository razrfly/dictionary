defmodule Mix.Tasks.Dd.Replay do
  @shortdoc "Load a checksummed replay archive back into source_records"

  @moduledoc """
  The other half of `mix dd.export.replay`, and the reason that task exists.

      mix dd.replay --source wikipedia
      mix dd.replay                      # every archive in priv/replay/

  ## Why this is not a convenience

  Wikipedia's 85,044 records and Wikidata's 72,770 exist **only** in a database.
  They are not a dump anyone can re-download: they are roughly three hours of
  batched API calls against endpoints whose answers change. #74 requires
  *"independently recoverable source inputs"* and says a reset without them
  fails the rebuild contract — so for those two sources the checksummed archive
  **is** the pinned input, exactly as `raw-wiktextract-data.jsonl.gz` is
  Wiktionary's.

  So it verifies before it reads. `priv/replay/MANIFEST.json` records each
  archive's SHA-256 and row count, and a mismatch stops the load rather than
  importing bytes nobody pinned.

  ## What it writes

  `source_records` and their revisions, and nothing else — the same rows the
  fetch wrote, with `fetched_at`, `changed_at` and `absent_until` preserved, so
  an absent marker stays absent and does not read as a page nobody asked about.
  Materialization is a separate pass, because the archive is *input*: replaying
  it and then materializing is the same path a fresh fetch takes, which is what
  makes the rebuild comparable to the original.

  ## Why it materializes more than once

  Because a fresh fetch does. An edge names a synset, or a parent taxon, that a
  *later* record introduces, so a single pass over the archive closes the graph
  only as far as the records happened to be ordered — Wikidata's own `absorb/2`
  loops its materialize for exactly this reason. A replay that did not would
  hand back a corpus with a truncated taxonomy and call it a rebuild.

  So it re-materializes while the open edges are still falling, capped at five
  passes, and what is left is reported rather than swallowed: an edge that
  genuinely names something nobody fetched should be visible.
  """

  use Mix.Task

  import Ecto.Query
  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Absorb.{Batch, GzipLines}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.Manifest

  @requirements ["app.start"]
  @batch 2_000
  @dir "priv/replay"
  @max_passes 5

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source: :string, dir: :string, quiet: :boolean, skip_verify: :boolean]
      )

    dir = opts[:dir] || @dir
    quiet? = opts[:quiet] || false

    entries =
      dir
      |> manifest()
      |> Enum.filter(&(is_nil(opts[:source]) or &1["source"] == opts[:source]))

    if entries == [] do
      Mix.raise("no replay archive for #{opts[:source] || "any source"} in #{dir}")
    end

    tell(quiet?, fn ->
      say("replaying from #{dir}/")
      say("")
    end)

    results = Enum.map(entries, &replay(&1, dir, opts, quiet?))

    tell(quiet?, fn ->
      say("")
      row("total records", results |> Enum.map(& &1.records) |> Enum.sum())
      row("materialized", results |> Enum.map(& &1.materialized) |> Enum.sum())
    end)
  end

  defp manifest(dir) do
    path = Path.join(dir, "MANIFEST.json")

    unless File.exists?(path) do
      Mix.raise("""
      no #{path}.

      A replay archive without its manifest is bytes nobody pinned. `mix
      dd.export.replay` writes both.
      """)
    end

    path |> File.read!() |> Jason.decode!() |> Map.fetch!("files")
  end

  defp replay(entry, dir, opts, quiet?) do
    path = Path.join(dir, entry["file"])
    source = Sources.get_source_by_slug!(entry["source"])

    verify!(path, entry, opts[:skip_verify])

    run = Sources.start_run("replay", source_id: source.id)

    records =
      path
      |> GzipLines.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Stream.chunk_every(@batch)
      |> Enum.reduce(0, fn chunk, acc ->
        rows =
          Enum.map(chunk, fn row ->
            %{
              external_id: row["external_id"],
              url: row["url"],
              raw: row["raw"] || %{},
              content_hash: row["content_hash"],
              fetched_at: parse_time(row["fetched_at"]),
              absent_until: parse_time(row["absent_until"])
            }
          end)

        Sources.insert_records(source, rows, @batch)
        acc + length(rows)
      end)

    # The same materialize passes a fresh fetch takes. The archive is input;
    # what it becomes is derived here, not carried over.
    materialized =
      materialize(DevilsDictionary.Absorb.source_module!(source.slug), source, run.id)

    Sources.finish_run(run, %{"records" => records, "replayed_from" => entry["file"]})

    tell(quiet?, fn ->
      row(source.slug, "#{records} records replayed")
    end)

    %{source: source.slug, records: records, materialized: Map.get(materialized, :senses, 0)}
  end

  # One pass, then more while the open edges are still falling. Both kinds
  # count: an edge held in `pending_relations` because its target is not there
  # yet, and a taxonomy parent the walk skipped. A source with neither stops
  # after the first pass and pays nothing.
  defp materialize(module, source, run_id) do
    first = Batch.run(module, source, run_id: run_id)
    close(module, source, run_id, Map.put(first, :passes, 1))
  end

  defp close(module, source, run_id, previous) do
    open = open_edges(previous, source)

    if open == 0 or previous.passes >= @max_passes do
      previous
    else
      counts =
        module
        |> Batch.run(source, only_stale: false, run_id: run_id)
        |> Map.put(:passes, previous.passes + 1)

      # "No better than last time" is a closed walk or a stuck one, and either
      # way another pass is wasted work.
      if open_edges(counts, source) >= open,
        do: counts,
        else: close(module, source, run_id, counts)
    end
  end

  defp open_edges(counts, source) do
    Map.get(counts, :concept_relations_skipped_parent_taxon, 0) + pending_for(source)
  end

  defp pending_for(source) do
    Repo.aggregate(from(p in "pending_relations", where: p.source_id == ^source.id), :count)
  end

  defp verify!(path, entry, skip?) do
    unless File.exists?(path) do
      Mix.raise("#{path} is missing. It is a required recovery input, not a convenience.")
    end

    cond do
      skip? ->
        :ok

      Manifest.digest(path) == entry["sha256"] ->
        :ok

      true ->
        Mix.raise("""
        #{path} does not match its manifest.

          expected #{entry["sha256"]}
          read     #{Manifest.digest(path)}

        Stopping rather than importing bytes nobody pinned.
        """)
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp tell(true, _fun), do: :ok
  defp tell(false, fun), do: fun.()
end
