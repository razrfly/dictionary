defmodule DevilsDictionaryWeb.SitemapControllerTest do
  @moduledoc """
  The sitemap index and the sitemaps (#237 C5): valid XML listing exactly
  the published canonical pages, at the published host, with a `lastmod`
  each; cached per publication receipt and per route change, so a publish,
  a withdrawal, a move or a retirement changes them at once; with the switch
  off (D5), an empty index with `noindex`, and the same answers once it is
  on again. The split at Google's limits is unit-tested in `SitemapsTest`.

  Voltaire, Candide and the rest are CI fixtures made in this test's
  sandbox.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, published!: 1]
  import DevilsDictionary.WordFixtures, only: [entry!: 4]
  import Ecto.Query

  alias DevilsDictionary.{Fixtures, Repo}
  alias DevilsDictionary.Routing.{Address, Ledger, Page, PublicPath, PublicRouting, Sitemaps}

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{conn: conn, sources: sources, human: human!()}
  end

  defp switch(on?, fun) do
    previous = Application.get_env(:devils_dictionary, :public_routing)
    Application.put_env(:devils_dictionary, :public_routing, on?)

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, :public_routing, previous)
    end
  end

  # Four published canonicals (one moved, one an edition, one non-ASCII), a
  # draft, a withdrawn page, a retired page and a published overview: only
  # the first four belong in a sitemap.
  defp world!(ctx) do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        description: "French writer",
        path: "/people/voltaire",
        published: true,
        actor: ctx.human
      )

    entry!(ctx, voltaire.entity, "wikipedia", body: "Voltaire was a writer. He wrote much.")

    moved =
      subject!("Candide", "works",
        kind: :work,
        path: "/works/candide-1759",
        published: true,
        actor: ctx.human
      )

    {:ok, _} =
      Ledger.move(moved.page.id, "/works/candide", actor_id: ctx.human.id, reason: "fixture")

    edition =
      subject!("Candide (1759)", "works",
        kind: :edition,
        path: "/works/candide-first-edition",
        published: true,
        actor: ctx.human
      )

    chekhov =
      subject!("Чехов", "people",
        kind: :person,
        path: "/people/чехов",
        published: true,
        actor: ctx.human
      )

    draft = subject!("Arouet", "people", kind: :person, path: "/people/arouet")

    gone =
      subject!("Zadig", "works",
        kind: :work,
        path: "/works/zadig",
        published: true,
        actor: ctx.human
      )

    withdrawn!(gone.page)

    retired =
      subject!("Micromégas", "works",
        kind: :work,
        path: "/works/micromegas",
        published: true,
        actor: ctx.human
      )

    {:ok, _} = Ledger.retire(retired.page.id, actor_id: ctx.human.id, reason: "fixture")

    overview!("On Voltaire", "/on/voltaire", [], author: ctx.human, published: true)

    %{
      voltaire: voltaire,
      moved: moved,
      edition: edition,
      chekhov: chekhov,
      draft: draft,
      gone: gone,
      retired: retired
    }
  end

  # The published canonicals, read from the ledger itself.
  defp published_canonicals do
    Repo.all(
      from p in Page,
        join: c in PublicPath,
        on: c.id == p.canonical_path_id,
        where:
          p.publication_state == :published and p.lifecycle_state == :active and
            p.role in [:subject, :edition],
        select: c.path
    )
    |> Enum.sort()
  end

  defp locs(xml), do: Regex.scan(~r{<loc>([^<]+)</loc>}, xml) |> Enum.map(fn [_, loc] -> loc end)

  defp well_formed!(xml) do
    {_document, ~c""} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    xml
  end

  defp index(conn) do
    response = get(conn, "/sitemap.xml")
    assert response.status == 200
    assert hd(get_resp_header(response, "content-type")) =~ "application/xml"
    assert get_resp_header(response, "x-robots-tag") == ["noindex"]
    response.resp_body |> well_formed!() |> locs()
  end

  # Every URL the index reaches, in order.
  defp urls(conn) do
    Enum.flat_map(index(conn), fn loc ->
      response = get(conn, URI.parse(loc).path)
      assert response.status == 200
      assert get_resp_header(response, "x-robots-tag") == ["noindex"]
      response.resp_body |> well_formed!() |> locs()
    end)
  end

  defp absolute(path), do: PublicRouting.origin() <> Address.encode(path)

  test "the index names the sitemaps, and they hold exactly the published canonicals", ctx do
    world!(ctx)
    expected = published_canonicals()

    assert expected ==
             Enum.sort([
               "/people/voltaire",
               "/people/чехов",
               "/works/candide",
               "/works/candide-first-edition"
             ])

    assert index(ctx.conn) == [PublicRouting.origin() <> "/sitemaps/subjects-1.xml"]
    assert Sitemaps.names() == ["subjects-1.xml"]

    sitemap = get(ctx.conn, "/sitemaps/subjects-1.xml")
    assert sitemap.status == 200
    assert hd(get_resp_header(sitemap, "content-type")) =~ "application/xml"
    xml = well_formed!(sitemap.resp_body)
    assert xml =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)

    assert locs(xml) == Enum.map(expected, &absolute/1)

    assert absolute("/people/чехов") ==
             PublicRouting.origin() <> "/people/%D1%87%D0%B5%D1%85%D0%BE%D0%B2"

    assert Enum.map(Sitemaps.entries(), & &1.path) == expected

    # Every URL carries a W3C lastmod, and the index carries the newest.
    assert length(Regex.scan(~r|<lastmod>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z</lastmod>|, xml)) ==
             4

    assert get(ctx.conn, "/sitemap.xml").resp_body =~ ~r|<lastmod>\d{4}-\d{2}-\d{2}T|

    # Nothing else is a sitemap.
    assert get(ctx.conn, "/sitemaps/subjects-2.xml").status == 404
    assert get(ctx.conn, "/sitemaps/lexical-1.xml").status == 404
    assert get(ctx.conn, "/sitemaps/subjects.xml").status == 404
  end

  test "the published host is the origin of every URL", ctx do
    world!(ctx)

    previous = Application.get_env(:devils_dictionary, :published_host)
    Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")

    try do
      assert index(ctx.conn) == ["https://wordhoard.test/sitemaps/subjects-1.xml"]
      assert "https://wordhoard.test/people/voltaire" in urls(ctx.conn)
    after
      if is_nil(previous),
        do: Application.delete_env(:devils_dictionary, :published_host),
        else: Application.put_env(:devils_dictionary, :published_host, previous)
    end
  end

  test "a publish, a withdrawal, a move and a retirement change the sitemap at once", ctx do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        path: "/people/voltaire",
        published: true,
        actor: ctx.human
      )

    assert urls(ctx.conn) == [absolute("/people/voltaire")]

    # A draft changes nothing.
    candide = subject!("Candide", "works", kind: :work, path: "/works/candide", actor: ctx.human)
    assert urls(ctx.conn) == [absolute("/people/voltaire")]

    published!(candide.page)
    assert urls(ctx.conn) == [absolute("/people/voltaire"), absolute("/works/candide")]

    withdrawn!(candide.page)
    assert urls(ctx.conn) == [absolute("/people/voltaire")]

    {:ok, _} =
      Ledger.move(voltaire.page.id, "/people/arouet", actor_id: ctx.human.id, reason: "fixture")

    assert urls(ctx.conn) == [absolute("/people/arouet")]

    {:ok, _} = Ledger.retire(voltaire.page.id, actor_id: ctx.human.id, reason: "fixture")
    assert urls(ctx.conn) == []
    assert index(ctx.conn) == []
    assert Sitemaps.names() == []
  end

  test "off: an empty index with noindex and no sitemap; on again, the same answers", ctx do
    world!(ctx)
    before = urls(ctx.conn)
    assert length(before) == 4

    switch(false, fn ->
      refute PublicRouting.enabled?()
      assert index(ctx.conn) == []
      assert Sitemaps.entries() == []
      assert Sitemaps.names() == []

      response = get(ctx.conn, "/sitemap.xml")
      assert well_formed!(response.resp_body) =~ "<sitemapindex"
      assert get_resp_header(response, "x-robots-tag") == ["noindex"]
      assert get(ctx.conn, "/sitemaps/subjects-1.xml").status == 404
    end)

    assert urls(ctx.conn) == before
  end
end
