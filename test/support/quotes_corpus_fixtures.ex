defmodule DevilsDictionary.QuotesCorpusFixtures do
  @moduledoc """
  The public-domain corpus build (#174) against captured answers, for the
  build's own tests and for the seeder's: Voltaire's page (build 4a's
  fixture), *Candide* as Gutenberg serves it (build 5's), and Wikidata's
  answers written out here. No network.
  """

  alias DevilsDictionary.Quotations.Corpus.Build
  alias DevilsDictionary.WikiquoteFixtures

  @endpoints [
    parsoid: "https://wikiquote.test/page/html/",
    wikiquote_api: "https://wikiquote.test/w/api.php",
    wikidata_api: "https://wikidata.test/w/api.php",
    sparql: "https://sparql.test/sparql",
    gutenberg: "https://gutenberg.test/cache/epub/"
  ]

  @doc "The test hosts every request goes to."
  def endpoints, do: @endpoints

  @doc "Candide, Gutenberg #19942."
  def candide, do: File.read!("test/support/fixtures/verifier/pg19942.txt.gz") |> :zlib.gunzip()

  @doc """
  Runs the build over Voltaire alone — a concept a sense refers to, and a
  person with a pre-line Gutenberg work — with `opts` merged in.
  """
  def build(opts \\ []) do
    Build.run(
      Keyword.merge(
        [
          endpoints: @endpoints,
          concept_qids: ["Q9068"],
          person_qids: ["Q9068"],
          get: stub(self())
        ],
        opts
      )
    )
  end

  @doc "A committed-shaped manifest from `build/1`."
  def manifest(opts \\ []) do
    {:ok, rows, selection, ledger} = build(opts)
    Mix.Tasks.Dd.Quotes.Corpus.Build.manifest(rows, selection, ledger)
  end

  defp uri(qid), do: %{"type" => "uri", "value" => "http://www.wikidata.org/entity/#{qid}"}
  defp lit(value), do: %{"type" => "literal", "value" => value}

  @doc """
  What each test host answers, reporting every URL to `test_pid` as
  `{:request, url}`. `candide` swaps the text, for the drift case.

  `items` adds Wikidata items to the sitelinks answer, for the concept hop
  (#172 build A): `%{qid => %{"title" => title | nil, "claims" => %{property
  => [qid]}}}`. Voltaire's is always there, with his page and his `P31`.
  """
  def stub(test_pid, candide \\ candide(), items \\ %{}) do
    voltaire = WikiquoteFixtures.body("voltaire")

    fn request ->
      send(test_pid, {:request, request[:url]})
      uri = URI.parse(request[:url])

      case {uri.host, uri.path, request[:params][:props]} do
        {"sparql.test", _, _} ->
          query = request[:form][:query]

          bindings =
            cond do
              query =~ "P629" ->
                []

              query =~ "P2034" ->
                [
                  %{
                    "work" => uri("Q215894"),
                    "author" => uri("Q9068"),
                    "pg" => lit("19942"),
                    "date" => lit("1759-01-01T00:00:00Z")
                  },
                  # After the line: never read.
                  %{
                    "work" => uri("Q999999"),
                    "author" => uri("Q9068"),
                    "pg" => lit("77777"),
                    "date" => lit("1950-01-01T00:00:00Z")
                  }
                ]
            end

          {:ok, 200, %{"results" => %{"bindings" => bindings}}, %{}}

        {"wikiquote.test", "/page/html/" <> _title, _} ->
          {:ok, 200, voltaire, %{}}

        {"wikiquote.test", "/w/api.php", _} ->
          {:ok, 200, %{"query" => %{"pages" => []}}, %{}}

        {"wikidata.test", _, "sitelinks" <> _ = props} ->
          items =
            Map.put_new(items, "Q9068", %{"title" => "Voltaire", "claims" => %{"P31" => ["Q5"]}})

          entities =
            for qid <- String.split(request[:params][:ids], "|"),
                item = items[qid],
                into: %{},
                do: {qid, sitelink_entity(qid, item, props =~ "claims")}

          {:ok, 200, %{"entities" => entities}, %{}}

        {"wikidata.test", _, _} ->
          ids = request[:params][:ids] |> String.split("|")
          {:ok, 200, %{"entities" => Map.new(ids, &{&1, entity(&1)})}, %{}}

        {"gutenberg.test", "/cache/epub/19942/pg19942.txt", _} ->
          {:ok, 200, candide, %{}}

        {"gutenberg.test", _, _} ->
          {:ok, 404, "", %{}}
      end
    end
  end

  defp sitelink_entity(qid, item, claims?) do
    links =
      case item["title"] do
        nil -> %{}
        title -> %{"enwikiquote" => %{"site" => "enwikiquote", "title" => title}}
      end

    entity = %{"id" => qid, "sitelinks" => links}

    if claims?,
      do:
        Map.put(
          entity,
          "claims",
          Map.new(item["claims"] || %{}, fn {property, ids} ->
            {property,
             Enum.map(
               ids,
               &claim(property, %{
                 "type" => "wikibase-entityid",
                 "value" => %{"id" => &1, "entity-type" => "item"}
               })
             )}
          end)
        ),
      else: entity
  end

  defp entity("Q9068") do
    %{
      "id" => "Q9068",
      "labels" => %{"en" => %{"language" => "en", "value" => "Voltaire"}},
      "descriptions" => %{"en" => %{"language" => "en", "value" => "French writer"}},
      "claims" => %{
        "P31" => [
          claim("P31", %{
            "type" => "wikibase-entityid",
            "value" => %{"id" => "Q5", "entity-type" => "item"}
          })
        ],
        "P569" => [
          claim("P569", %{
            "type" => "time",
            "value" => %{"time" => "+1694-11-21T00:00:00Z", "precision" => 11}
          })
        ]
      }
    }
  end

  defp entity("Q215894"),
    do: %{"id" => "Q215894", "labels" => %{"en" => %{"value" => "Candide"}}}

  defp entity(qid), do: %{"id" => qid, "missing" => ""}

  defp claim(property, datavalue) do
    %{
      "rank" => "normal",
      "mainsnak" => %{
        "snaktype" => "value",
        "property" => property,
        "hash" => "drop-me",
        "datavalue" => datavalue
      }
    }
  end
end
