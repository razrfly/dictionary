defmodule Mix.Tasks.Dd.Artworks.Seed do
  @shortdoc "Builds or runs a bounded Wikidata/Artsy artwork seed manifest"

  @moduledoc """
  Builds a credential-free, checksummed manifest from exact Wikidata P11005
  identifiers, or imports an existing manifest through the shared source
  identity resolver.

      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --build --dry-run
      mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json --resume

  `--dry-run` never writes the database. `--build` discovers candidates and
  writes only the manifest; add `--import` to build and import in one command.
  All discovery and provider calls are bounded. Reruns converge on exact
  Wikidata, P11005/P2042 and opaque Artsy identifiers; titles never identify.
  """

  use Mix.Task

  alias DevilsDictionary.Artworks.{Manifest, Seeder, WikidataCandidates}

  @switches [
    manifest: :string,
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
    offset: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] or is_nil(opts[:manifest]) do
      Mix.raise("invalid arguments; --manifest is required (run `mix help dd.artworks.seed`)")
    end

    path = Path.expand(opts[:manifest])
    manifest = if opts[:build], do: build(path, opts), else: Manifest.load!(path)

    if opts[:build] == true and opts[:import] != true do
      print_manifest(manifest, path)
    else
      {manifest, summary} =
        Seeder.run(manifest,
          dry_run: opts[:dry_run] || false,
          resume: opts[:resume] || false,
          manifest_path: if(opts[:dry_run], do: nil, else: path),
          request_limit: opts[:request_limit] || 500,
          record_limit: opts[:record_limit] || 500,
          batch_size: opts[:batch_size] || 25
        )

      print_manifest(manifest, path)
      Mix.shell().info("Artwork seed summary: " <> inspect(summary, pretty: true))
    end
  rescue
    error in [ArgumentError, File.Error] -> Mix.raise(Exception.message(error))
  end

  defp build(path, opts) do
    {:ok, candidates, stats} =
      WikidataCandidates.discover(
        limit: opts[:candidate_limit] || 50,
        request_limit: opts[:discovery_request_limit] || 10,
        offset: opts[:offset] || 0,
        remote: not (opts[:local_only] || false)
      )

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
end
