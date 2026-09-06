defmodule DevilsDictionaryWeb.KitLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: true

  # U0's exit condition (#71 §8): the ported primitives render, so the port can
  # be held next to the kit's own demo. The route is compile-gated on
  # `dev_routes` in the router, so production has no such page.
  test "every ported primitive renders", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/kit")

    for id <- ~w(kit-type kit-document kit-buttons kit-stats kit-features kit-forms kit-table) do
      assert html =~ ~s(id="#{id}")
    end
  end

  test "the theme's tokens are the ones in use, not daisyUI's", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/kit")

    assert html =~ "font-display"
    assert html =~ "text-mist-950"
    refute html =~ ~r/class="[^"]*\bbtn\b/
    refute html =~ "bg-base-100"
  end
end
