defmodule DevilsDictionaryWeb.PublishedHostLinksTest do
  @moduledoc """
  What a visitor through the published host reads (#237 D2, step 6): no
  link to the exact-identity route, no `href="#"`, no operator surface, and
  no draft at `/entities/:id/:slug` either.

    * a published subject page links a subject it names at its address when
      the public is served one, and otherwise names it as text: a draft
      work, a work with no page and a connection's other end, in three
      sections;
    * an On page's Subjects cards and authors, and the home search, the same;
    * `/entities/:id/:slug` of an entity whose page is a draft is 404 there
      to the public, on the response and in the LiveView, and 200 to a
      reviewer and on any other server; an entity with no page, or a
      published one, still reads;
    * off the published host, and in internal mode on it, `Links` falls
      back to the exact-identity route as before;
    * a crawl of every same-host link on those pages, and one link further,
      finds none of it.

  Voltaire and the rest are CI fixtures made in this test's sandbox.
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

  # ── what a page links ────────────────────────────────────────────────────

  # Every href on the page, as written.
  defp hrefs(html) do
    ~r/\shref="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  # The hrefs that stay on this host, as paths: a relative path, or an
  # absolute URL at the published host's origin. `#` is kept, to be refused.
  defp same_host(html) do
    html
    |> hrefs()
    |> Enum.flat_map(fn
      "#" -> ["#"]
      "https://" <> @host <> path -> [if(path == "", do: "/", else: path)]
      "//" <> _other -> []
      "/" <> _path = path -> [path]
      _elsewhere -> []
    end)
  end

  @forbidden ~w(/entities/ /ops /dev /kit)

  # The crawl's assertion: nothing that leads to an exact identity, an
  # operator surface, or nowhere.
  defp clean!(html, where) do
    links = same_host(html)

    for link <- links do
      refute link == "#", "#{where} links #"
      refute Enum.any?(@forbidden, &String.starts_with?(link, &1)), "#{where} links #{link}"
    end

    refute html =~ ~s(href="#"), "#{where} has an empty link"
    links
  end

  # The page, then every same-host page it links, once each: every answer
  # that is a page must be as clean.
  defp crawl!(conn, path) do
    html = conn |> get(path) |> html_response(200)

    html
    |> clean!(path)
    |> Enum.map(&(&1 |> URI.parse() |> Map.get(:path)))
    |> Enum.reject(&(is_nil(&1) or &1 == path))
    |> Enum.uniq()
    |> Enum.each(fn link ->
      response = get(conn, link)

      if response.status == 200 and
           response |> get_resp_header("content-type") |> Enum.any?(&(&1 =~ "text/html")) do
        clean!(response.resp_body, "#{link} (from #{path})")
      end
    end)

    html
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp links_in(doc, selector),
    do: doc |> LazyHTML.query(selector <> " a") |> LazyHTML.attribute("href")

  defp text_of(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  # ── tests ────────────────────────────────────────────────────────────────

  test "a published subject page links a named subject only at its served address; the rest is text",
       ctx do
    world = world!(ctx)

    published_host(fn ->
      html = crawl!(ctx.conn, "/people/voltaire")
      doc = doc(html)

      # Works authored: Zadig at its address; Candide (a draft) and
      # Micromegas (no page) by name only.
      assert links_in(doc, "#work-#{world.zadig.object_id}") == ["/works/zadig"]

      for work <- [world.candide, world.micromegas] do
        assert links_in(doc, "#work-#{work.object_id}") == []
        assert text_of(doc, "#work-#{work.object_id}") =~ work.preferred_label
      end

      # Other connections: the Lisbon earthquake by name, and the claim's
      # own page still linked.
      connections = text_of(doc, "#entity-connections")
      assert connections =~ "Lisbon earthquake"

      assert Enum.all?(
               links_in(doc, "#entity-connections"),
               &String.starts_with?(&1, "/connections/")
             )

      # No operator surface in the chrome either.
      refute html =~ ~s(href="/ops)

      # The connected render says the same.
      {:ok, view, _html} = live(ctx.conn, "/people/voltaire")
      clean!(render(view), "/people/voltaire (connected)")
      refute has_element?(view, "#work-#{world.candide.object_id} a")
      assert has_element?(view, "#work-#{world.zadig.object_id} a[href='/works/zadig']")
    end)

    # Elsewhere, the same page links them at their exact identities, as before.
    reading(false, fn ->
      html = ctx.conn |> get("/people/voltaire") |> html_response(200)
      doc = doc(html)

      assert links_in(doc, "#work-#{world.candide.object_id}") ==
               [Links.entity_path(world.candide.object_id, "Candide")]
    end)
  end

  test "an On page names unpublished subjects and authors as text", ctx do
    world = world!(ctx)

    published_host(fn ->
      html = crawl!(ctx.conn, "/on/voltaire")
      doc = doc(html)

      # The Subjects section: the published person at his address, the draft
      # opera that shares his name as text.
      assert doc
             |> LazyHTML.query("a#subject-discovered-#{world.voltaire.object_id}-link")
             |> LazyHTML.attribute("href") == ["/people/voltaire"]

      opera = "#subject-discovered-#{world.opera.object_id}-link"
      assert doc |> LazyHTML.query(opera) |> LazyHTML.tag() == ["span"]
      assert text_of(doc, opera) =~ "Voltaire"

      # The definition's author, a draft person, by name only.
      assert html =~ "Arouet"
      refute "Arouet" in (doc |> LazyHTML.query("a") |> Enum.map(&String.trim(LazyHTML.text(&1))))
    end)
  end

  test "the home search names unpublished subjects as text", ctx do
    world = world!(ctx)

    published_host(fn ->
      html = crawl!(ctx.conn, "/?q=voltaire")
      doc = doc(html)

      assert doc
             |> LazyHTML.query("a#result-entity-#{world.voltaire.object_id}")
             |> LazyHTML.attribute("href") == ["/people/voltaire"]

      opera = "#result-entity-#{world.opera.object_id}"
      assert doc |> LazyHTML.query(opera) |> LazyHTML.tag() == ["span"]
      assert text_of(doc, opera) =~ "an opera, a draft"
    end)
  end

  test "the exact-identity route of a draft's entity is 404 there to the public, 200 to a reviewer and elsewhere",
       ctx do
    world = world!(ctx)
    candide = "/entities/#{world.candide.object_id}/candide"
    voltaire = "/entities/#{world.voltaire.object_id}/voltaire"
    lisbon = Links.entity_path(world.lisbon.object_id, "Lisbon earthquake")

    published_host(fn ->
      # Direct: the plug's 404, and the LiveView's own not-found state.
      html = ctx.conn |> get(candide) |> html_response(404)
      assert html =~ ~s(id="no-such-entity")
      refute html =~ "1759 novella"

      # A wrong slug is not followed to the label either.
      assert ctx.conn |> get("/entities/#{world.candide.object_id}/x") |> html_response(404)

      # A published subject's identity, and an entity with no page, still read.
      assert ctx.conn |> get(voltaire) |> html_response(200) =~ "French writer"
      assert ctx.conn |> get(lisbon) |> html_response(200) =~ "Lisbon earthquake"

      # Live navigation decides the same, in the LiveView.
      {:ok, view, _html} = live(ctx.conn, voltaire)
      render_patch(view, candide)
      assert has_element?(view, "#no-such-entity")
      refute render(view) =~ "1759 novella"

      # A reviewer reads internally, the draft included.
      reviewer = CurationFixtures.account([:reviewer])
      conn = log_in_user(ctx.conn, reviewer.user)
      assert conn |> get(candide) |> html_response(200) =~ "1759 novella"
    end)

    # Not the published host: the route reads it, publicly too.
    reading(false, fn ->
      assert ctx.conn |> get(candide) |> html_response(200) =~ "1759 novella"
    end)
  end

  test "an identity merged into a draft is 404 at its retired id too; one merged into a published subject reads",
       ctx do
    world = world!(ctx)

    # A retired identity merged into the draft Candide, and one merged into
    # the published Zadig: neither has a page of its own, and the route
    # shows the survivor's content at the retired id.
    {:ok, into_draft} = Registry.create_work(%{preferred_label: "Candide ou l'optimisme"})
    {:ok, into_published} = Registry.create_work(%{preferred_label: "Zadig ou la destinee"})

    {:ok, _} =
      Registry.merge([into_draft.object_id], world.candide.object_id, reason: "duplicate")

    {:ok, _} =
      Registry.merge([into_published.object_id], world.zadig.object_id, reason: "duplicate")

    retired_draft = "/entities/#{into_draft.object_id}/candide-ou-l-optimisme"
    retired_published = "/entities/#{into_published.object_id}/zadig-ou-la-destinee"

    published_host(fn ->
      for path <- [retired_draft, "/entities/#{into_draft.object_id}/x"] do
        html = ctx.conn |> get(path) |> html_response(404)
        refute html =~ "1759 novella", path
      end

      assert Links.withheld?(into_draft.object_id, :public)
      refute Links.withheld?(into_published.object_id, :public)

      # Live navigation from a page the public reads, to the retired id.
      {:ok, view, _html} = live(ctx.conn, "/entities/#{world.voltaire.object_id}/voltaire")
      render_patch(view, retired_draft)
      assert has_element?(view, "#no-such-entity")
      refute render(view) =~ "1759 novella"

      # Merged into a published subject: the survivor reads at the retired id.
      conn = get(ctx.conn, retired_published)
      assert conn.status in [200, 302]

      if conn.status == 302,
        do: assert(ctx.conn |> get(redirected_to(conn)) |> html_response(200) =~ "1747 novel"),
        else: assert(html_response(conn, 200) =~ "1747 novel")
    end)

    # Not the published host: the retired id reads the survivor, as before.
    reading(false, fn ->
      conn = get(ctx.conn, retired_draft)
      assert conn.status in [200, 302]
    end)
  end

  test "a published page whose identity was merged into a draft is withheld with it, at its address and its identity",
       ctx do
    world = world!(ctx)

    # A published work, later merged in the registry into the draft Candide:
    # its own page is still served, but what it shows is the survivor's.
    retired =
      subject!("Candide (1759)", "works",
        kind: :work,
        work_kind: "book",
        description: "a retired record",
        path: "/works/candide-1759",
        published: true,
        actor: ctx.human
      )

    published_host(fn ->
      assert ctx.conn |> get("/works/candide-1759") |> html_response(200)
    end)

    {:ok, _} =
      Registry.merge([retired.entity.object_id], world.candide.object_id, reason: "duplicate")

    published_host(fn ->
      for path <- ["/works/candide-1759", "/entities/#{retired.entity.object_id}/candide-1759"] do
        html = ctx.conn |> get(path) |> html_response(404)
        refute html =~ "1759 novella", path
      end

      assert Links.withheld?(retired.entity.object_id, :public)

      # In the LiveView too, by live navigation from a page the public reads.
      {:ok, view, _html} = live(ctx.conn, "/people/voltaire")
      assert {:ok, view, _html} = view |> live_redirect(to: "/works/candide-1759")
      refute render(view) =~ "1759 novella"
    end)

    # A reviewer reads it internally, and another server publicly, as before.
    reading(false, fn ->
      assert ctx.conn |> get("/works/candide-1759") |> html_response(200) =~ "1759 novella"
    end)
  end

  test "Links falls back to the exact identity off the published host, and internally on it",
       ctx do
    world = world!(ctx)
    candide = Links.entity_path(world.candide.object_id, "Candide")
    micromegas = Links.entity_path(world.micromegas.object_id, "Micromegas")

    # Off the published host: the old behaviour, publicly and internally.
    assert Links.path(world.candide.object_id, "Candide", :public) == candide
    assert Links.path(world.micromegas.object_id, "Micromegas", :internal) == micromegas
    assert Links.fallback(world.candide.object_id, "Candide", :public) == candide
    refute Links.withheld?(world.candide.object_id, :public)

    published_host(fn ->
      # Publicly: no fallback, and the draft's identity withheld.
      assert Links.path(world.zadig.object_id, "Zadig", :public) == "/works/zadig"
      assert Links.path(world.candide.object_id, "Candide", :public) == nil
      assert Links.fallback(world.micromegas.object_id, "Micromegas", :public) == nil

      assert Links.paths(
               [{world.zadig.object_id, "Zadig"}, {world.micromegas.object_id, "Micromegas"}],
               :public
             ) == %{world.zadig.object_id => "/works/zadig", world.micromegas.object_id => nil}

      assert Links.withheld?(world.candide.object_id, :public)
      refute Links.withheld?(world.zadig.object_id, :public)
      refute Links.withheld?(world.micromegas.object_id, :public)

      # Internally, as before: the draft at its address, the rest at its
      # exact identity, and nothing withheld.
      assert Links.path(world.candide.object_id, "Candide", :internal) == "/works/candide"
      assert Links.path(world.micromegas.object_id, "Micromegas", :internal) == micromegas
      assert Links.fallback(world.micromegas.object_id, "Micromegas", :internal) == micromegas
      refute Links.withheld?(world.candide.object_id, :internal)
    end)
  end
end
