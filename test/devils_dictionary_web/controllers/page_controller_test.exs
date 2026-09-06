defmodule DevilsDictionaryWeb.PageControllerTest do
  use DevilsDictionaryWeb.ConnCase, async: true

  test "the home page indexes the developer surfaces", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Every word. Every source. One page."
    assert html =~ ~p"/s/animals"
    assert html =~ ~p"/health"
    assert html =~ ~p"/admin/imports"
  end

  test "the layout carries the theme's fonts and the wordmark", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Instrument+Serif"
    assert html =~ "family=Inter"
    assert html =~ "wordhoard"
    # A page with no title of its own gets the tagline, then the wordmark once.
    assert html =~ ">Every word, every source · wordhoard</title>"
  end
end
