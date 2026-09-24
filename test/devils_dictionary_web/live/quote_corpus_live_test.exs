defmodule DevilsDictionaryWeb.QuoteCorpusLiveTest do
  @moduledoc """
  The public-domain corpus on a word page (#174): mounted with the page, no
  request made, in the 👑 band, *held locally* on every card, and absent from
  a page whose senses refer to nothing it filed.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Corpus.Seeder
  alias DevilsDictionary.QuotesCorpusFixtures
  alias DevilsDictionary.Registry

  @manifest QuotesCorpusFixtures.manifest()

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    # No live provider: whatever reaches the Quotes shelf is the corpus.
    Application.put_env(:devils_dictionary, :discovery_providers, [])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, providers) end)

    {:ok, _} = Seeder.run(@manifest)
    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes})
  end

  defp voltaire_page!(ctx) do
    word = word!(ctx, "voltaire", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    voltaire = Registry.by_external_id("wikidata", "Q9068")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", voltaire, %{confidence: 0.95})
    word
  end

  test "the corpus is on the page it was filed under, held locally and verified", ctx do
    voltaire_page!(ctx)
    {:ok, live, _html} = live(ctx.conn, ~p"/define/voltaire")

    assert has_element?(live, "#culture-filter-quote")
    assert has_element?(live, "#culture-band-quote-aristocracy", "Public domain")
    assert has_element?(live, "#culture-provider-wikiquote-pd-v1")

    for row <- @manifest["rows"] do
      card = "#culture-quote-#{row["fingerprint"]}"
      assert has_element?(live, "#culture-held-#{row["fingerprint"]}", "held locally")
      assert has_element?(live, "#{card}-provenance", "Verified")
      assert has_element?(live, "#{card}-source-wikiquote-pd-v1")
      # The credit is a link to the person the registry holds, by QID.
      assert has_element?(
               live,
               "#culture-creator-quotation_fingerprint-#{row["fingerprint"]} a",
               "Voltaire"
             )

      assert has_element?(live, "#culture-evidence-#{row["fingerprint"]}")
    end

    # The corpus's own mark, from its source row, not a placeholder letter.
    fingerprint = hd(@manifest["rows"])["fingerprint"]

    assert has_element?(
             live,
             ~s(#culture-quote-#{fingerprint}-source-wikiquote-pd-v1 img[src="/images/sources/wikiquote.png"])
           )

    # The About note says where the lines came from, as a corpus's does.
    assert has_element?(live, "#culture-about-quote-wikiquote-pd-v1", "held locally")
    assert has_element?(live, "#culture-about-quote-wikiquote-pd-v1", "Project Gutenberg")
    refute has_element?(live, ~s(#culture-about-quote-wikiquote-pd-v1 a[href="/artworks"]))
  end

  test "a page whose senses refer to nothing the corpus filed has no Quotes shelf", ctx do
    word!(ctx, "garden", ~w(wordnet))
    {:ok, live, _html} = live(ctx.conn, ~p"/define/garden")

    refute has_element?(live, "#culture-filter-quote")
    refute has_element?(live, ~s([id^="culture-held-"]))
  end

  test "audit: retired corpus quotations disappear from the public shelf", ctx do
    voltaire_page!(ctx)
    row = hd(@manifest["rows"])
    id = Registry.by_external_id("quotation_fingerprint", row["fingerprint"])
    {:ok, _} = Registry.retire(id, reason: "audit withdrawn content")
    {:ok, view, _} = live(ctx.conn, ~p"/define/voltaire")
    refute has_element?(view, "#culture-quote-#{row["fingerprint"]}")
  end
end
