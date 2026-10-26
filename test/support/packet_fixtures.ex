defmodule DevilsDictionary.PacketFixtures do
  @moduledoc """
  Pilot pages shaped for packet v2 (#262): the ten pages of #253 D2, each a
  whole On scope with words, senses, quotations, entries, catalog works and
  exemplars.

  The four whose shape #262 names have it: *love* is five words, 43 senses
  and so 48 packet meanings; *war* has 37 meanings and *hope* 58; *greed*
  has no Bierce entry, 7 quotations and 6 meanings. The other six are
  illustrative. Every text is fixture text, except the catalog works, which
  must be the committed `wikidata-famous-v1` rows that depict the page's
  concept (four depict love, Q316; two depict war, Q198).
  """

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{CurationFixtures, ExemplarFixtures, Lexicon}
  alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}
  alias DevilsDictionary.Lexicon.WordPage

  @famous "priv/artworks/manifests/wikidata-famous-v1.json"

  @shapes %{
    "love" => %{
      words: [
        {"love", "noun", [{"wordnet", 6}, {"wiktionary", 24}]},
        {"love", "verb", [{"wordnet", 5}, {"wiktionary", 5}]},
        {"Love", "name", [{"wiktionary", 1}]},
        {"Love", "noun", [{"wiktionary", 1}]},
        {"LoVe", "name", [{"wiktionary", 1}]}
      ],
      entries: [
        {"bierce", 0, "LOVE", "n"},
        {"johnson", 0, "LOVE", "n. s."},
        {"johnson", 1, "To LOVE", "v. a."}
      ],
      quotations: 14,
      works: {"Q316", "love"},
      exemplars: {3, 1}
    },
    "war" => %{
      words: [
        {"war", "noun", [{"wordnet", 3}, {"wiktionary", 24}]},
        {"war", "verb", [{"wordnet", 2}, {"wiktionary", 6}]}
      ],
      entries: [
        {"bierce", 0, "WAR", "n"},
        {"johnson", 0, "WAR", "n. s."},
        {"johnson", 1, "To WAR", "v. n."}
      ],
      quotations: 9,
      works: {"Q198", "war"},
      exemplars: {2, 0}
    },
    "hope" => %{
      words: [
        {"hope", "noun", [{"wordnet", 4}, {"wiktionary", 30}]},
        {"hope", "verb", [{"wordnet", 3}, {"wiktionary", 10}]},
        {"Hope", "name", [{"wiktionary", 8}]}
      ],
      entries: [{"bierce", 0, "HOPE", "n"}, {"johnson", 0, "HOPE", "n. s."}],
      quotations: 11,
      exemplars: {1, 0}
    },
    "greed" => %{
      words: [
        {"greed", "noun", [{"wordnet", 1}, {"wiktionary", 2}]},
        {"greed", "verb", [{"wiktionary", 1}]}
      ],
      entries: [{"johnson", 0, "GREEDINESS", "n. s."}],
      quotations: 7
    },
    "nepotism" => %{
      words: [{"nepotism", "noun", [{"wordnet", 1}, {"wiktionary", 2}]}],
      entries: [{"bierce", 0, "NEPOTISM", "n"}],
      quotations: 2
    },
    "coward" => %{
      words: [
        {"coward", "noun", [{"wordnet", 1}, {"wiktionary", 3}]},
        {"coward", "verb", [{"wiktionary", 1}]}
      ],
      entries: [{"bierce", 0, "COWARD", "n"}, {"johnson", 0, "COWARD", "n. s."}],
      quotations: 4
    },
    "patience" => %{
      words: [{"patience", "noun", [{"wordnet", 2}, {"wiktionary", 4}]}],
      entries: [{"bierce", 0, "PATIENCE", "n"}, {"johnson", 0, "PATIENCE", "n. s."}],
      quotations: 3
    },
    "justice" => %{
      words: [{"justice", "noun", [{"wordnet", 6}, {"wiktionary", 8}]}],
      entries: [{"bierce", 0, "JUSTICE", "n"}, {"johnson", 0, "JUSTICE", "n. s."}],
      quotations: 5
    },
    "truth" => %{
      words: [{"truth", "noun", [{"wordnet", 5}, {"wiktionary", 9}]}],
      entries: [{"bierce", 0, "TRUTH", "n"}, {"johnson", 0, "TRUTH", "n. s."}],
      quotations: 6
    },
    "bestiality" => %{
      words: [{"bestiality", "noun", [{"wordnet", 2}, {"wiktionary", 3}]}],
      entries: [],
      quotations: 1
    }
  }

  @doc "The ten pilot pages (#253 D2), in D2's order."
  def pilot_slugs,
    do: ~w(nepotism greed war love coward patience justice truth hope bestiality)

  @doc "A pilot page's shape."
  def shape(slug), do: Map.fetch!(@shapes, slug)

  @doc "The page as the screen and the reader build it."
  def page(slug), do: slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

  @doc """
  Builds pilot page `slug` from its shape (or `shape`, to vary one). `ctx`
  carries the seeded `sources`; `opts`: `:contributor` and `:reviewer`
  accounts for the exemplars, made when absent. Returns `%{words, senses,
  entries, works, exemplars, pending}`.
  """
  def pilot!(ctx, slug, shape \\ nil, opts \\ []) do
    shape = shape || shape(slug)

    words =
      for {lemma, pos, senses} <- shape.words do
        {word!(ctx, lemma, Enum.map(senses, &elem(&1, 0)), pos: pos, scope: nil), senses}
      end

    total = words |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    quotations = quotations_per_sense(Map.get(shape, :quotations, 0), total)

    {senses, _n} =
      Enum.flat_map_reduce(words, 0, fn {lexeme, by_source}, n ->
        Enum.flat_map_reduce(by_source, n, fn {source, count}, n ->
          made =
            for k <- 1..count//1 do
              index = n + k - 1

              sense!(ctx, lexeme, source,
                gloss:
                  "Fixture #{source} sense #{k} of #{lexeme.lemma} (#{lexeme.part_of_speech}).",
                position: k,
                group_key: if(source == "wordnet", do: "fixture-#{slug}-#{index}"),
                examples: examples(slug, index, Map.get(quotations, index, 0))
              )
            end

          {made, n + count}
        end)
      end)

    lexemes = Enum.map(words, &elem(&1, 0))

    entries =
      for {source, word, headword, pos} <- Map.get(shape, :entries, []) do
        lexeme = Enum.at(lexemes, word)

        entry!(ctx, lexeme, source,
          headword: headword,
          pos: pos,
          body: "A fixture #{source} entry for #{lexeme.lemma}, as #{pos}."
        )
      end

    works = works!(shape[:works], lexemes, senses)
    {exemplars, pending} = exemplars!(shape[:exemplars], senses, opts)

    %{
      words: lexemes,
      senses: senses,
      entries: entries,
      works: works,
      exemplars: exemplars,
      pending: pending
    }
  end

  # Quotations one per sense from the first, round again when there are
  # more quotations than senses.
  defp quotations_per_sense(0, _total), do: %{}
  defp quotations_per_sense(_n, 0), do: %{}

  defp quotations_per_sense(n, total),
    do: Enum.frequencies(for k <- 0..(n - 1), do: rem(k, total))

  defp examples(slug, index, count) do
    for q <- 1..count//1 do
      %{
        "type" => "quotation",
        "text" => "Fixture quotation #{q} of #{slug} sense #{index + 1}, in the source's words.",
        "ref" => "Fixture author, fixture work #{index + 1}.#{q}:"
      }
    end
  end

  # The committed rows that depict the concept, on the page's shelf through
  # its first sense, which refers to that concept.
  defp works!(nil, _lexemes, _senses), do: []

  defp works!({qid, label}, [lexeme | _], [sense | _]) do
    concept = concept!(qid, label)
    link!(lexeme, concept, sense: sense, confidence: 0.95)

    rows =
      @famous
      |> Manifest.load!()
      |> Map.fetch!("rows")
      |> Enum.filter(fn row -> Enum.any?(row["depicts"] || [], &(&1["qid"] == qid)) end)

    {:ok, _summary} = Manifest.new("wikidata-famous", rows) |> Seeder.run()
    rows
  end

  # Accepted exemplars, each under its own sense from the second, then the
  # nominations still waiting.
  defp exemplars!(nil, _senses, _opts), do: {[], []}

  defp exemplars!({accepted, pending}, senses, opts) do
    contributor =
      Keyword.get_lazy(opts, :contributor, fn -> CurationFixtures.account([:contributor]) end)

    reviewer = Keyword.get_lazy(opts, :reviewer, fn -> CurationFixtures.account([:reviewer]) end)

    nominate = fn n ->
      sense = Enum.at(senses, rem(n, length(senses)))
      person = ExemplarFixtures.person!("Fixture exemplar #{n}")
      ExemplarFixtures.nominate!(contributor, person, sense)
    end

    claims =
      for n <- 1..accepted//1 do
        claim = nominate.(n)
        ExemplarFixtures.decide!(reviewer, claim)
        claim
      end

    waiting = for n <- (accepted + 1)..(accepted + pending)//1, do: nominate.(n)
    {claims, waiting}
  end
end
