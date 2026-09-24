defmodule DevilsDictionary.Discovery.Conformance.QuoteCorpusMultiSourceTest do
  @moduledoc """
  The multi-source check on the Quotes shelf with the public-domain corpus on
  it (#174): the corpus (`wikiquote-pd-v1`, seeded), Wikiquote (live, over
  build 4a's captured Voltaire page) and Wiktionary (build 4's fixture quote
  source) render **one** shelf, and on it:

    * the corpus **opens the 👑 band** (decision 2), ahead of the live lines
      dated the same era;
    * a line the corpus and a live source both hold is **one card naming
      both** (build 3's fold, across archetypes);
    * every corpus card says *held locally*, and no live card does;
    * every card carries its attribution line, and the corpus's reason is
      described as identity, never as a search.

  Read the way the word page reads it: live states through
  `Discovery.state/2`, the corpus through `Quotations.Corpus.shelf_items/1`,
  all of it through `Culture.section/1`.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Corpus.Seeder
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.FakeWiktionaryQuoteProvider, as: Wiktionary
  alias DevilsDictionary.Quotations
  alias DevilsDictionary.QuotesCorpusFixtures
  alias DevilsDictionary.Registry
  alias DevilsDictionaryWeb.Culture

  @moduletag :conformance

  @manifest QuotesCorpusFixtures.manifest()
  @corpus "wikiquote-pd-v1"

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Wikiquote, Wiktionary])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Wikiquote})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req)
      Wiktionary.clear_rows()
    end)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(&{&1, Conformance.human(&1, &1)})

      Req.Test.json(conn, %{"entities" => entities})
    end)

    # The corpus first, as a deploy seeds it: Voltaire is minted from the
    # manifest's own facts.
    {:ok, %{newly_created: created}} = Seeder.run(@manifest)
    assert created == @manifest["row_count"]
    voltaire = Registry.by_external_id("wikidata", "Q9068")

    # A page whose sense refers to him: his Wikiquote page is its theme, and
    # the corpus's lines were filed under it.
    context = %{sources: catalog.sources, scopes: catalog.scopes}
    word = word!(context, "voltaire", ~w(wordnet))
    sense = sense!(context, word, "wordnet")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", voltaire, %{confidence: 0.95})

    target = %{object_id: word.object_id, term: "voltaire", language: "en", relevance: "term"}
    %{target: target, word: word, context: context}
  end

  defp run!(target, slug) do
    {:queued, run} = Discovery.request(target, slug)
    :ok = Discovery.execute_run(run.id)
  end

  defp shelf(target) do
    corpus = %{
      status: :ready,
      archetype: :corpus,
      items: Quotations.Corpus.shelf_items([target.object_id]),
      provider: @corpus,
      provider_name: "Wikiquote, public domain",
      tier: :aristocracy,
      content_types: [:quote],
      mapping_id: nil,
      term: target.term,
      relevance: "term"
    }

    states = %{
      "wikiquote" => Discovery.state(target.object_id, "wikiquote"),
      Wiktionary.slug() => Discovery.state(target.object_id, Wiktionary.slug()),
      @corpus => corpus
    }

    {corpus.items,
     render_component(&Culture.section/1, states: states) |> LazyHTML.from_fragment()}
  end

  defp ids(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

  test "three sources, one Quotes shelf, and the corpus opens the 👑 band", %{target: target} do
    [shared | _] = @manifest["rows"]

    # Wiktionary's copy of one corpus line, in its own transcription.
    Wiktionary.put_rows("voltaire", [
      %{
        "id" => "wikt-voltaire-candide",
        "text" => shared["text"] |> String.upcase() |> String.trim_trailing("."),
        "author_qid" => "Q9068",
        "author_display" => "Voltaire",
        "year" => 1759,
        "source_url" => "https://en.wiktionary.org/wiki/garden"
      }
    ])

    WikiquoteFixture.respond(%{"Q9068" => "Voltaire"})
    run!(target, Wiktionary.slug())
    run!(target, "wikiquote")

    {corpus_items, doc} = shelf(target)
    assert length(corpus_items) == @manifest["row_count"]

    # One Quotes shelf, and its first band is the public domain.
    assert doc |> LazyHTML.query("#culture-filter-quote") |> Enum.count() == 1
    assert [first_band | _] = ids(doc, ~s([id^="culture-band-quote-"]))
    assert first_band == "culture-band-quote-aristocracy"

    # The band opens with every corpus line, before any live line of its era.
    # (One shelf on this page, so its first band's list is `#culture-results`.)
    band = ids(doc, ~s(#culture-results > li[id^="culture-result-"]))

    corpus_cards =
      Enum.map(corpus_items, &"culture-result-quotation_fingerprint-#{&1.external_id}")

    assert Enum.take(band, length(corpus_cards)) |> Enum.sort() == Enum.sort(corpus_cards)
    assert length(band) > length(corpus_cards), "no live line shares the band"

    # The shared line is one card, the corpus's, naming both sources — and
    # Wiktionary's own copy is not a second card.
    shared_card = "culture-quote-#{shared["fingerprint"]}"
    assert doc |> LazyHTML.query("##{shared_card}-source-#{@corpus}") |> Enum.count() == 1

    assert doc |> LazyHTML.query("##{shared_card}-source-#{Wiktionary.slug()}") |> Enum.count() ==
             1

    assert doc
           |> LazyHTML.query("#culture-result-wiktionary_quote-wikt-voltaire-candide")
           |> Enum.count() == 0

    # Held locally on every corpus card, and on nothing else.
    held = ids(doc, ~s([id^="culture-held-"]))
    assert Enum.sort(held) == Enum.sort(Enum.map(corpus_items, &"culture-held-#{&1.external_id}"))

    # Verified, from the build's checks, on every corpus card.
    for item <- corpus_items do
      badge = LazyHTML.query(doc, "#culture-quote-#{item.external_id}-provenance")
      assert LazyHTML.text(badge) =~ "Verified"
    end

    # Every card on the rail, in every band, carries its credit line.
    cards = LazyHTML.query(doc, ~s(li[id^="culture-result-"] figure))
    assert Enum.count(cards) >= length(band)

    for card <- cards do
      assert LazyHTML.text(card) =~ "CC BY-SA 4.0"
    end

    # Each source with a card on the rail is credited once in the shelf
    # header. Wiktionary's one line folded into the corpus's card, so it is
    # named on that card and not in the byline (CodeRabbit on #122: the
    # byline describes the rail, not what was delivered).
    for slug <- [@corpus, "wikiquote"] do
      assert doc |> LazyHTML.query("#culture-provider-#{slug}") |> Enum.count() == 1
    end

    assert doc |> LazyHTML.query("#culture-provider-#{Wiktionary.slug()}") |> Enum.count() == 0
  end

  test "the corpus's reason is identity: the page its concept names, never a search",
       %{target: target} do
    WikiquoteFixture.respond(%{})
    [item | _] = Quotations.Corpus.shelf_items([target.object_id])
    [reason] = DevilsDictionary.Discovery.MatchReason.from_result(item.match_details, "voltaire")

    assert reason.kind == :sitelink
    assert reason.identifier == "Q9068"
    assert DevilsDictionary.Discovery.MatchReason.evidence(reason) != :query
  end

  test "a page whose senses refer to nothing the corpus filed shows none of it", ctx do
    other = word!(ctx.context, "garden", ~w(wordnet))
    assert Quotations.Corpus.shelf_items([other.object_id]) == []
  end
end
