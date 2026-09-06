defmodule DevilsDictionaryWeb.Admin.ImportsLiveTest do
  @moduledoc """
  The import dashboard. Its whole claim is that it prints what `mix dd.health`
  prints, so that is what the tests check — plus the one button that has a
  worker behind it.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Health, Repo}
  alias DevilsDictionary.Sources.SourceRecord
  alias DevilsDictionary.Workers.AbsorbWorker

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  defp record!(source, external_id, attrs \\ []) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %SourceRecord{
          source_id: source.id,
          external_id: external_id,
          raw: %{},
          content_hash: external_id,
          fetched_at: now,
          materialized_at: now
        },
        attrs
      )
    )
  end

  test "a row per source, with the ledger's numbers", ctx do
    record!(ctx.sources["bierce"], "CAT/n")
    record!(ctx.sources["bierce"], "DOG/n", materialized_at: nil)

    {:ok, _live, html} = live(ctx.conn, ~p"/admin/imports")

    assert html =~ ~s(id="imports-rows")

    for source <- ~w(wordnet wiktionary wikidata wikipedia bierce) do
      assert html =~ source
    end

    # 2 records, 1 of them unmaterialized — the same figures Health.records/1
    # hands mix dd.health.
    ledger = Enum.find(Health.records("animals"), &(&1.slug == "bierce"))
    assert ledger.records == 2
    assert ledger.needs_materialization == 1
    assert html =~ "needs mat."
  end

  test "a dump's needs-fetch is an em dash, not a zero", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/admin/imports")

    assert html =~ "a dump is the answer"
    assert html =~ "wikidata: asserted concepts"
    assert html =~ "wikipedia: scope lemmas"
    assert ctx.sources["wordnet"].access == :dump
  end

  test "the health summary is on the page, and parity is not", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/admin/imports")

    assert html =~ ~s(id="health-summary")
    assert html =~ "unresolved Wiktionary relation targets"
    # M1 belongs on the health page, behind a button: it re-runs materialize/1.
    assert html =~ "Parity (M1) is not on this page"
  end

  test "the commands that have no worker are printed, not offered as buttons", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/admin/imports")

    assert html =~ "mix dd.resolve"
    assert html =~ "mix dd.link --scope animals"
    assert html =~ "mix dd.materialize --source &lt;slug&gt; --all"
    assert html =~ "mix dd.score --scope animals"
  end

  test "absorb is the one button, and it enqueues the worker that exists", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/admin/imports")

    html =
      live
      |> element(~s(button[phx-value-source="wikipedia"]))
      |> render_click()

    assert html =~ "Queued absorb of wikipedia"

    # An API source carries the scope; a dump does not need one. Oban is in
    # `testing: :manual`, so the job is enqueued and never executed.
    assert [job] = Repo.all(Oban.Job)
    assert job.worker == inspect(AbsorbWorker)
    assert job.queue == "absorb"
    assert job.args == %{"source" => "wikipedia", "scope" => "animals"}
  end

  test "refresh re-reads without navigating", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/admin/imports")

    before = render(live)
    record!(ctx.sources["bierce"], "CAT/n")

    assert live |> element("button", "Refresh") |> render_click() != before
  end
end
