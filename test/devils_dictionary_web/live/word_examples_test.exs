defmodule DevilsDictionaryWeb.WordExamplesTest do
  @moduledoc """
  The Examples section on `/define/:slug` (#181 build 1): the named things a
  source files under the word's meanings, as chips under one heading with one
  byline — after the definitions, and in place of the thing panel's old
  *examples* row.

  Ids, not words, as the rest of the page's tests.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)

    war = word!(ctx, "war", ~w(wordnet wiktionary))
    war_sense = sense!(ctx, war, "wordnet", group_key: "oewn-war-n", gloss: "armed conflict")
    wiktionary = sense!(ctx, war, "wiktionary", gloss: "organised violence")
    q198 = concept!("Q198", "war")
    link!(war, q198, sense: wiktionary)

    Map.merge(ctx, %{war: war, war_sense: war_sense, q198: q198})
  end

  defp named!(ctx, lemma, synset) do
    lexeme = word!(ctx, lemma, ~w(wordnet))
    sense = sense!(ctx, lexeme, "wordnet", group_key: synset)

    relation!(ctx, lexeme, :instance_of, nil,
      source: "wordnet",
      from_sense: sense,
      to_sense: ctx.war_sense
    )

    {lexeme, sense}
  end

  defp chip_id(item_id), do: "#examples-" <> String.replace(item_id, ":", "-")

  test "the section holds the named things as chips, and nothing else", ctx do
    named!(ctx, "Korean War", "oewn-korean-war-n")
    named!(ctx, "Boer War", "oewn-boer-war-n")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

    assert has_element?(live, "#examples")
    assert has_element?(live, "#examples-instances li", "Korean War")
    assert has_element?(live, "#examples-instances li", "Boer War")
    assert has_element?(live, "#examples-by-wordnet-sense")

    # Chips only: nothing is cited yet, so the card register is empty (C2).
    refute has_element?(live, "#examples [id^='examples-card']")
    refute has_element?(live, "#examples-more")
  end

  test "a chip hops to the thing's word, with the trail", ctx do
    named!(ctx, "Korean War", "oewn-korean-war-n")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

    {:error, {:live_redirect, %{to: to}}} =
      live |> element("#examples-instances a", "Korean War") |> render_click()

    assert to == "/define/korean-war?trail=war"
  end

  test "Wikidata's instances are here, a wordless one linking to its thing", ctx do
    pig_war = concept!("Q1", "Pig War")
    concept_relation!(ctx, pig_war, :instance_of, ctx.q198)
    named!(ctx, "Korean War", "oewn-korean-war-n")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

    assert live
           |> element(chip_id("inst:e#{pig_war.object_id}"))
           |> render() =~ ~s(href="/entities/#{pig_war.object_id}/pig-war")

    assert has_element?(live, "#examples-by-wikidata-entity")

    # Two sources, so each chip carries its source's badge.
    assert has_element?(live, "#examples-instances a span.sr-only", "Wikidata")

    # The panel no longer repeats them.
    refute has_element?(live, "#thing-examples")
  end

  test "past the cap, the rest fold behind a disclosure that counts them", ctx do
    for i <- 1..15, do: named!(ctx, "War #{i}", "oewn-war-#{i}-n")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/war")

    assert live |> element("#examples-instances") |> render() |> count_chips() == 12
    assert has_element?(live, "#examples-more summary", "3")
    assert live |> element("#examples-rest") |> render() |> count_chips() == 3
  end

  test "a word nothing names has no section", ctx do
    word!(ctx, "coward", ~w(wordnet))

    {:ok, live, _html} = live(ctx.conn, ~p"/define/coward")

    refute has_element?(live, "#examples")
  end

  defp count_chips(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("li") |> Enum.count()
  end
end
