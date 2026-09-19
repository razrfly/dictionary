defmodule DevilsDictionaryWeb.CultureMoreLiveTest do
  @moduledoc """
  The shelf's one *Load more*, driven through the LiveView.

  D3 of #126 replaced four per-source controls with one per shelf, and #127's
  report named the gap it left: the component test asserts the control's
  markup and the demoted shelf's arithmetic, and nothing drove the event. So
  the only evidence that clicking it fetches a page and puts the page on the
  rail was a browser run — which is not a thing a suite can keep.

  `FakeOffsetDiscoveryProvider` is the fixture for it: a plain GET on an
  offset cursor, a `:text` shelf, and five rows against a `result_limit` of
  three, which is two pages with different ids in them.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Discovery.Run
  alias DevilsDictionary.FakeOffsetDiscoveryProvider
  alias DevilsDictionary.Repo

  setup %{conn: conn} do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()

    original = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [FakeOffsetDiscoveryProvider])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, original) end)

    Map.merge(catalog, %{conn: conn})
  end

  test "one click on the shelf's Load more fetches the next page and puts it on the rail", ctx do
    stub_pages()
    word = word!(ctx, "elegy", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a lament for the dead")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/elegy")

    run_all!()
    _ = render(live)

    # Page one: three rows, the whole of a `result_limit` page.
    for id <- 1..3, do: assert(has_element?(live, "#culture-result-fixture_text-#{id}"))
    refute has_element?(live, "#culture-result-fixture_text-4")

    # One control for the shelf, naming the states it advances (D3).
    assert has_element?(
             live,
             ~s(#culture-more-text[phx-value-providers="offset-fixture"])
           )

    live |> element("#culture-more-text") |> render_click()
    run_all!()
    _ = render(live)

    # The second page's ids are on the rail beside the first page's, which is
    # the whole point of the control: a *Load more* that cannot move a count
    # is the defect Openverse had on the Images shelf (#126 Phase 2, #128).
    for id <- 1..5, do: assert(has_element?(live, "#culture-result-fixture_text-#{id}"))

    assert Repo.aggregate(Run, :count) == 2
    assert [0, 1] == Run |> Repo.all() |> Enum.map(& &1.page) |> Enum.sort()
  end

  test "the control is gone once the source has no page left", ctx do
    stub_pages()
    word = word!(ctx, "elegy", ~w(wordnet))
    sense!(ctx, word, "wordnet", gloss: "a lament for the dead")

    {:ok, live, _html} = live(ctx.conn, ~p"/define/elegy")
    run_all!()
    _ = render(live)

    live |> element("#culture-more-text") |> render_click()
    run_all!()
    _ = render(live)

    # Page two was short — two rows against a window of three — so the
    # provider ended pagination and the shelf has nothing more to offer.
    refute has_element?(live, "#culture-more-text")
  end

  # Five rows, windowed by the offset and limit the provider computes, so the
  # second page is genuinely the second page and not the first one again.
  defp stub_pages do
    rows = Enum.map(1..5, fn id -> %{"id" => id, "title" => "Elegy #{id}", "year" => "1751"} end)

    Req.Test.stub(CineGraph, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      offset = String.to_integer(conn.params["offset"])
      limit = String.to_integer(conn.params["limit"])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(Enum.slice(rows, offset, limit)))
    end)
  end

  defp run_all! do
    for run <- Repo.all(Run), run.status in [:pending, :running] do
      assert :ok = Discovery.execute_run(run.id)
    end
  end
end
