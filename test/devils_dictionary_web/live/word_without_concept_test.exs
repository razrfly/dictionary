defmodule DevilsDictionaryWeb.WordWithoutConceptTest do
  @moduledoc """
  A word that may refer to something but names no concept of its own: its
  thing panel has no concept (`WordPage`'s `empty_thing/0`) when its only
  links are candidates, or when its senses name two or more things and none
  at or above the floor; and a concept with no Wikidata item. Its pages
  render without the one-line answer and open the thing's drawer, instead of
  failing; a query parameter shaped as a list or a map is ignored.
  Found by #237's crawl of the published host, where 22 exact-word pages a
  published subject links answered 500.
  """
  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    Map.put(ctx, :sources, sources)
  end

  test "an exact word and its On page render with a candidate and no concept", ctx do
    word = word!(ctx, "oyster", ~w(wordnet))
    maybe = concept!("Q4", "Oyster bar")
    link!(word, maybe, confidence: 0.4, method: :disambiguation, status: :candidate)

    page =
      word
      |> Map.get(:lemma)
      |> DevilsDictionary.Lexicon.lookup()
      |> DevilsDictionary.Lexicon.WordPage.build()

    assert %{concept: nil, may_refer_to: [_ | _]} = page.thing

    for path <- ["/words/#{word.object_id}/oyster", "/on/oyster"] do
      html = ctx.conn |> get(path) |> html_response(200)
      refute html =~ ~s(id="quick-definition"), path
      assert html =~ ~s(id="may-refer-to"), path
      assert {:ok, view, _html} = live(ctx.conn, path)
      assert has_element?(view, "#may-refer-to")
      refute has_element?(view, "#quick-definition")
    end
  end

  test "two asserted senses below the floor are a disagreement with no concept, and render",
       ctx do
    word = word!(ctx, "seal", ~w(wordnet))

    for {qid, label} <- [{"Q5", "Seal (animal)"}, {"Q6", "Seal (emblem)"}] do
      link!(word, concept!(qid, label), confidence: 0.6, method: :wiktionary_qid)
    end

    page =
      word
      |> Map.get(:lemma)
      |> DevilsDictionary.Lexicon.lookup()
      |> DevilsDictionary.Lexicon.WordPage.build()

    assert %{concept: nil, may_refer_to: [], disagreement: [_, _]} = page.thing

    for path <- ["/words/#{word.object_id}/seal", "/on/seal"] do
      refute ctx.conn |> get(path) |> html_response(200) =~ ~s(id="quick-definition"), path
      {:ok, view, _html} = live(ctx.conn, path)
      refute has_element?(view, "#quick-definition")
    end
  end

  test "a concept with no Wikidata item opens its provenance drawer, not a 500", ctx do
    word = word!(ctx, "quoll", ~w(wordnet))
    link!(word, concept!(nil, "quoll", description: "a marsupial"), confidence: 0.95)

    for path <- ["/words/#{word.object_id}/quoll", "/on/quoll"] do
      html = ctx.conn |> get(path <> "?provenance=thing") |> html_response(200)
      assert html =~ ~s(id="provenance-panel"), path
      {:ok, view, _html} = live(ctx.conn, path)
      assert render_patch(view, path <> "?provenance=thing") =~ ~s(id="provenance-panel")
    end
  end

  test "a query parameter shaped as a list or a map is ignored, not a 500", ctx do
    word = word!(ctx, "quoll", ~w(wordnet))
    link!(word, concept!("Q7", "quoll", description: "a marsupial"), confidence: 0.95)

    for path <- ["/words/#{word.object_id}/quoll", "/on/quoll"],
        query <- ["?provenance[]=thing", "?provenance[a]=thing", "?trail[]=cat", "?trail[a]=cat"] do
      assert ctx.conn |> get(path <> query) |> html_response(200), path <> query
    end
  end
end
