defmodule DevilsDictionary.Health.Pages do
  @moduledoc """
  The five scorecard rows the word page answers — **X1** (every word has a
  page), **U2** (the flagship words), **U3** (provenance everywhere), **U6**
  (every card links out) and **R3** (chains render).

  All five are measured by building the page, not by rendering it: they call
  `Lexicon.WordPage.build/2` and read the struct. That keeps them pure — no
  HTTP, no endpoint, no browser — so `mix dd.score` and `mix test` measure the
  same thing, and a row cannot pass because a template happened to swallow a
  nil.
  """

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Sources

  @flagships ~w(cat dog oyster)
  @chain_words ~w(cat dog)
  @page_words Enum.uniq(@flagships ++ @chain_words ++ ~w(joy grief oysters))
  @sample 200

  @doc """
  **X1** — every word has a page.

  Renders a random sample of the index through `WordPage.build/2`. Most of the
  1.5 million rows are bare, which is the point: a word nobody has written
  about still gets a page, so the sample is dominated by exactly the case most
  likely to raise.

  Sampled by `Lexicon.random_lexemes/1`, which draws random ids across the id
  range rather than `ORDER BY random()`, a sequential scan of the whole index.
  """
  def word_pages(sample \\ @sample) do
    probes =
      for lexeme <- Lexicon.random_lexemes(sample: sample) do
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

  The thing panel's two ↗ — Wikipedia and Wikidata — joined the population in
  U2, the carry-over from the U1b audit. They are probed only for a word that
  names something, and counted separately: a word with no concept has no panel
  and cannot fail a row about link-outs.
  """
  def cards_link_out do
    pages = pages()

    cards =
      for {word, page} <- pages, card <- page.cards do
        %{word: word, card: card.id, url: card.url}
      end
      |> Enum.uniq_by(&{&1.word, &1.card})

    things =
      for {word, %{thing: %{concept: concept} = thing}} when not is_nil(concept) <- pages,
          {label, url} <- [{"wikipedia", thing.wikipedia_url}, {"wikidata", thing.wikidata_url}] do
        %{word: word, card: "thing-#{label}", url: url}
      end

    all = cards ++ things
    linked = Enum.filter(all, &linked?/1)

    %{
      probes: Enum.reject(all, &linked?/1),
      passed: length(linked),
      total: length(all),
      cards: length(cards),
      things: length(things)
    }
  end

  defp linked?(%{url: url}), do: is_binary(url) and url != ""

  @doc """
  **U3** — provenance everywhere.

  Every card opens the drawer, and the drawer is a `source_records` row: the
  external id, the canonical url, the license, the three timestamps and the
  trimmed raw. A card passes when at least one of the records it cites still
  exists — `entries.source_record_id` and `senses.source_record_id` are
  `on_delete: :nilify_all`, so a deleted record leaves a card that renders and
  cannot say where it came from, which is exactly the rot this row is for.

  Two figures, because one hides the other: **cards** that open a drawer, and
  **citations** — every entry and every sense on those cards — that carry a
  record. A WordNet card cites one record per synset, so a card can pass on its
  first synset while the rest have gone.

  The thing panel is reported beside them, never graded: a concept has no
  `source_record_id`, and its records are found by the convention that Wikidata
  writes `Q…` and Wikipedia writes `concept:Q…` or the title it probed with.
  A convention is not a foreign key.
  """
  def cards_provenance do
    pages = pages()

    cards =
      for {word, page} <- pages, card <- page.cards do
        citations = card.entries ++ Enum.flat_map(card.groups, & &1.senses)

        %{
          word: word,
          card: card.id,
          records: WordPage.card_record_ids(card),
          citations: length(citations),
          cited: Enum.count(citations, &(not is_nil(&1.record_id)))
        }
      end
      |> Enum.uniq_by(&{&1.word, &1.card})

    known =
      cards
      |> Enum.flat_map(& &1.records)
      |> Sources.records()
      |> MapSet.new(& &1.id)

    probes = Enum.map(cards, &Map.put(&1, :ok, Enum.any?(&1.records, fn id -> id in known end)))

    %{
      probes: Enum.reject(probes, & &1.ok),
      passed: Enum.count(probes, & &1.ok),
      total: length(probes),
      citations: Enum.sum(Enum.map(cards, & &1.citations)),
      cited: Enum.sum(Enum.map(cards, & &1.cited)),
      words: length(pages),
      things: thing_provenance(pages)
    }
  end

  # Reported, not graded. `passed` is the words whose panel finds at least one
  # record of its own; `total` is the words that have a panel at all.
  defp thing_provenance(pages) do
    with_concept =
      for {_word, %{thing: %{concept: concept}} = page} when not is_nil(concept) <- pages,
          do: page

    opened =
      Enum.count(with_concept, fn page ->
        case WordPage.provenance(page, "thing") do
          %{records: [_ | _]} -> true
          _ -> false
        end
      end)

    %{passed: opened, total: length(with_concept)}
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

        # One block per page since #133 R4, so there is nothing to flatten:
        # every lexeme's *broader* rows are already merged into one group.
        wiktionary =
          case page.related do
            nil -> []
            related -> Enum.map(Map.get(related.groups, :broader, %{shown: []}).shown, & &1.lemma)
          end

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

  # The six words U3 and U6 are measured on, built once per call: the three
  # flagships (which are also the two chain words), an emotion, its opposite,
  # and a plural that redirects. A small denominator, which is why the actual
  # strings print it.
  defp pages, do: for(word <- @page_words, do: {word, build!(word)})

  defp safe_build(word) do
    {:ok, build!(word)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end
end
