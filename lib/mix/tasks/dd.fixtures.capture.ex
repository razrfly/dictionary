defmodule Mix.Tasks.Dd.Fixtures.Capture do
  @shortdoc "Capture real source records as test fixtures"

  @moduledoc """
  Writes real raw records for a few lemmas into `test/support/fixtures`, so the
  test suite runs against what the sources actually emit rather than against
  something hand-written, and runs with no network (scorecard O3).

      mix dd.fixtures.capture
      mix dd.fixtures.capture --source wiktionary --lemma cat --force
      mix dd.fixtures.capture --source wikipedia --lemma seal --force

  Wiktionary fixtures are stored **untrimmed** on purpose: scorecard M4 measures
  trimmed size against untrimmed, so checking in the trimmed record would
  destroy the denominator. The test applies `trim/1` itself.

  Refuses to overwrite without `--force`, so a green suite can never be quietly
  re-baselined against new data.

  The two API sources are captured by calling the same clients the absorb uses,
  so a fixture is a real response and not a hand-written approximation.
  Wikipedia fixtures carry the absorb's `_probe` annotation, because
  `materialize/1` reads the lexeme keys from it.

  Options:

    * `--source` — any slug `Absorb.implemented/0` knows (default: all of them)
    * `--lemma` — repeatable (default: cat, dog, oyster; the API sources add
      `seal`, which is a disambiguation page)
    * `--force` — overwrite existing fixtures
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Absorb.GzipLines
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @default_lemmas ~w(cat dog oyster)
  # `seal` earns its place: it is a Wikipedia disambiguation page, which is the
  # only way to test the L4 path offline.
  @api_lemmas @default_lemmas ++ ~w(seal)
  # A static book source is read back out of `source_records` by its printed
  # headword. These are each one's awkward cases, not its ordinary ones; a
  # source not named here gets the default three.
  #
  #   * **Bierce** — the entry the HTML mis-wraps in a `<pre>`, the alternate
  #     headword, the definition that resumes lowercase after its verse, the
  #     stub whose whole body is the verse, the bare cross-reference, the joke
  #     part of speech, the `[from X]` bracket, a letter essay, and the entry
  #     with 26 continuation paragraphs.
  #   * **Johnson** — the alternate headword (`A'BBEY, or ABBY`), the comma that
  #     is a gloss rather than an alternate (`METHO'UGHT, the preterite of
  #     methinks`), the ten-way homograph, and the verb whose printed headword
  #     carries a grammar note (`To ABIDE. I abode or abid.`).
  @static_lemmas %{
    "bierce" =>
      @default_lemmas ++ ~w(eucharist babe monument insectivora brute hash academy x story),
    "johnson" => @default_lemmas ++ ~w(abbey methought a abide)
  }
  @dir "test/support/fixtures"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [source: :string, lemma: :keep, force: :boolean])

    given = Keyword.get_values(opts, :lemma)

    sources =
      case opts[:source] do
        nil -> all_sources()
        one -> [one]
      end

    captured =
      Enum.flat_map(sources, fn
        "wordnet" -> capture_wordnet(lemmas(given, @default_lemmas), opts)
        "wiktionary" -> capture_wiktionary(lemmas(given, @default_lemmas), opts)
        "wikipedia" -> capture_wikipedia(lemmas(given, @api_lemmas), opts)
        "wikidata" -> capture_wikidata(lemmas(given, @api_lemmas), opts)
        slug -> capture_static(slug, lemmas(given, @static_lemmas[slug] || @default_lemmas), opts)
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

  # A static book source (Bierce, Johnson) keys its records by the printed
  # headword, so the lemma is upcased to find them, and a lemma may legitimately
  # return several: Bierce defines `REASON` twice, Johnson defines `A` ten
  # times. Nothing here names a slug — the sixth source captures with no edit
  # (scorecard E1).
  defp capture_static(slug, lemmas, opts) do
    source = Sources.get_source_by_slug!(slug)

    Enum.flat_map(lemmas, fn lemma ->
      records =
        Repo.all(
          from r in SourceRecord,
            where: r.source_id == ^source.id,
            # Compared with the stress marks stripped from both sides: Johnson
            # prints `ABI'DE`, and the lemma we ask for is `abide`.
            where:
              fragment(
                "replace(replace(? ->> 'headword', ?, ''), ?, '') = ?",
                r.raw,
                "\u2019",
                "'",
                ^String.upcase(lemma)
              ),
            order_by: r.external_id,
            select: r.raw
        )

      write(slug, lemma, records, opts)
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

  defp lemmas([], default), do: default
  defp lemmas(given, _default), do: given

  # The API sources are captured through the same clients the absorb uses, so a
  # fixture is a real response. Stored **untrimmed**, like Wiktionary's, so the
  # trim tests have an honest denominator.
  defp capture_wikipedia(lemmas, opts) do
    Enum.flat_map(lemmas, fn lemma ->
      case Clients.Wikipedia.summaries([lemma]) do
        {:ok, %{^lemma => page}} when is_map(page) ->
          write("wikipedia", lemma, [with_probe(page, lemma)], opts)

        _ ->
          write("wikipedia", lemma, [], opts)
      end
    end)
  end

  # `_probe` is the absorb's annotation, not Wikipedia's payload: it carries the
  # lexeme keys the probe stands for, so `materialize/1` never has to guess a
  # part of speech. A fixture without it would exercise a path the absorb never
  # takes.
  defp with_probe(page, lemma) do
    keys =
      Repo.all(from l in Lexeme, where: l.lemma == ^lemma, select: {l.lang, l.pos})
      |> Enum.map(fn {lang, pos} -> [lang, lemma, pos] end)

    keys = if keys == [], do: [["en", lemma, "noun"]], else: keys

    page = Map.put(page, "_probe", %{"lemma" => lemma, "lexemes" => keys})

    if get_in(page, ["pageprops", "disambiguation"]) do
      Map.put(page, "_candidates", candidates(page["title"]))
    else
      page
    end
  end

  defp candidates(title) do
    with {:ok, titles} <- Clients.Wikipedia.links(title),
         titles = Enum.take(titles, 30),
         {:ok, props} <- Clients.Wikipedia.pageprops(titles) do
      for t <- titles,
          page = Map.get(props, t),
          is_map(page),
          qid = get_in(page, ["pageprops", "wikibase_item"]),
          not is_nil(qid) do
        %{"title" => page["title"], "qid" => qid, "description" => page["description"]}
      end
    else
      _ -> []
    end
  end

  # Wikidata is captured by QID, discovered from the lemma's Wikipedia page, plus
  # the P13176 taxon item behind it — Q146 *cat* and Q20980826 *Felis catus* are
  # different entities and the pair is what `taxon_concept_id` is tested on.
  defp capture_wikidata(lemmas, opts) do
    Enum.flat_map(lemmas, fn lemma ->
      with {:ok, %{^lemma => page}} when is_map(page) <- Clients.Wikipedia.summaries([lemma]),
           qid when is_binary(qid) <- get_in(page, ["pageprops", "wikibase_item"]),
           {:ok, entities} <- Clients.Wikidata.fetch([qid]),
           entity when is_map(entity) <- Map.get(entities, qid) do
        taxa =
          case Clients.Wikidata.entity_ids(entity, "P13176") do
            [] -> %{}
            ids -> ids |> Enum.take(1) |> Clients.Wikidata.fetch() |> then(&elem(&1, 1))
          end

        write("wikidata", lemma, [entity | Map.values(taxa)], opts)
      else
        _ -> write("wikidata", lemma, [], opts)
      end
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

  defp all_sources, do: Enum.sort(DevilsDictionary.Absorb.implemented())

  defp write_manifest([]), do: :ok

  defp write_manifest(captured) do
    sources =
      Sources.list_sources()
      |> Enum.filter(&(&1.slug in all_sources()))
      |> Map.new(
        &{&1.slug,
         Map.take(&1.config, ~w(dump_url edition snapshot_date dump_date api_url batch_size))}
      )

    # Merged, not replaced: capturing one source must not erase the record of
    # when the others were taken.
    previous =
      case File.read(Path.join(@dir, "MANIFEST.json")) do
        {:ok, body} -> Jason.decode!(body)["fixtures"] || []
        _ -> []
      end

    fixtures =
      (captured ++ previous)
      |> Enum.uniq_by(&{&1["source"], &1["lemma"]})
      |> Enum.sort_by(&{&1["source"], &1["lemma"]})

    manifest = %{
      "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "sources" => sources,
      "fixtures" => fixtures
    }

    path = Path.join(@dir, "MANIFEST.json")
    File.write!(path, Jason.encode_to_iodata!(manifest, pretty: true))
    Mix.shell().info("  + #{path}")
  end
end
