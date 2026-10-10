defmodule DevilsDictionaryWeb.PublishedHostLinksTest do
  @moduledoc """
  What a visitor through the published host reads (#250, which undid #237
  D2's link hiding): every subject a page names is linked, the way #219
  built it — at its address when the public is served one, and otherwise at
  its exact identity, `/entities/:id/:slug`, which reads every entity.

    * a published subject page links a published work at its address, and
      a draft work, a work with no page and a connection's other end at
      their exact identities, each of which answers 200 through the tunnel;
    * an On page's Subjects cards and authors, and the home search, the same;
    * `/entities/:id/:slug` reads a draft's entity, and an identity merged
      into a draft, through the tunnel too; the draft's own family address
      stays 404 there, as routing has it;
    * `Links` falls back to the exact identity on the published host as on
      any other server, publicly and internally.

  Every request here is made as through the tunnel (`X-Forwarded-For`): on
  the published host, a request from the machine itself reads internally
  (`ReadingMode`). Voltaire and the rest are CI fixtures made in this test's
  sandbox.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  @moduletag :capture_log

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0]
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Claims, CurationFixtures, Fixtures, Registry}
  alias DevilsDictionary.Routing.Links

  @host "wordhoard.test"

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{conn: conn, sources: sources, human: human!()}
  end

  defp with_env(key, value, fun) do
    previous = Application.get_env(:devils_dictionary, key)
    Application.put_env(:devils_dictionary, key, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Application.delete_env(:devils_dictionary, key),
        else: Application.put_env(:devils_dictionary, key, previous)
    end
  end

  defp published_host(fun), do: with_env(:published_host, @host, fun)

  defp tunnel(conn), do: put_req_header(conn, "x-forwarded-for", "203.0.113.7")

  # Voltaire, published, and what his page names: Zadig, published; Candide,
  # allocated and still a draft; Micromégas, a work with no page; and the
  # Lisbon earthquake, an event with no page, at the other end of a
  # connection. Arouet is a draft person, the author of a definition of the
  # word Voltaire, and the opera a draft subject that shares his name.
  defp world!(ctx) do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        description: "French writer",
        path: "/people/voltaire",
        published: true,
        actor: ctx.human
      )

    zadig =
      subject!("Zadig", "works",
        kind: :work,
        work_kind: "book",
        description: "1747 novel",
        path: "/works/zadig",
        published: true,
        actor: ctx.human
      )

    candide =
      subject!("Candide", "works",
        kind: :work,
        work_kind: "book",
        description: "1759 novella",
        path: "/works/candide",
        actor: ctx.human
      )

    {:ok, micromegas} = Registry.create_work(%{preferred_label: "Micromegas", work_kind: "book"})

    {:ok, lisbon} =
      Registry.create_entity(%{entity_kind: :event, preferred_label: "Lisbon earthquake"})

    for work <- [zadig.entity, candide.entity, micromegas] do
      {:ok, _} = Claims.assert(work.object_id, "authored_by", voltaire.entity.object_id)
    end

    {:ok, _} = Claims.assert(voltaire.entity.object_id, "participates_in", lisbon.object_id)

    arouet =
      subject!("Arouet", "people",
        kind: :person,
        description: "a draft",
        path: "/people/arouet",
        actor: ctx.human
      )

    opera =
      subject!("Voltaire", "works",
        kind: :work,
        description: "an opera, a draft",
        path: "/works/voltaire",
        actor: ctx.human
      )

    word = word!(ctx, "Voltaire", ~w(wiktionary bierce))
    sense!(ctx, word, "wiktionary", gloss: "A French writer of the Enlightenment.")
    entry!(ctx, word, "bierce", author: arouet.entity, body: "A wit, by his own account.")

    %{
      voltaire: voltaire.entity,
      zadig: zadig.entity,
      candide: candide.entity,
      micromegas: micromegas,
      lisbon: lisbon,
      arouet: arouet.entity,
      opera: opera.entity
    }
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp links_in(doc, selector),
    do: doc |> LazyHTML.query(selector <> " a") |> LazyHTML.attribute("href")

  defp href(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  # Every `/entities/` link on a page answers 200 through the tunnel: a link
  # the page gives is a page the visitor can read.
  defp entity_links_read!(conn, html) do
    links =
      ~r/\shref="(\/entities\/[^"?#]*)/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    for link <- links do
      assert (conn |> tunnel() |> get(link)).status == 200, "#{link} does not read"
    end

    refute html =~ ~s(href="#")
    links
  end

  test "a published subject page links every subject it names: at its address, or at its exact identity",
       ctx do
    world = world!(ctx)
    candide = Links.entity_path(world.candide.object_id, "Candide")
    micromegas = Links.entity_path(world.micromegas.object_id, "Micromegas")
    lisbon = Links.entity_path(world.lisbon.object_id, "Lisbon earthquake")

    published_host(fn ->
      html = ctx.conn |> tunnel() |> get("/people/voltaire") |> html_response(200)
      doc = doc(html)

      # Works authored: Zadig at its address; Candide (a draft) and
      # Micromegas (no page) at their exact identities.
      assert links_in(doc, "#work-#{world.zadig.object_id}") == ["/works/zadig"]
      assert links_in(doc, "#work-#{world.candide.object_id}") == [candide]
      assert links_in(doc, "#work-#{world.micromegas.object_id}") == [micromegas]

      # Other connections: the Lisbon earthquake at its exact identity.
      assert lisbon in links_in(doc, "#entity-connections")

      # And every one of them reads.
      read = entity_links_read!(ctx.conn, html)
      assert Enum.all?([candide, micromegas, lisbon], &(&1 in read))

      # The connected render says the same.
      {:ok, view, _html} = ctx.conn |> tunnel() |> live("/people/voltaire")
      assert has_element?(view, "#work-#{world.candide.object_id} a[href='#{candide}']")
      assert has_element?(view, "#work-#{world.zadig.object_id} a[href='/works/zadig']")
      refute has_element?(view, "#subject-draft")
    end)
  end

  test "an On page links its subjects and authors, a draft's at its exact identity", ctx do
    world = world!(ctx)

    published_host(fn ->
      html = ctx.conn |> tunnel() |> get("/on/voltaire") |> html_response(200)
      doc = doc(html)

      # The Subjects section: the published person at his address, the draft
      # opera that shares his name at its exact identity.
      assert href(doc, "a#subject-discovered-#{world.voltaire.object_id}-link") ==
               ["/people/voltaire"]

      assert href(doc, "a#subject-discovered-#{world.opera.object_id}-link") ==
               [Links.entity_path(world.opera.object_id, "Voltaire")]

      # The definition's author, a draft person, linked at his identity.
      assert html =~ ~s(href="#{Links.entity_path(world.arouet.object_id, "Arouet")}")

      entity_links_read!(ctx.conn, html)
    end)
  end

  test "the home search links every subject it finds", ctx do
    world = world!(ctx)

    published_host(fn ->
      html = ctx.conn |> tunnel() |> get("/?q=voltaire") |> html_response(200)
      doc = doc(html)

      assert href(doc, "a#result-entity-#{world.voltaire.object_id}") == ["/people/voltaire"]

      assert href(doc, "a#result-entity-#{world.opera.object_id}") ==
               [Links.entity_path(world.opera.object_id, "Voltaire")]

      entity_links_read!(ctx.conn, html)
    end)
  end

  test "the exact-identity route reads a draft's entity through the tunnel; the draft's address stays 404",
       ctx do
    world = world!(ctx)
    candide = "/entities/#{world.candide.object_id}/candide"

    published_host(fn ->
      conn = tunnel(ctx.conn)

      assert conn |> get(candide) |> html_response(200) =~ "1759 novella"
      assert conn |> get("/works/candide") |> html_response(404)

      # Live navigation decides the same, in the LiveView.
      {:ok, view, _html} = live(conn, "/entities/#{world.voltaire.object_id}/voltaire")
      render_patch(view, candide)
      assert render(view) =~ "1759 novella"

      # A reviewer reads internally through the tunnel, the address included.
      reviewer = CurationFixtures.account([:reviewer])
      assert conn |> log_in_user(reviewer.user) |> get("/works/candide") |> html_response(200)
    end)
  end

  test "an identity merged into a draft reads at its retired id, as the survivor", ctx do
    world = world!(ctx)

    {:ok, into_draft} = Registry.create_work(%{preferred_label: "Candide ou l'optimisme"})

    {:ok, _} =
      Registry.merge([into_draft.object_id], world.candide.object_id, reason: "duplicate")

    published_host(fn ->
      conn =
        ctx.conn |> tunnel() |> get("/entities/#{into_draft.object_id}/candide-ou-l-optimisme")

      assert conn.status in [200, 302]
    end)
  end

  test "Links falls back to the exact identity on the published host as anywhere, publicly and internally",
       ctx do
    world = world!(ctx)
    candide = Links.entity_path(world.candide.object_id, "Candide")
    micromegas = Links.entity_path(world.micromegas.object_id, "Micromegas")

    for host <- [nil, @host] do
      with_env(:published_host, host, fn ->
        assert Links.path(world.zadig.object_id, "Zadig", :public) == "/works/zadig"
        assert Links.path(world.candide.object_id, "Candide", :public) == candide
        assert Links.path(world.micromegas.object_id, "Micromegas", :public) == micromegas

        assert Links.paths(
                 [{world.zadig.object_id, "Zadig"}, {world.micromegas.object_id, "Micromegas"}],
                 :public
               ) == %{
                 world.zadig.object_id => "/works/zadig",
                 world.micromegas.object_id => micromegas
               }

        # Internally the draft is at its address, the rest at its identity.
        assert Links.path(world.candide.object_id, "Candide", :internal) == "/works/candide"
        assert Links.path(world.micromegas.object_id, "Micromegas", :internal) == micromegas
      end)
    end
  end
end
