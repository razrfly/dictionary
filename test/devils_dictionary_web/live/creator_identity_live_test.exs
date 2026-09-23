defmodule DevilsDictionaryWeb.CreatorIdentityLiveTest do
  @moduledoc """
  #164 on the pages a reader and an operator open: the person page's
  quotations and misattributed populations, a resolved quotation's evidence
  page, and the creator counts on `/ops/discovery`. The rows are written by a
  real run of `FakeQuoteDiscoveryProvider` over the #158 fixture.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Conformance, Result}
  alias DevilsDictionary.FakeQuoteDiscoveryProvider, as: Quotes
  alias DevilsDictionary.Registry

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [Quotes])

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Quotes.clear_rows()
    end)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(fn
          "Q9068" = qid ->
            {qid,
             Conformance.human(qid, "Voltaire",
               born: ~D[1694-11-21],
               died: ~D[1778-05-30],
               description: "French Enlightenment writer, historian and philosopher"
             )}

          qid ->
            {qid, Conformance.human(qid, qid)}
        end)

      Req.Test.json(conn, %{"entities" => entities})
    end)

    ctx = %{sources: catalog.sources}

    Quotes.put_rows(
      "garden",
      Quotes.rows(~w(voltaire-candide-garden voltaire-misattributed-defend))
    )

    word = word!(ctx, "garden", ~w(wordnet))

    {:queued, run} =
      Discovery.request(
        %{object_id: word.object_id, term: "garden", language: "en", relevance: "term"},
        "quote-fixture"
      )

    :ok = Discovery.execute_run(run.id)

    results =
      DevilsDictionary.Repo.all(from r in Result, where: r.run_id == ^run.id)
      |> Map.new(&{&1.external_id, &1})

    Map.merge(ctx, %{
      voltaire_id: Registry.by_external_id("wikidata", "Q9068"),
      garden: results["voltaire-candide-garden"],
      defend: results["voltaire-misattributed-defend"]
    })
  end

  test "the person page lists the line under quotations, and the register row apart", ctx do
    {:ok, view, html} = live(ctx.conn, ~p"/entities/#{ctx.voltaire_id}/voltaire")

    assert html =~ "Voltaire"
    assert html =~ "1694"

    assert has_element?(view, "#entity-quotations #quotation-#{ctx.garden.object_id}")
    assert render(element(view, "#quotation-#{ctx.garden.object_id}")) =~ "cultivate our garden"
    assert render(element(view, "#quotation-#{ctx.garden.object_id}")) =~ "Quote fixture"
    refute has_element?(view, "#entity-quotations #quotation-#{ctx.defend.object_id}")

    assert has_element?(view, "#entity-misattributed #misattributed-#{ctx.defend.object_id}")
    refute has_element?(view, "#entity-definitions")

    revision = Registry.current_content_revision(ctx.garden.object_id)

    assert has_element?(
             view,
             ~s(#quotation-evidence-#{ctx.garden.object_id}[href="/evidence/content/#{revision.id}"])
           )
  end

  test "a resolved quotation's evidence page renders its text", ctx do
    revision = Registry.current_content_revision(ctx.garden.object_id)
    {:ok, _view, html} = live(ctx.conn, ~p"/evidence/content/#{revision.id}")

    assert html =~ "We must cultivate our garden."
    assert html =~ "Quote fixture"
  end

  test "/ops/discovery counts what creator identity did", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/ops/discovery")

    assert has_element?(view, "#discovery-creators")
    row = render(element(view, "#creators-quote-fixture"))
    # One minted credit (the Voltaire line) and one minted misattribution
    # target is the same person — minted once, matched the second time.
    assert row =~ "quote-fixture"
    assert render(element(view, "#discovery-creators")) =~ "people and organizations minted"
    _ = ctx
  end
end
