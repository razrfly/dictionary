defmodule Mix.Tasks.Dd.Artworks.Manifest do
  @shortdoc "Builds a committed artwork corpus manifest from the Met or Wikidata"

  @moduledoc """
  Builds one of the committed corpus manifests the artwork seeder reads.

      mix dd.artworks.manifest met-highlights
      mix dd.artworks.manifest met-highlights --request-limit 3000 --id-limit 50
      mix dd.artworks.manifest met-highlights --from-cache
      mix dd.artworks.manifest wikidata-famous --measure
      mix dd.artworks.manifest wikidata-famous --min-sitelinks 20

  The output lands in `priv/artworks/manifests/<kind>-v1.json` unless `--output`
  says otherwise, and is meant to be committed: the seeder reads the file and
  never searches live, because the Met's search totals are parameter-sensitive
  and a re-queried corpus is a different corpus.

  `--measure` (Wikidata only) reports the paged sitelink distribution and writes
  nothing. Whole-graph sitelink counts time out on the query service, so the
  threshold is measured by paging before it is chosen.

  Every request is bounded and counted; the printed ledger is what goes in the
  session's `docs/integrations/` ledger. No image bytes are ever downloaded.
  """

  use Mix.Task

  alias DevilsDictionary.Artworks.Corpus.{Manifest, MetHighlights, WikidataFamous}

  @switches [
    output: :string,
    request_limit: :integer,
    interval_ms: :integer,
    progress: :string,
    id_limit: :integer,
    max_attempts: :integer,
    from_cache: :boolean,
    min_sitelinks: :integer,
    measure: :boolean,
    page_size: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    kind =
      case {rest, invalid} do
        {[kind], []} -> kind
        _ -> Mix.raise("usage: mix dd.artworks.manifest <#{Enum.join(Manifest.kinds(), "|")}>")
      end

    unless kind in Manifest.kinds() do
      Mix.raise("unknown manifest kind #{kind}; known: #{Enum.join(Manifest.kinds(), ", ")}")
    end

    build(kind, opts)
  end

  defp build("met-highlights", opts) do
    case MetHighlights.build(
           request_limit: opts[:request_limit],
           interval_ms: opts[:interval_ms],
           progress: opts[:progress],
           id_limit: opts[:id_limit],
           max_attempts: opts[:max_attempts],
           from_cache: opts[:from_cache]
         ) do
      {:ok, manifest, ledger} -> write(manifest, ledger, opts, "met-highlights")
      {:error, reason} -> Mix.raise("met highlights manifest failed: #{reason}")
    end
  end

  defp build("wikidata-famous", opts) do
    if opts[:measure] do
      case WikidataFamous.measure(
             page_size: opts[:page_size],
             request_limit: opts[:request_limit]
           ) do
        {:ok, measurement} ->
          Mix.shell().info("Sitelink threshold measurement (paged; nothing written):")
          Mix.shell().info(inspect(measurement, pretty: true, limit: :infinity))

        {:error, reason} ->
          Mix.raise("sitelink measurement failed: #{reason}")
      end
    else
      case WikidataFamous.build(
             min_sitelinks: opts[:min_sitelinks],
             request_limit: opts[:request_limit],
             page_size: opts[:page_size]
           ) do
        {:ok, manifest, ledger} -> write(manifest, ledger, opts, "wikidata-famous")
        {:error, reason} -> Mix.raise("wikidata famous manifest failed: #{reason}")
      end
    end
  end

  defp write(manifest, ledger, opts, kind) do
    path = opts[:output] || Path.join("priv/artworks/manifests", "#{kind}-v1.json")
    Manifest.save!(manifest, path)

    Mix.shell().info(
      "Wrote #{path}: #{manifest["row_count"]} rows, checksum #{manifest["checksum"]}"
    )

    Mix.shell().info("Ledger: " <> inspect(ledger, pretty: true, limit: :infinity))
  end
end
