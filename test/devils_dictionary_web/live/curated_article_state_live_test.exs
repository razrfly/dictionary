defmodule DevilsDictionaryWeb.CuratedArticleStateLiveTest do
  @moduledoc """
  The curated page's states that need an editor run (#309 D4, review R1):
  an abstention is read from the attempt that made it, by the editor that
  made it, even after the next check has been admitted.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.Refresh

  setup ctx do
    world = editor_world!(ctx, publish: false)
    stub_answer!(world, abstain())
    assert {:ok, %{last_outcome: :abstained}} = run!(world)
    Map.put(ctx, :world, world)
  end

  test "abstained: the editor's own stored reason, and no persona it does not have", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-state[data-state='abstained']")
    assert has_element?(view, "#curated-state-assessed", "The AI editor last assessed it on")
    assert has_element?(view, "#curated-state-assessed", "and chose not to select:")
    assert has_element?(view, "#curated-state-reason", "“Nothing fits.”")
    refute has_element?(view, "#curated-state-assessed", "inspired by")
    refute has_element?(view, "#curated-state-reason", "cut at")
  end

  test "the next check's admission does not lose the last assessment's reason", ctx do
    # A new generation is admitted (as a visit after `refresh_after` would);
    # the last completed run is still the abstention.
    assert {:ok, :admitted} =
             Refresh.request(ctx.world.reviewer, ctx.world.composition.id, "love", "#309 test")

    {:ok, view, _} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#curated-state[data-state='abstained']")
    assert has_element?(view, "#curated-state-reason", "“Nothing fits.”")
    refute has_element?(view, "#curated-state-assessed", "gave no reason")
  end
end
