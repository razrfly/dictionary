defmodule Mix.Tasks.Dd.Artworks.Seed do
  @shortdoc "Builds or runs a bounded Wikidata/Artsy artwork seed manifest"

  @moduledoc """
  Builds a credential-free, checksummed manifest from exact Wikidata P11005
  identifiers, or imports an existing manifest through the shared source
  identity resolver.

      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build --import --dry-run
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json \
        --wikidata-only --refresh-wikidata --wikidata-request-limit 2
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json \
        --record-limit 50 --request-limit 160 \
        --wikidata-entity-limit 100 --wikidata-request-limit 4 --resume

  `--build` always makes bounded Wikidata discovery calls and writes the base
  manifest. `--dry-run` applies only to the import stage and never writes the
  database; add `--import` to build and dry-run the import in one command.
  Imports hydrate selected artwork and creator QIDs through the existing bounded
  Wikidata adapter before optional Artsy enrichment. Use
  `--wikidata-only --refresh-wikidata` for a safe, repeatable rich-data backfill
  of existing identities without spending Artsy requests. Use
  `--skip-wikidata-hydration` only when that stage is already complete, and
  `--refresh-wikidata` when current Wikidata records must be refreshed.

  It also seeds the committed **corpus** manifests built by
  `mix dd.artworks.manifest` — `met-highlights` and `wikidata-famous` — which are
  recognised by their contents rather than by a flag:

      mix dd.artworks.seed --manifest priv/artworks/manifests/met-highlights-v1.json
      mix dd.artworks.seed --manifest priv/artworks/manifests/wikidata-famous-v1.json --dry-run

  A corpus manifest is the whole input: nothing is searched, fetched or resumed,
  and rerunning it matches every row on its exact identifier, so the counts come
  back identical.

  All discovery and provider calls are bounded. Import progress is written to
  an ignored, environment-local `MANIFEST.checkpoint.json` (or `--checkpoint`),
  so `--resume` continues partial records without mutating the portable base
  manifest or replaying completed pages. Reruns converge on exact Wikidata,
  P11005/P2042 and opaque Artsy identifiers; titles never identify.
  """

  use Mix.Task

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus
  alias DevilsDictionary.Artworks.{Manifest, Seeder, WikidataCandidates}

  @switches [
    manifest: :string,
    checkpoint: :string,
    build: :boolean,
    import: :boolean,
    wikidata_only: :boolean,
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

    if Corpus.Manifest.corpus_manifest?(path) do
      seed_corpus(path, opts)
    else
      seed_artsy_pilot(path, opts)
    end
  end

  # A committed corpus manifest (`met-highlights`, `wikidata-famous`) is the
  # whole input: the seeder reads it from disk, resolves each row on its exact
  # identifier and makes no provider call at all. None of the Artsy pilot's
  # build, checkpoint, resume or hydration stages apply, because there is
  # nothing to fetch and nothing partial to resume.
  defp seed_corpus(path, opts) do
    if opts[:build],
      do: Mix.raise("--build does not apply to a corpus manifest; use mix dd.artworks.manifest")

    manifest = Corpus.Manifest.load!(path)

    {:ok, summary} =
      Corpus.Seeder.run(manifest, dry_run: opts[:dry_run] || false, limit: opts[:record_limit])

    Mix.shell().info(
      "Corpus manifest #{path}: #{manifest["row_count"]} rows, checksum #{manifest["checksum"]}"
    )

    Mix.shell().info("Corpus seed summary: " <> inspect(summary, pretty: true))

    Mix.shell().info(
      "Artwork catalog by source: " <> inspect(Corpus.Seeder.catalog_counts(), pretty: true)
    )
  rescue
    error in [ArgumentError, File.Error, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  defp seed_artsy_pilot(path, opts) do
    base_manifest = if opts[:build], do: build(path, opts), else: Manifest.load!(path)

    cond do
      opts[:build] == true and opts[:import] != true and opts[:wikidata_only] != true ->
        print_manifest(base_manifest, path)

      opts[:wikidata_only] == true ->
        if opts[:dry_run], do: Mix.raise("--wikidata-only cannot be combined with --dry-run")

        wikidata_stats = hydrate_wikidata(base_manifest, opts, existing_only: true)
        mapping_stats = Artworks.install_meaning_mappings!()
        print_manifest(base_manifest, path)
        Mix.shell().info("Wikidata backfill summary: " <> inspect(wikidata_stats, pretty: true))

        Mix.shell().info(
          "Selected catalog coverage: " <> inspect(coverage(base_manifest), pretty: true)
        )

        Mix.shell().info("Meaning mapping summary: " <> inspect(mapping_stats, pretty: true))

      true ->
        checkpoint_path = Path.expand(opts[:checkpoint] || path <> ".checkpoint.json")

        manifest =
          if opts[:resume] && File.exists?(checkpoint_path),
            do: resumed_manifest!(checkpoint_path, base_manifest, path),
            else: base_manifest

        wikidata_stats =
          if opts[:dry_run] || opts[:skip_wikidata_hydration] do
            %{
              skipped: true,
              reason: if(opts[:dry_run], do: "dry_run", else: "operator_requested")
            }
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

        Mix.shell().info(
          "Selected catalog coverage: " <> inspect(coverage(manifest), pretty: true)
        )

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

  # Resuming a checkpoint that belongs to a different manifest would silently
  # import the wrong candidate set. `--build --resume` makes that easy: the base
  # manifest is rediscovered while a stale checkpoint still wins.
  defp resumed_manifest!(checkpoint_path, base_manifest, path) do
    checkpoint = Manifest.load!(checkpoint_path)

    unless Manifest.same_selection?(checkpoint, base_manifest) do
      Mix.raise(
        "checkpoint #{checkpoint_path} does not match the manifest #{path}. " <>
          "Its exact identities differ, so resuming it would import a different " <>
          "candidate set. Pass --checkpoint for the matching checkpoint, or rerun " <>
          "without --resume."
      )
    end

    checkpoint
  end

  defp hydrate_wikidata(manifest, opts, hydrate_opts \\ []) do
    existing_only? = hydrate_opts[:existing_only] || false

    # The rule is "hydrate identities that already exist locally". Applying it
    # per candidate instead of per QID dropped creators who do exist locally
    # merely because one of their artworks does not.
    qids =
      manifest["candidates"]
      |> Enum.flat_map(fn candidate ->
        [candidate["qid"] | Enum.map(candidate["creators"] || [], & &1["qid"])]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.filter(fn qid ->
        not existing_only? or
          not is_nil(DevilsDictionary.Registry.by_external_id("wikidata", qid))
      end)

    if qids == [] do
      %{skipped: true, reason: "no_matching_local_identities", requests: 0, records: 0}
    else
      entity_limit = opts[:wikidata_entity_limit] || length(qids)
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

  defp coverage(manifest) do
    artworks =
      manifest["candidates"]
      |> Enum.map(&DevilsDictionary.Registry.by_external_id("wikidata", &1["qid"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&Artworks.get/1)
      |> Enum.reject(&is_nil/1)

    %{
      candidates: length(manifest["candidates"]),
      local_identities: length(artworks),
      images: Enum.count(artworks, &is_binary(&1.image_url)),
      commons_images:
        Enum.count(artworks, &(&1.image_url && String.contains?(&1.image_url, "wikimedia"))),
      artsy_thumbnail_fallbacks:
        Enum.count(
          artworks,
          &(&1.artsy && &1.image_url == &1.artsy["thumbnail_url"] && is_binary(&1.image_url))
        ),
      visible_creator_links:
        artworks
        |> Enum.flat_map(fn artwork ->
          Enum.map(artwork.creators, &{artwork.object_id, &1.object_id})
        end)
        |> Enum.uniq()
        |> length(),
      unavailable_records:
        Enum.count(manifest["candidates"], fn candidate ->
          get_in(candidate, ["import", "status"]) == "unavailable"
        end)
    }
  end
end
