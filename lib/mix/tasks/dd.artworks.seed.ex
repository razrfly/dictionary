defmodule Mix.Tasks.Dd.Artworks.Seed do
  @shortdoc "Seeds a committed corpus manifest, or builds the Artsy pilot's Wikidata half"

  @moduledoc """
  Seeds the committed **corpus** manifests built by `mix dd.artworks.manifest`
  — `met-highlights`, `wikidata-famous`, `poetrydb` — which are recognised by
  their contents rather than by a flag:

      mix dd.artworks.seed --manifest priv/artworks/manifests/met-highlights-v1.json
      mix dd.artworks.seed --manifest priv/artworks/manifests/wikidata-famous-v1.json --dry-run

  A corpus manifest is the whole input: nothing is searched, fetched or resumed,
  and rerunning it matches every row on its exact identifier, so the counts come
  back identical.

  It also still builds and backfills the Artsy pilot's Wikidata half — the part
  that never needed Artsy:

      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json \
        --wikidata-only --refresh-wikidata --wikidata-request-limit 2

  `--build` makes bounded Wikidata discovery calls for exact P11005 identifiers
  and writes the checksummed base manifest. `--wikidata-only` hydrates the
  manifest's already-local artwork and creator QIDs through the shared bounded
  Wikidata adapter and installs the meaning mappings.

  **The Artsy import stage is retired** (#109 Phase 3a, with the private Artsy
  client). Running this task on an Artsy import manifest without `--build` or
  `--wikidata-only` is refused with that explanation: the 43 pilot works are
  already catalog rows, and there is no client left to enrich them with.
  """

  use Mix.Task

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Artworks.Corpus
  alias DevilsDictionary.Artworks.{Manifest, WikidataCandidates}

  @switches [
    manifest: :string,
    build: :boolean,
    wikidata_only: :boolean,
    dry_run: :boolean,
    local_only: :boolean,
    candidate_limit: :integer,
    discovery_request_limit: :integer,
    record_limit: :integer,
    offset: :integer,
    refresh_wikidata: :boolean,
    refresh: :boolean,
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
      Corpus.Seeder.run(manifest,
        dry_run: opts[:dry_run] || false,
        limit: opts[:record_limit],
        refresh: opts[:refresh] || false
      )

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
      opts[:build] == true and opts[:wikidata_only] != true ->
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
        Mix.raise(
          "#{path} is an Artsy import manifest, and the Artsy import stage was retired " <>
            "with the private Artsy client in #109 Phase 3a. The pilot's 43 works are " <>
            "already catalog rows. Pass --build to rediscover the manifest's Wikidata " <>
            "candidates, or --wikidata-only to backfill their Wikidata records."
        )
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

  defp hydrate_wikidata(manifest, opts, hydrate_opts) do
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
