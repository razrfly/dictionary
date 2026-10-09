defmodule DevilsDictionaryWeb.HeadTest do
  @moduledoc """
  Head metadata per role (#237 C4; ADR 0004 §6 and §7), on the initial
  response and after live navigation:

    * a published subject at its canonical: its label and family as the
      title, one canonical on the published host, no robots instruction, a
      description, and the JSON-LD of D4; every query variant, a draft, the
      switch off: noindex, still 200 where the page answers;
    * On: the word, its canonical as the headword's slug, indexable only as
      a lexical entry of the launch manifest whose subject is published
      (D1); a spelling, a trail, a drawer and the demo are noindex variants;
    * an exact word, the exact-identity route, evidence and the way in:
      noindex, each at its own canonical (the exact-identity route at the
      subject's public address where one is served);
    * live navigation sets the head again, and the hook element carries it;
    * a page that sets no head is noindex with no canonical.

  Voltaire and the rest are CI fixtures made in this test's sandbox.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  @moduletag :capture_log

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0]
  import DevilsDictionary.WordFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.{Fixtures, Registry, Repo}
  alias DevilsDictionary.Registry.SenseRevision
  alias DevilsDictionary.Routing.LaunchManifest

  @host "wordhoard.test"
  @origin "https://" <> @host

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()
    previous = for key <- [:published_host, :launch_manifest], do: {key, env(key)}
    Application.put_env(:devils_dictionary, :published_host, @host)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore(key, value) end) end)
    %{conn: conn, sources: sources, human: human!()}
  end

  defp env(key), do: Application.get_env(:devils_dictionary, key)
  defp restore(key, nil), do: Application.delete_env(:devils_dictionary, key)
  defp restore(key, value), do: Application.put_env(:devils_dictionary, key, value)

  defp with_env(key, value, fun) do
    previous = env(key)
    restore(key, value)

    try do
      fun.()
    after
      restore(key, previous)
    end
  end

  defp switch(on?, fun), do: with_env(:public_routing, on?, fun)

  # Voltaire: a published person with a description, a biography, a verified
  # Wikidata identifier and a candidate one, and the word spelled like him.
  defp voltaire!(ctx) do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        description: "French writer and philosopher.",
        path: "/people/voltaire",
        published: true,
        actor: ctx.human
      )

    entry!(ctx, voltaire.entity, "wikipedia",
      body: "Voltaire was a writer of the Enlightenment. He wrote much."
    )

    id = voltaire.entity.object_id
    {:ok, _} = Registry.add_external_id(id, "wikidata", "Q9068")
    {:ok, _} = Registry.add_external_id(id, "wikidata", "Q999999999", %{status: :candidate})

    word = word!(ctx, "Voltaire", ~w(wiktionary))

    sense =
      sense!(ctx, word, "wiktionary",
        gloss: "A French writer of the Enlightenment. Also a given name."
      )

    Map.merge(voltaire, %{word: word, sense: sense})
  end

  # The launch manifest lists `path` as a lexical entry for `page_ids`.
  defp list!(page_ids, path \\ "/on/voltaire") do
    file =
      Path.join(System.tmp_dir!(), "launch-manifest-#{System.unique_integer([:positive])}.json")

    doc = %{
      "format" => LaunchManifest.format(),
      "entries" => [
        %{
          "kind" => "lexical",
          "locale" => "en",
          "path" => path,
          "lexeme_ids" => [],
          "subject_page_ids" => page_ids,
          "reviewer" => "reviewer@example.test",
          "clause" => "index_lexical"
        }
      ]
    }

    File.write!(file, Jason.encode!(doc))
    Application.put_env(:devils_dictionary, :launch_manifest, file)
    on_exit(fn -> File.rm(file) end)
    file
  end

  # What the response's head says.
  defp head(html) when is_binary(html) do
    doc = LazyHTML.from_document(html)

    %{
      title: doc |> LazyHTML.query("head title") |> LazyHTML.text() |> String.trim(),
      canonical: doc |> attribute("head link[rel=canonical]", "href"),
      robots: doc |> attribute("head meta[name=robots]", "content"),
      description: doc |> attribute("head meta[name=description]", "content"),
      json_ld: doc |> LazyHTML.query("head script#json-ld") |> LazyHTML.text() |> decode()
    }
  end

  defp attribute(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

  defp decode(json) do
    case String.trim(json) do
      "" -> nil
      json -> Jason.decode!(json)
    end
  end

  defp head_of(conn, path, status) do
    head(conn |> get(path) |> html_response(status))
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # ── the initial response, per role ───────────────────────────────────────

  test "a published subject at its canonical: title, canonical, no robots, description, JSON-LD",
       ctx do
    voltaire!(ctx)
    head = head_of(ctx.conn, "/people/voltaire", 200)

    assert head.title == "Voltaire · People · wordhoard"
    assert head.canonical == @origin <> "/people/voltaire"
    assert head.robots == nil
    assert head.description == "French writer and philosopher."

    assert %{"@context" => "https://schema.org", "@graph" => [page, subject]} = head.json_ld

    assert page["@type"] == "WebPage"
    assert page["@id"] == @origin <> "/people/voltaire#page"
    assert page["url"] == @origin <> "/people/voltaire"
    assert page["name"] == "Voltaire · People"
    assert page["description"] == "French writer and philosopher."
    assert page["inLanguage"] == "en"
    assert page["about"] == %{"@id" => @origin <> "/people/voltaire#subject"}
    assert page["dateModified"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    # The subject: typed by its family, identified only by the verified id.
    assert subject == %{
             "@type" => "Person",
             "@id" => @origin <> "/people/voltaire#subject",
             "name" => "Voltaire",
             "url" => @origin <> "/people/voltaire",
             "description" => "French writer and philosopher.",
             "sameAs" => "https://www.wikidata.org/wiki/Q9068"
           }

    # HEAD answers as GET does.
    assert head(ctx.conn, "/people/voltaire").status == 200
  end

  test "a query variant is noindex at the base canonical; a draft and the switch off are 404 and noindex",
       ctx do
    voltaire!(ctx)

    for query <- ["?works_after=1", "?from=/on/voltaire", "?demo=1"] do
      head = head_of(ctx.conn, "/people/voltaire" <> query, 200)
      assert head.robots == "noindex", query
      assert head.canonical == @origin <> "/people/voltaire", query
    end

    subject!("Arouet", "people", kind: :person, description: "A draft.", path: "/people/arouet")

    head = head_of(ctx.conn, "/people/arouet", 404)
    assert head.robots == "noindex"
    assert head.canonical == nil
    assert head.title == "Nothing at this address · wordhoard"

    # Internally the draft reads at its address, marked, and still noindex.
    with_env(:published_host, nil, fn ->
      reading(true, fn ->
        head = head_of(ctx.conn, "/people/arouet", 200)
        assert head.robots == "noindex"
        assert head.canonical =~ "/people/arouet"
        assert head.title == "Arouet · People · wordhoard"
      end)
    end)

    switch(false, fn ->
      head = head_of(ctx.conn, "/people/voltaire", 404)
      assert head.robots == "noindex"
      assert head.canonical == nil
    end)
  end

  test "On: the word, the headword's slug as canonical, indexable only as a listed lexical entry",
       ctx do
    world = voltaire!(ctx)

    # Not listed: 200 and noindex, so a crawler can read it.
    head = head_of(ctx.conn, "/on/voltaire", 200)
    assert head.title == "On Voltaire · wordhoard"
    assert head.canonical == @origin <> "/on/voltaire"
    assert head.robots == "noindex"
    assert head.description == "A French writer of the Enlightenment."

    assert [%{"@type" => "WebPage", "@id" => @origin <> "/on/voltaire#page"}] =
             head.json_ld["@graph"]

    list!([world.page.id])
    head = head_of(ctx.conn, "/on/voltaire", 200)
    assert head.robots == nil
    assert head.canonical == @origin <> "/on/voltaire"

    # A spelling, a trail, a drawer and the demo: the same canonical, noindex.
    for path <- [
          "/on/Voltaire",
          "/on/voltaire?trail=oyster",
          "/on/voltaire?demo=1",
          "/on/voltaire?provenance=x"
        ] do
      head = head_of(ctx.conn, path, 200)
      assert head.robots == "noindex", path
      assert head.canonical == @origin <> "/on/voltaire", path
    end

    # The switch off, or the subject withdrawn: noindex again.
    switch(false, fn -> assert head_of(ctx.conn, "/on/voltaire", 200).robots == "noindex" end)
    withdrawn!(world.page)
    assert head_of(ctx.conn, "/on/voltaire", 200).robots == "noindex"

    # A miss: noindex, no canonical, under the plug's 404.
    head = head_of(ctx.conn, "/on/voltairy", 404)
    assert head.robots == "noindex"
    assert head.canonical == nil
  end

  test "an exact word: lemma and part of speech, its own canonical, noindex", ctx do
    world = voltaire!(ctx)
    id = world.word.object_id

    head = head_of(ctx.conn, "/words/#{id}/voltaire", 200)
    assert head.title == "Voltaire · noun · wordhoard"
    assert head.canonical == @origin <> "/words/#{id}/voltaire"
    assert head.robots == "noindex"
    assert head.description == "A French writer of the Enlightenment."

    # Listing the On page does not index the exact word (D1).
    list!([world.page.id])
    assert head_of(ctx.conn, "/words/#{id}/voltaire", 200).robots == "noindex"

    head = head_of(ctx.conn, "/words/999999999/voltaire", 404)
    assert head.robots == "noindex"
    assert head.canonical == nil
  end

  test "the exact-identity route: noindex, canonical at the subject's public address", ctx do
    world = voltaire!(ctx)
    id = world.entity.object_id

    head = head_of(ctx.conn, "/entities/#{id}/voltaire", 200)
    assert head.title == "Voltaire · wordhoard"
    assert head.robots == "noindex"
    assert head.canonical == @origin <> "/people/voltaire"
    assert head.description == "French writer and philosopher."
    assert [%{"@type" => "WebPage"}] = head.json_ld["@graph"]

    switch(false, fn ->
      assert head_of(ctx.conn, "/entities/#{id}/voltaire", 200).canonical ==
               @origin <> "/entities/#{id}/voltaire"
    end)

    album = subject!("Mars", "works", kind: :work, description: "2012 album")
    album_id = album.entity.object_id
    head = head_of(ctx.conn, "/entities/#{album_id}/mars", 200)
    assert head.canonical == @origin <> "/entities/#{album_id}/mars"
    assert head.robots == "noindex"

    head = head_of(ctx.conn, "/entities/999999999/nobody", 404)
    assert head.robots == "noindex"
    assert head.canonical == nil
  end

  test "evidence: the revision, its own canonical, noindex", ctx do
    world = voltaire!(ctx)

    revision =
      Repo.one!(
        from r in SenseRevision,
          where: r.sense_id == ^world.sense.object_id and r.is_current,
          select: r.id
      )

    head = head_of(ctx.conn, "/evidence/sense/#{revision}", 200)
    assert head.title == "Voltaire · revision #{revision} · wordhoard"
    assert head.canonical == @origin <> "/evidence/sense/#{revision}"
    assert head.robots == "noindex"
    assert head.description == "A French writer of the Enlightenment."

    head = head_of(ctx.conn, "/evidence/sense/999999999", 200)
    assert head.title == "No such evidence revision · wordhoard"
    assert head.robots == "noindex"
    assert head.canonical == nil
  end

  test "the way in is noindex at /, and so is a search", ctx do
    for path <- ["/", "/?q=voltaire"] do
      head = head_of(ctx.conn, path, 200)
      assert head.title == "Every word, every source · wordhoard", path
      assert head.robots == "noindex", path
      assert head.canonical == @origin <> "/", path
      assert head.description == "Every word. Every source. One page."
    end
  end

  test "a page that sets no head is noindex with no canonical, on the response and the hook",
       ctx do
    for path <- ["/artworks", "/sources/wiktionary"] do
      head = head_of(ctx.conn, path, 200)
      assert head.robots == "noindex", path
      assert head.canonical == nil, path
      assert head.json_ld == nil, path
    end

    {:ok, view, _html} = live(ctx.conn, "/artworks")
    assert has_element?(view, "#page-head[data-robots='noindex']")
    refute has_element?(view, "#page-head[data-canonical]")
  end

  # ── live navigation ──────────────────────────────────────────────────────

  test "live navigation sets the head again: On to a subject, a variant by patch, and back",
       ctx do
    world = voltaire!(ctx)
    list!([world.page.id])

    {:ok, on, _html} = live(ctx.conn, "/on/voltaire")
    assert has_element?(on, "#page-head[data-canonical='#{@origin}/on/voltaire']")
    assert has_element?(on, "#page-head[data-title='On Voltaire · wordhoard']")
    refute has_element?(on, "#page-head[data-robots]")
    assert %{head: %{indexable?: true, canonical: @origin <> "/on/voltaire"}} = assigns(on)

    {:ok, subject, _html} =
      on
      |> element("#subject-discovered-#{world.entity.object_id}-link")
      |> render_click()
      |> follow_redirect(ctx.conn, "/people/voltaire")

    assert page_title(subject) == "Voltaire · People · wordhoard"
    assert has_element?(subject, "#page-head[data-title='Voltaire · People · wordhoard']")
    assert has_element?(subject, "#page-head[data-canonical='#{@origin}/people/voltaire']")
    assert has_element?(subject, "#page-head[data-description='French writer and philosopher.']")
    refute has_element?(subject, "#page-head[data-robots]")

    assert %{head: %{indexable?: true, robots: nil, canonical: canonical, json_ld: json}} =
             assigns(subject)

    assert canonical == @origin <> "/people/voltaire"
    assert %{"@graph" => [%{"@type" => "WebPage"}, %{"@type" => "Person"}]} = Jason.decode!(json)

    # A section cursor, by patch: a noindex variant of the same canonical.
    render_patch(subject, "/people/voltaire?works_after=1")
    assert has_element?(subject, "#page-head[data-robots='noindex']")
    assert has_element?(subject, "#page-head[data-canonical='#{@origin}/people/voltaire']")
    assert %{head: %{indexable?: false, robots: "noindex"}} = assigns(subject)

    {:ok, back, _html} =
      subject
      |> element("#subject-on")
      |> render_click()
      |> follow_redirect(ctx.conn, "/on/voltaire")

    assert page_title(back) == "On Voltaire · wordhoard"
    assert has_element?(back, "#page-head[data-canonical='#{@origin}/on/voltaire']")
    refute has_element?(back, "#page-head[data-robots]")
    assert %{head: %{indexable?: true}} = assigns(back)
  end
end
