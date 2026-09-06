defmodule DevilsDictionaryWeb.HealthLiveTest do
  @moduledoc """
  The health page — scorecard row **O4**. Its claim is that it renders what
  `mix dd.score` and `mix dd.health` print, so the tests compare it with those
  functions rather than with hard-coded numbers.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Health.Score

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  test "the scorecard is Score.rows/1, row for row", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/health")

    rows = Score.rows(scope: "animals", skip_parity: true)
    summary = Score.summary(rows)

    assert html =~ ~s(id="scorecard")
    assert html =~ "#{summary.passed} / #{summary.graded} graded rows pass"

    for row <- rows do
      assert html =~ ~s(id="score-row-#{row.id}")
    end
  end

  test "a pending row shows which session owes it", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/health")

    # U2, U3 and U6 are #71's; E1–E3 are S5's. The table says so rather than
    # showing a blank.
    assert html =~ ~s(id="score-row-U2")
    assert html =~ ~s(id="score-row-E1")
    assert html =~ "S5"
  end

  test "the detail sections arrive asynchronously, and the scorecard does not wait", ctx do
    {:ok, live, html} = live(ctx.conn, ~p"/health")

    assert html =~ ~s(id="scorecard")
    assert html =~ ~s(id="health-loading")

    settled = render_async(live)
    refute settled =~ ~s(id="health-loading")

    for section <- ~w(health-coverage health-resolution health-links health-dead) do
      assert settled =~ ~s(id="#{section}")
    end
  end

  test "parity is a button per source, not a page load", ctx do
    {:ok, live, html} = live(ctx.conn, ~p"/health")

    assert html =~ ~s(id="health-parity")
    assert html =~ "not checked"
    assert html =~ "Not loaded on arrival"

    for slug <- ~w(wordnet wiktionary wikidata wikipedia bierce) do
      assert html =~ ~s(id="parity-#{slug}")
    end

    live |> element(~s(button[phx-value-source="bierce"])) |> render_click()

    # An empty database has no records, so the answer is 0 gaps over 0 records.
    assert render_async(live) =~ "0 gaps over 0 records"
  end

  test "the sources link through to their own pages", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/health")

    assert render_async(live) =~ ~p"/sources/bierce"
    assert ctx.sources["bierce"].slug == "bierce"
  end
end
