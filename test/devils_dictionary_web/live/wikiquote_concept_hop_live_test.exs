defmodule DevilsDictionaryWeb.WikiquoteConceptHopLiveTest do
  @moduledoc """
  `/define/coward` after #172 build A: its sense refers to a concept with no
  Wikiquote page, which has as its characteristic *cowardice*, whose page is
  *Cowardice*. The page shows a Quotes shelf from *Cowardice*, each line's
  reason naming the hop, and none of them a search result.

  The run is the provider's own over the page captured on 2026-09-24 and the
  Wikidata answers of that day (`WikiquoteFixture`); the page is then
  mounted as a reader opens it.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  alias DevilsDictionary.Discovery.Providers.Wikiquote

  @reason "the concept a sense of “coward” has as its characteristic (Q1401607)."

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Wikiquote])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Wikiquote})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req)
    end)

    WikiquoteFixture.respond(%{
      "Q104605901" => %{
        "title" => nil,
        "claims" => %{"P1552" => ["Q1401607"], "P279" => ["Q215627"]}
      },
      "Q1401607" => "Cowardice"
    })

    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes})
  end

  defp coward_page!(ctx) do
    word = word!(ctx, "coward", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    entity = concept!("Q104605901", "coward")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})
    target = %{object_id: word.object_id, term: "coward", language: "en", relevance: "term"}

    {:queued, run} = Discovery.request(target, "wikiquote")
    Discovery.execute_run(run.id)
    word
  end

  test "coward shows a Quotes shelf from Cowardice, the reason naming the hop", ctx do
    coward_page!(ctx)
    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    assert has_element?(live, "#culture-filter-quote")
    assert has_element?(live, "#culture-provider-wikiquote")
    assert has_element?(live, ~s([id^="culture-quote-"]))

    # Every line's reason is the hop, in the About note's list.
    about = "#culture-about-quote-wikiquote"
    assert has_element?(live, about, "From Wikiquote's page “Cowardice”, " <> @reason)

    # No plaque: nothing on the shelf is called a search result.
    refute render(live) =~ "Search result for"
    refute has_element?(live, about, "the page of the concept this meaning refers to")
  end

  test "a page with no sense link still has no Quotes shelf", ctx do
    word!(ctx, "situationship", ~w(wordnet))
    {:ok, live, _html} = live(ctx.conn, ~p"/define/situationship")

    refute has_element?(live, "#culture-filter-quote")
  end
end
