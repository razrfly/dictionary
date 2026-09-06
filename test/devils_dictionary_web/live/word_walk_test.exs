defmodule DevilsDictionaryWeb.WordWalkTest do
  @moduledoc """
  The acceptance criterion #71 §2 ends on: **ten hops with no dead end.**

  The walk is the whole point of the page, and it is the one thing that cannot
  be checked by looking at a single render — a chip is only good if the page it
  lands on has a chip of its own. So this follows real hrefs through real
  renders, ten times, and fails on the first page that offers nowhere to go.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures

  @hops 10

  setup ctx do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})
  end

  # A chain of words where each is broader than the last, plus a derived word
  # hanging off every one — so the walk has more than one kind of edge to take
  # and cannot survive by following a single group.
  defp graph!(ctx) do
    lemmas =
      ~w(oyster bivalve mollusk invertebrate animal organism creature being thing entity object)

    words =
      for lemma <- lemmas do
        word = word!(ctx, lemma, ~w(wordnet wiktionary))
        sense = sense!(ctx, word, "wordnet", group_key: "oewn-#{lemma}-n", gloss: "a #{lemma}")
        {word, sense}
      end

    words
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{from, from_sense}, {to, _}] ->
      relation!(ctx, from, :hypernym, to,
        source: "wordnet",
        from_sense: from_sense,
        to_group_key: "oewn-#{to.lemma}-n"
      )
    end)

    Enum.each(words, fn {word, _sense} ->
      derived = word!(ctx, "#{word.lemma}ish", ~w(wiktionary))
      relation!(ctx, word, :derived, derived)
    end)

    words
  end

  test "ten hops from oyster, no dead end, the trail in the URL the whole way", ctx do
    graph!(ctx)

    # Seen words, not seen URLs: the same word reached with a different trail is
    # the same word, and a walk that revisits it is a walk going nowhere.
    {seen, final_url} =
      Enum.reduce(1..@hops, {["oyster"], "/define/oyster"}, fn hop, {seen, url} ->
        {:ok, _live, html} = live(ctx.conn, url)

        assert html =~ ~s(id="headword"), "hop #{hop}: #{url} has no headword"

        next =
          html
          |> hop_targets()
          |> Enum.reject(&(slug_of(&1) in seen))
          |> List.first()

        assert next, "hop #{hop}: #{url} is a dead end — no chip leads to a word not yet walked"

        # Every hop after the first carries the walk it came from.
        if hop > 1, do: assert(next =~ "trail=")

        {[slug_of(next) | seen], next}
      end)

    assert length(Enum.uniq(seen)) == @hops + 1, "the walk revisited a word: #{inspect(seen)}"
    assert final_url =~ "trail="

    # The trail the tenth page arrived with is the walk, in order.
    {:ok, _live, html} = live(ctx.conn, final_url)
    assert html =~ ~s(id="trail")
    assert html =~ ~s(id="trail-oyster")
  end

  test "a page reached by a pasted URL reproduces the same walk", ctx do
    graph!(ctx)

    url = "/define/mollusk?trail=oyster,bivalve"

    {:ok, _live, html} = live(ctx.conn, url)

    assert html =~ ~s(id="trail-oyster")
    assert html =~ ~s(id="trail-bivalve")
    assert html =~ ~s(id="headword")
  end

  # Every chip and chain step on the page, in render order, as the hrefs a
  # reader could actually click.
  defp slug_of(href) do
    href |> String.replace_prefix("/define/", "") |> String.split("?") |> hd()
  end

  defp hop_targets(html) do
    ~r/href="(\/define\/[^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, href] -> String.replace(href, "&amp;", "&") end)
    |> Enum.uniq()
  end
end
