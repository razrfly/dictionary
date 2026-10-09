defmodule DevilsDictionaryWeb.WordWithoutConceptTest do
  @moduledoc """
  A word that may refer to something but names no concept of its own: its
  thing panel has candidates and no concept (`WordPage`'s `empty_thing/0`),
  and its pages render without the one-line answer instead of failing.
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

    if page.thing, do: assert(is_nil(page.thing.concept))

    for path <- ["/words/#{word.object_id}/seal", "/on/seal"] do
      assert ctx.conn |> get(path) |> html_response(200), path
    end
  end

  test "a concept with no Wikidata item opens its provenance drawer, not a 500", ctx do
    word = word!(ctx, "quoll", ~w(wordnet))
    link!(word, concept!(nil, "quoll", description: "a marsupial"), confidence: 0.95)

    for path <- ["/words/#{word.object_id}/quoll", "/on/quoll"] do
      assert ctx.conn |> get(path <> "?provenance=thing") |> html_response(200), path
      {:ok, view, _html} = live(ctx.conn, path)
      assert render_patch(view, path <> "?provenance=thing")
    end
  end
end
