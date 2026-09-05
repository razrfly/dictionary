defmodule Mix.Tasks.Dd.Fixtures.Capture do
  @shortdoc "Capture real source records as test fixtures"

  @moduledoc """
  Writes real raw records for a few lemmas into `test/support/fixtures`, so the
  test suite runs against what the sources actually emit rather than against
  something hand-written, and runs with no network (scorecard O3).

      mix dd.fixtures.capture
      mix dd.fixtures.capture --source wiktionary --lemma cat --force

  Wiktionary fixtures are stored **untrimmed** on purpose: scorecard M4 measures
  trimmed size against untrimmed, so checking in the trimmed record would
  destroy the denominator. The test applies `trim/1` itself.

  Refuses to overwrite without `--force`, so a green suite can never be quietly
  re-baselined against new data.

  Options:

    * `--source` — `wordnet` or `wiktionary` (default: both)
    * `--lemma` — repeatable (default: cat, dog, oyster)
    * `--force` — overwrite existing fixtures
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.Absorb.GzipLines
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @default_lemmas ~w(cat dog oyster)
  @dir "test/support/fixtures"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [source: :string, lemma: :keep, force: :boolean])

    lemmas =
      case Keyword.get_values(opts, :lemma) do
        [] -> @default_lemmas
        given -> given
      end

    sources =
      case opts[:source] do
        nil -> ~w(wordnet wiktionary)
        one -> [one]
      end

    captured =
      Enum.flat_map(sources, fn
        "wordnet" -> capture_wordnet(lemmas, opts)
        "wiktionary" -> capture_wiktionary(lemmas, opts)
      end)

    write_manifest(captured)
    Mix.shell().info("\ncaptured #{length(captured)} fixtures")
  end

  # WordNet fixtures come from source_records, which already hold exactly the
  # `raw` contract materialize/1 consumes: normalized ids plus the expanded
  # `_edges` the absorb inverted.
  defp capture_wordnet(lemmas, opts) do
    source = Sources.get_source_by_slug!("wordnet")

    Enum.flat_map(lemmas, fn lemma ->
      records =
        Repo.all(
          from r in SourceRecord,
            where: r.source_id == ^source.id,
            # jsonb_exists/2 rather than the `?` operator: `?` is Ecto's
            # fragment placeholder and cannot be escaped.
            where: fragment("jsonb_exists(? -> 'members', ?)", r.raw, ^lemma),
            order_by: r.external_id,
            select: r.raw
        )

      write("wordnet", lemma, records, opts)
    end)
  end

  defp capture_wiktionary(lemmas, opts) do
    source = Sources.get_source_by_slug!("wiktionary")
    path = source.config["dump_file"]
    wanted = MapSet.new(lemmas)

    Mix.shell().info("streaming #{path} for #{Enum.join(lemmas, ", ")} (one full pass)…")

    found =
      path
      |> GzipLines.stream!()
      |> Stream.filter(&(:binary.match(&1, ~S("lang_code": "en")) != :nomatch))
      |> Stream.map(&Jason.decode!(&1, strings: :copy))
      |> Stream.filter(fn record ->
        record["lang_code"] == "en" and MapSet.member?(wanted, record["word"])
      end)
      |> Enum.group_by(& &1["word"])

    Enum.flat_map(lemmas, fn lemma ->
      write("wiktionary", lemma, Map.get(found, lemma, []), opts)
    end)
  end

  defp write(_source, lemma, [], _opts) do
    Mix.shell().error("  ! no records for #{lemma}")
    []
  end

  defp write(source, lemma, records, opts) do
    path = Path.join([@dir, source, "#{lemma}.json"])

    if File.exists?(path) and not opts[:force] do
      Mix.shell().info("  = #{path} (exists; --force to replace)")
      []
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode_to_iodata!(%{"records" => records}, pretty: true))
      size = File.stat!(path).size
      Mix.shell().info("  + #{path} — #{length(records)} records, #{div(size, 1024)} KB")
      [%{"source" => source, "lemma" => lemma, "records" => length(records), "bytes" => size}]
    end
  end

  defp write_manifest([]), do: :ok

  defp write_manifest(captured) do
    sources =
      Sources.list_sources()
      |> Enum.filter(&(&1.slug in ["wordnet", "wiktionary"]))
      |> Map.new(&{&1.slug, Map.take(&1.config, ~w(dump_url edition snapshot_date dump_date))})

    manifest = %{
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "sources" => sources,
      "fixtures" => captured
    }

    path = Path.join(@dir, "MANIFEST.json")
    File.write!(path, Jason.encode_to_iodata!(manifest, pretty: true))
    Mix.shell().info("  + #{path}")
  end
end
