defmodule DevilsDictionaryWeb.VerificationLiveTest do
  @moduledoc "#158 build 5 on `/ops/discovery`: a budget row per checker, and why the off ones are off."
  use DevilsDictionaryWeb.ConnCase, async: false

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    :ok
  end

  test "every checker has a row, a budget and a state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ops/discovery")

    assert has_element?(view, "#discovery-verification")

    for slug <- ~w(gutenberg wikisource internet-archive quote-investigator google-books) do
      assert has_element?(view, "#checker-#{slug}")
    end

    assert render(element(view, "#checker-gutenberg")) =~ "live"
    assert render(element(view, "#checker-gutenberg")) =~ "0/200"
    assert render(element(view, "#checker-google-books")) =~ "waiting for an API key"
    assert render(element(view, "#checker-quote-investigator")) =~ "permission email"
    assert render(element(view, "#checker-internet-archive")) =~ "measured out"
  end
end
