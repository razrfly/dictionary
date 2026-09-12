defmodule Mix.Tasks.Dd.Artworks.Seed do
  @shortdoc "Builds or runs a bounded Wikidata/Artsy artwork seed manifest"

  @moduledoc """
  Builds a credential-free, checksummed manifest from exact Wikidata P11005
  identifiers, or imports an existing manifest through the shared source
  identity resolver.

      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build --import --dry-run
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json \
        --record-limit 50 --request-limit 160 \
        --wikidata-entity-limit 100 --wikidata-request-limit 4 --resume

  `--build` always makes bounded Wikidata discovery calls and writes the base
  manifest. `--dry-run` applies only to the import stage and never writes the
  database; add `--import` to build and dry-run the import in one command.
  Imports hydrate selected artwork and creator QIDs through the existing bounded
  Wikidata adapter before optional Artsy enrichment. Use
  `--skip-wikidata-hydration` only when that stage is already complete, and
  `--refresh-wikidata` when current Wikidata records must be refreshed.

  All discovery and provider calls are bounded. Import progress is written to
  an ignored, environment-local `MANIFEST.checkpoint.json` (or `--checkpoint`),
  so `--resume` continues partial records without mutating the portable base
  manifest or replaying completed pages. Reruns converge on exact Wikidata,
  P11005/P2042 and opaque Artsy identifiers; titles never identify.
  """

  use Mix.Task

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.{Manifest, Seeder, WikidataCandidates}

  @switches [
    manifest: :string,
    checkpoint: :string,
    build: :boolean,
    import: :boolean,
    dry_run: :boolean,
    resume: :boolean,
    local_only: :boolean,
    candidate_limit: :integer,
    request_limit: :integer,
    discovery_request_limit: :integer,
    record_limit: :integer,
    batch_size: :integer,
    offset: :integer,
    skip_wikidata_hydration: :boolean,
    refresh_wikidata: :boolean,
    wikidata_request_limit: :integer,
    wikidata_entity_limit: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] or is_nil(opts[:manifest]) do
      Mix.raise("invalid arguments; --manifest is required (run `mix help dd.artworks.seed`)")
    end

    path = Path.expand(opts[:manifest])
    base_manifest = if opts[:build], do: build(path, opts), else: Manifest.load!(path)

    if opts[:build] == true and opts[:import] != true do
      print_manifest(base_manifest, path)
    else
      checkpoint_path = Path.expand(opts[:checkpoint] || path <> ".checkpoint.json")

      manifest =
        if opts[:resume] && File.exists?(checkpoint_path),
          do: Manifest.load!(checkpoint_path),
          else: base_manifest

      wikidata_stats =
        if opts[:dry_run] || opts[:skip_wikidata_hydration] do
          %{skipped: true, reason: if(opts[:dry_run], do: "dry_run", else: "operator_requested")}
        else
          hydrate_wikidata(manifest, opts)
        end

      {manifest, summary} =
        Seeder.run(manifest,
          dry_run: opts[:dry_run] || false,
          resume: opts[:resume] || false,
          manifest_path: if(opts[:dry_run], do: nil, else: checkpoint_path),
          request_limit: opts[:request_limit] || 500,
          record_limit: opts[:record_limit] || 500,
          batch_size: opts[:batch_size] || 25
        )

      mapping_stats =
        if opts[:dry_run], do: %{skipped: "dry_run"}, else: Artworks.install_meaning_mappings!()

      print_manifest(manifest, if(opts[:dry_run], do: path, else: checkpoint_path))
      Mix.shell().info("Portable base manifest unchanged: " <> path)
      Mix.shell().info("Wikidata hydration summary: " <> inspect(wikidata_stats, pretty: true))
      Mix.shell().info("Artwork seed summary: " <> inspect(summary, pretty: true))
      Mix.shell().info("Meaning mapping summary: " <> inspect(mapping_stats, pretty: true))
    end
  rescue
    error in [ArgumentError, File.Error, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  defp build(path, opts) do
    {:ok, candidates, stats} =
      WikidataCandidates.discover(
        limit: opts[:candidate_limit] || 50,
        request_limit: opts[:discovery_request_limit] || 10,
        offset: opts[:offset] || 0,
        remote: not (opts[:local_only] || false)
      )

    if stats[:error], do: Mix.raise("Wikidata discovery failed: #{stats.error}")

    if stats[:truncated] do
      Mix.shell().info(
        "Wikidata discovery reached a configured bound; next offset: #{stats.next_offset}"
      )
    end

    manifest =
      Manifest.new(candidates, %{
        "discovery" => stats,
        "source" => "Wikidata P11005/P2042",
        "selection_reason" => "painting with exact Artsy artwork identifier"
      })

    Manifest.save!(manifest, path)
  end

  defp print_manifest(manifest, path) do
    Mix.shell().info(
      "Artwork manifest #{path}: #{length(manifest["candidates"])} candidates, checksum #{manifest["checksum"]}"
    )
  end

  defp hydrate_wikidata(manifest, opts) do
    qids =
      manifest["candidates"]
      |> Enum.flat_map(fn candidate ->
        [candidate["qid"] | Enum.map(candidate["creators"] || [], & &1["qid"])]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    entity_limit = opts[:wikidata_entity_limit] || max(length(qids), 1)
    request_limit = opts[:wikidata_request_limit] || max(div(length(qids) + 49, 50), 1)

    {:ok, stats} =
      DevilsDictionary.Absorb.Sources.Wikidata.absorb(nil,
        qids: Enum.take(qids, entity_limit),
        entity_budget: entity_limit,
        request_budget: request_limit,
        related_depth: 1,
        refresh: opts[:refresh_wikidata] || false
      )

    stats
  end
end
