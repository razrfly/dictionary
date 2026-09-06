defmodule DevilsDictionary.Health.Pages do
  @moduledoc """
  The four scorecard rows the word page answers — **X1** (every word has a
  page), **U2** (the flagship words), **U6** (every card links out) and **R3**
  (chains render).

  All four are measured by building the page, not by rendering it: they call
  `Lexicon.WordPage.build/2` and read the struct. That keeps them pure — no
  HTTP, no endpoint, no browser — so `mix dd.score` and `mix test` measure the
  same thing, and a row cannot pass because a template happened to swallow a
  nil.
  """

  import Ecto.Query

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Lexeme, WordPage}
  alias DevilsDictionary.Repo

  @flagships ~w(cat dog oyster)
  @chain_words ~w(cat dog)
  @sample 200

  @doc """
  **X1** — every word has a page.

  Renders a random sample of the index through `WordPage.build/2`. Most of the
  1.5 million rows are bare, which is the point: a word nobody has written
  about still gets a page, so the sample is dominated by exactly the case most
  likely to raise.

  Sampled by drawing random ids across the id range rather than `ORDER BY
  random()`, which is a sequential scan of the whole index.
  """
  def word_pages(sample \\ @sample) do
    probes =
      for lexeme <- random_lexemes(sample) do
        case safe_build(lexeme.slug) do
          {:ok, page} ->
            %{input: lexeme.slug, ok: true, error: nil, cards: length(page.cards)}

          {:error, error} ->
            %{input: lexeme.slug, ok: false, error: error, cards: 0}
        end
      end

    %{probes: probes, passed: Enum.count(probes, & &1.ok), total: length(probes)}
  end

  @doc """
  **U2** — the flagship words.

  *cat*, *dog* and *oyster* each want at least four source cards spanning at
  least two tiers. Bierce and Johnson are both 👑, so the second tier has to
  come from the institutions.
  """
  def flagships do
    probes =
      for word <- @flagships do
        page = build!(word)
        tiers = page.cards |> Enum.map(& &1.tier) |> Enum.uniq()

        %{
          input: word,
          cards: length(page.cards),
          tiers: length(tiers),
          sources: page.cards |> Enum.map(& &1.source.slug) |> Enum.uniq(),
          ok: length(page.cards) >= 4 and length(tiers) >= 2
        }
      end

    %{probes: probes, passed: Enum.count(probes, & &1.ok), total: length(probes)}
  end

  @doc """
  **U6** — every card links out.

  A card's ↗ resolves to the row's own url, the url of the record it came from,
  or the source's `url_template` — A9's three answers, in A9's order. A card
  with none of them is a bug, not a missing icon, so this counts cards without
  a target rather than sampling them.
  """
  def cards_link_out do
    cards =
      for word <- @flagships ++ @chain_words ++ ~w(joy grief oysters),
          card <- build!(word).cards do
        %{word: word, card: card.id, url: card.url}
      end
      |> Enum.uniq_by(&{&1.word, &1.card})

    linked = Enum.filter(cards, &(is_binary(&1.url) and &1.url != ""))

    %{
      probes: Enum.reject(cards, &(is_binary(&1.url) and &1.url != "")),
      passed: length(linked),
      total: length(cards)
    }
  end

  @doc """
  **R3** — chains render.

  #69 §7 wants a hypernym chain reaching *animal* from at least two sources.
  The two are structurally different and both have to be there: WordNet's
  chain, walked synset to synset and rendered under the sense it belongs to,
  and Wiktionary's *broader* chips, which hang off the part of speech.
  """
  def chains do
    probes =
      for word <- @chain_words do
        page = build!(word)

        wordnet =
          page.cards
          |> Enum.filter(&(&1.source.slug == "wordnet"))
          |> Enum.flat_map(& &1.groups)
          |> Enum.map(&Enum.map(&1.chain, fn step -> step.lemma end))
          |> Enum.filter(&("animal" in &1))

        wiktionary =
          page.related
          |> Enum.flat_map(&Map.get(&1.groups, :broader, %{shown: []}).shown)
          |> Enum.map(& &1.lemma)

        %{
          input: word,
          chain: List.first(wordnet) || [],
          broader: wiktionary,
          ok: wordnet != [] and wiktionary != []
        }
      end

    %{probes: probes, passed: Enum.count(probes, & &1.ok), total: length(probes)}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp build!(word), do: word |> Lexicon.lookup() |> WordPage.build()

  defp safe_build(word) do
    {:ok, build!(word)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  # Uniform over the id range rather than `ORDER BY random()`, which reads all
  # 1.5 million rows. The id space has gaps — a round of 400 draws lands about
  # 140 rows — so rounds are drawn until the sample is full, each one a single
  # indexed lookup.
  defp random_lexemes(sample) do
    case Repo.one(from l in Lexeme, select: {min(l.id), max(l.id)}) do
      {nil, nil} -> []
      {low, high} -> draw(low..high, sample, [], 8)
    end
  end

  defp draw(_range, sample, taken, 0), do: Enum.take(taken, sample)

  defp draw(range, sample, taken, rounds) do
    have = MapSet.new(taken, & &1.id)
    ids = for _ <- 1..(sample * 3), do: Enum.random(range)
    ids = ids |> Enum.uniq() |> Enum.reject(&(&1 in have))

    found =
      Repo.all(
        from l in Lexeme,
          where: l.id in ^ids,
          select: %{id: l.id, slug: l.slug, lemma: l.lemma}
      )

    case taken ++ found do
      all when length(all) >= sample -> Enum.take(all, sample)
      all -> draw(range, sample, all, rounds - 1)
    end
  end
end
