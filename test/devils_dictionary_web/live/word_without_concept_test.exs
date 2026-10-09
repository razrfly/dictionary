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
      assert {:ok, _view, _html} = live(ctx.conn, path)
    end
  end
end
