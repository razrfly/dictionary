defmodule DevilsDictionaryWeb.OnReaderTest do
  @moduledoc """
  On as the reading entry (#219 B2, B4, B6): every row of B2's table as a
  direct HTTP request, status and `location` included, and the reader's
  journeys as LiveView navigation — search → On → a subject's own address and
  back, exact words kept through a drawer and a reload.

  Mars's deity and album, the Butterfly works, On C++ and every other subject
  here are CI fixtures made in this test's sandbox (`OnFixtures`), never
  corpus records; the ones meant to be seen as fixtures carry the mark.

  Not async: it switches the configured reading mode (public mode is tested
  by turning the development default off), and allocates addresses.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  @moduletag :capture_log

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, importer!: 0, published!: 1]
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.{Fixtures, Registry, Repo}
  alias DevilsDictionary.Routing.{Ledger, Page}

  @fixture "#219 test fixture: not a corpus record"

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{conn: conn, sources: sources, human: human!(), importer: importer!()}
  end

  # Three words spelled `mars`, the planet, a fixture deity and a fixture
  # album: two addressed, one not.
  defp mars!(ctx, opts \\ []) do
    published = Keyword.get(opts, :published, false)
    noun = word!(ctx, "Mars", ~w(wiktionary), pos: "noun", scope: nil)
    verb = word!(ctx, "mars", ~w(wiktionary), pos: "verb", scope: nil)
    upper = word!(ctx, "MARS", ~w(wiktionary), pos: "noun", scope: nil)

    planet =
      subject!("Mars", "nature",
        description: "fourth planet from the Sun",
        path: "/nature/mars",
        published: published,
        actor: ctx.human
      )

    deity =
      subject!("Mars", "subjects",
        description: "Roman god of war",
        fixture: @fixture,
        path: "/subjects/mars",
        published: published,
        actor: ctx.human
      )

    album = subject!("Mars", "works", kind: :work, description: "2012 album", fixture: @fixture)

    %{noun: noun, verb: verb, upper: upper, planet: planet, deity: deity, album: album}
  end

  defp card(_view, group, entity), do: "#subject-#{group}-#{entity.object_id}"

  # ── B2: direct requests ──────────────────────────────────────────────────

  describe "direct requests, in public mode" do
    test "a published subject is 200; its spellings are one 301; a miss is a 404", ctx do
      mars!(ctx, published: true)

      reading(false, fn ->
        assert ctx.conn |> get("/nature/mars") |> html_response(200) =~ "fourth planet"

        for spelling <- ["/nature/Mars", "/nature/mars/", "/nature/MARS"] do
          conn = get(ctx.conn, spelling)
          assert conn.status == 301, spelling
          assert get_resp_header(conn, "location") == ["/nature/mars"]
        end

        assert ctx.conn |> get("/nature/jupiter") |> html_response(404) =~ "subject-unresolved"
        # The family routes answer only what the ledger holds for them.
        assert ctx.conn |> get("/people/mars") |> html_response(404) =~ "Nothing at this address"
      end)
    end

    test "a draft is 404 publicly, and its spellings never redirect to it", ctx do
      mars!(ctx)

      reading(false, fn ->
        for path <- ["/nature/mars", "/nature/Mars", "/subjects/mars/"] do
          conn = get(ctx.conn, path)
          assert conn.status == 404, path
          assert get_resp_header(conn, "location") == []
        end

        # No request parameter switches the mode.
        for query <- ["?mode=internal", "?reading=internal", "?internal=1"] do
          assert get(ctx.conn, "/nature/mars" <> query).status == 404
        end
      end)
    end

    test "the same draft is 200 and 301 internally, marked, and nothing is published", ctx do
      world = mars!(ctx)

      reading(true, fn ->
        html = ctx.conn |> get("/nature/mars") |> html_response(200)
        assert html =~ ~s(id="subject-draft")
        assert get(ctx.conn, "/nature/Mars") |> redirected_to(301) == "/nature/mars"
      end)

      assert Repo.get!(Page, world.planet.page.id).publication_state == :draft
    end

    test "an alias is one hop; a removed page is 410; malformed is 400; corrupt is 500", ctx do
      world = mars!(ctx, published: true)

      {:ok, _} =
        Ledger.move(world.planet.page.id, "/nature/mars-planet",
          actor_id: ctx.human.id,
          reason: "qualified"
        )

      {:ok, _} = Ledger.retire(world.deity.page.id, actor_id: ctx.human.id, reason: "removed")

      reading(false, fn ->
        assert get(ctx.conn, "/nature/mars") |> redirected_to(301) == "/nature/mars-planet"
        assert ctx.conn |> get("/nature/mars-planet") |> html_response(200) =~ "fourth planet"
        assert ctx.conn |> get("/subjects/mars") |> html_response(410) =~ "Removed"
        assert ctx.conn |> get("/nature/%2E%2E") |> html_response(400) =~ "Not an address"
        assert ctx.conn |> get("/nature/a%00b") |> html_response(400)
      end)

      # State the ledger's own triggers would refuse, forced past them.
      Repo.query!("SET session_replication_role = replica")

      try do
        # A published page with its canonical pointer gone.
        Repo.query!("UPDATE pages SET canonical_path_id = NULL WHERE id = $1", [
          world.planet.page.id
        ])

        reading(false, fn ->
          assert ctx.conn |> get("/nature/mars-planet") |> html_response(500) =~
                   "This address is broken"
        end)
      after
        Repo.query!("SET session_replication_role = origin")
      end
    end

    test "a split subject is a plain choice among its successors", ctx do
      [mercury, planet, element] =
        for {label, path} <- [
              {"Mercury", "/nature/mercury"},
              {"Mercury (planet)", "/nature/mercury-planet"},
              {"Mercury (element)", "/nature/mercury-element"}
            ] do
          subject!(label, "nature", path: path, published: true, actor: ctx.human).page
        end

      {:ok, _} =
        Registry.split(
          mercury.target_object_id,
          [planet.target_object_id, element.target_object_id], reason: "fixture")

      {:ok, _} =
        Ledger.split(mercury.id, [planet.id, element.id],
          actor_id: ctx.human.id,
          reason: "fixture"
        )

      reading(false, fn ->
        html = ctx.conn |> get("/nature/mercury") |> html_response(200)
        assert html =~ ~s(id="subject-choice")
        assert html =~ ~s(href="/nature/mercury-planet")
        assert html =~ ~s(href="/nature/mercury-element")
      end)
    end

    test "/on is 200 for words, 404 with suggestions for none; /words 404s a missing id", ctx do
      world = mars!(ctx, published: true)

      reading(false, fn ->
        html = ctx.conn |> get("/on/mars") |> html_response(200)
        assert html =~ "On mars"

        miss = ctx.conn |> get("/on/marz") |> html_response(404)
        assert miss =~ ~s(id="no-such-word")
        assert miss =~ ~s(id="suggestion-mars")

        # An exact address never substitutes the word the slug would find.
        missing = ctx.conn |> get("/words/999999999/mars") |> html_response(404)
        assert missing =~ ~s(id="no-such-word-identity")
        refute missing =~ ~s(id="headword")

        assert ctx.conn |> get("/words/#{world.noun.object_id}/mars") |> html_response(200)

        assert get(ctx.conn, "/words/#{world.noun.object_id}/wrong") |> redirected_to(302) ==
                 "/words/#{world.noun.object_id}/mars"

        # The exact-identity route is unchanged.
        assert ctx.conn
               |> get("/entities/#{world.album.entity.object_id}/mars")
               |> html_response(200) =~ "2012 album"
      end)
    end
  end

  # ── authored overviews on /on ────────────────────────────────────────────

  describe "an authored overview at an On address" do
    test "published: over its words publicly; a draft only internally; withdrawn never", ctx do
      world = mars!(ctx)

      overview =
        overview!("On Mars", "/on/mars", [{:supplies_lexical_material, world.noun.object_id}],
          author: ctx.human
        )

      reading(false, fn ->
        html = ctx.conn |> get("/on/mars") |> html_response(200)
        refute html =~ ~s(id="overview")
        assert html =~ ~s(id="headword")
      end)

      reading(true, fn ->
        {:ok, view, _html} = live(ctx.conn, "/on/mars")
        assert has_element?(view, "#overview #overview-draft")
        assert has_element?(view, "#headword")
      end)

      withdrawn!(overview)

      for on? <- [true, false] do
        reading(on?, fn ->
          html = ctx.conn |> get("/on/mars") |> html_response(200)
          refute html =~ ~s(id="overview")
        end)
      end
    end

    test "an overview with no words behind it is the page, or a 404 when not served", ctx do
      planet = subject!("Mars", "nature", path: "/nature/mars", published: true, actor: ctx.human)

      overview =
        overview!(
          "On the Red Planet",
          "/on/the-red-planet",
          [{:discusses_subject, planet.entity.object_id}], author: ctx.human)

      reading(false, fn ->
        assert ctx.conn |> get("/on/the-red-planet") |> html_response(404) =~ "no-such-word"
      end)

      published!(overview)

      reading(false, fn ->
        html = ctx.conn |> get("/on/the-red-planet") |> html_response(200)
        assert html =~ ~s(id="overview")
        assert html =~ "On the Red Planet"
        assert html =~ ~s(href="/nature/mars")
      end)
    end

    test "curated members: a different name is still a member; an association is not identity",
         ctx do
      world = mars!(ctx, published: true)

      ares =
        subject!("Ares", "subjects",
          fixture: @fixture,
          path: "/subjects/ares",
          published: true,
          actor: ctx.human
        )

      company = subject!("Mars, Incorporated", "organizations", fixture: @fixture)

      gone =
        subject!("Mars probe", "works",
          kind: :work,
          path: "/works/mars-probe",
          published: true,
          actor: ctx.human
        )

      withdrawn!(gone.page)

      overview!(
        "On Mars",
        "/on/mars",
        [
          {:supplies_lexical_material, world.noun.object_id},
          {:discusses_subject, ares.entity.object_id},
          {:discusses_subject, {:page, world.planet.page.id}},
          {:editorial_association, company.entity.object_id},
          {:discusses_subject, {:page, gone.page.id}}
        ],
        author: ctx.human,
        published: true
      )

      reading(false, fn ->
        {:ok, view, _html} = live(ctx.conn, "/on/mars")

        assert has_element?(view, "#overview")
        # Stored order, and a member named otherwise than the page.
        curated = view |> element("#subjects-curated") |> render()
        assert curated =~ "Ares"
        assert :binary.match(curated, "Ares") < :binary.match(curated, "fourth planet")

        assert has_element?(
                 view,
                 "#subject-curated-#{ares.entity.object_id}-link[href='/subjects/ares']"
               )

        # The association, shown as one, and nowhere as the same thing.
        assert has_element?(
                 view,
                 "#subjects-associations #{card(view, "association", company.entity)}"
               )

        refute has_element?(view, "#subjects-curated #{card(view, "curated", company.entity)}")

        # The withdrawn member is withheld, not replaced.
        assert has_element?(view, "#subjects-withheld")
        refute render(view) =~ "Mars probe"

        # Curated once; discovered subjects never repeat a curated one.
        refute has_element?(view, card(view, "discovered", world.planet.entity))
        assert has_element?(view, card(view, "discovered", world.deity.entity))
      end)
    end

    test "an overview whose words are other words is a separate choice, through reload", ctx do
      world = mars!(ctx, published: true)
      candy = word!(ctx, "Mars bar", ~w(wiktionary), pos: "noun", scope: nil)

      overview!("On Mars bars", "/on/mars", [{:supplies_lexical_material, candy.object_id}],
        author: ctx.human,
        published: true
      )

      reading(false, fn ->
        for _load <- 1..2 do
          {:ok, view, _html} = live(ctx.conn, "/on/mars")
          assert has_element?(view, "#overview-choice")
          refute has_element?(view, "#overview")
          assert has_element?(view, "#headword")
          refute has_element?(view, "#subjects-curated")
        end

        # Reached by navigation, the same.
        {:ok, home, _html} = live(ctx.conn, "/?q=mars")

        {:ok, view, _html} =
          home |> element("#result-mars") |> render_click() |> follow_redirect(ctx.conn)

        assert has_element?(view, "#overview-choice")
        _ = world
      end)
    end
  end

  # ── the reader's journeys ────────────────────────────────────────────────

  test "search → On Mars → each subject at its own address, and back", ctx do
    world = mars!(ctx)

    reading(true, fn ->
      {:ok, home, _html} = live(ctx.conn, "/")
      home |> form("#search", %{"q" => "Mars"}) |> render_submit()
      assert_redirect(home, "/on/mars")

      {:ok, on, _html} = live(ctx.conn, "/on/mars")
      assert page_title(on) =~ "On mars"

      planet = card(on, "discovered", world.planet.entity)
      deity = card(on, "discovered", world.deity.entity)
      album = card(on, "discovered", world.album.entity)

      assert has_element?(on, "#{planet}-link[href='/nature/mars']")
      assert has_element?(on, "#{deity}-link[href='/subjects/mars']")

      assert has_element?(
               on,
               "#{album}-link[href='/entities/#{world.album.entity.object_id}/mars']"
             )

      assert has_element?(on, "#{planet}[data-state='addressed']")
      assert has_element?(on, "#{album}[data-state='no_address']")
      assert on |> element(deity) |> render() =~ "Fixture"
      assert on |> element(deity) |> render() =~ "Draft"

      {:ok, nature, html} =
        on
        |> element("#{planet}-link")
        |> render_click()
        |> follow_redirect(ctx.conn, "/nature/mars")

      assert html =~ "fourth planet"
      assert has_element?(nature, "#subject-family", "Nature")
      assert has_element?(nature, "#subject-provenance")

      {:ok, _back, _html} =
        nature
        |> element("#subject-on")
        |> render_click()
        |> follow_redirect(ctx.conn, "/on/mars")

      {:ok, on, _html} = live(ctx.conn, "/on/mars")

      {:ok, subjects, html} =
        on
        |> element("#{deity}-link")
        |> render_click()
        |> follow_redirect(ctx.conn, "/subjects/mars")

      assert html =~ "Roman god of war"
      assert has_element?(subjects, "#subject-family", "Subjects")
    end)
  end

  test "public mode shows the same subjects with drafts withheld from their addresses", ctx do
    world = mars!(ctx)

    reading(false, fn ->
      {:ok, on, _html} = live(ctx.conn, "/on/mars")
      planet = card(on, "discovered", world.planet.entity)

      assert has_element?(on, "#{planet}[data-state='not_yet_public']")

      assert has_element?(
               on,
               "#{planet}-link[href='/entities/#{world.planet.entity.object_id}/mars']"
             )

      refute render(on) =~ ~s(href="/nature/mars")
      refute on |> element(planet) |> render() =~ "Draft"
    end)
  end

  test "an exact selection keeps its identity through a drawer and a reload", ctx do
    world = mars!(ctx, published: true)
    entry!(ctx, world.verb, "wiktionary", body: "to spoil")

    {:ok, home, _html} = live(ctx.conn, "/?q=mars")
    assert has_element?(home, "#result-word-#{world.verb.object_id}")

    {:ok, word, _html} =
      home
      |> element("#result-word-#{world.verb.object_id}")
      |> render_click()
      |> follow_redirect(ctx.conn, "/words/#{world.verb.object_id}/mars")

    assert word |> element("#headword") |> render() =~ "mars"

    path = "/words/#{world.verb.object_id}/mars?provenance=thing"
    word |> render_patch(path)
    assert_patched(word, path)

    # Reloaded, it is still that one word.
    {:ok, reloaded, _html} = live(ctx.conn, path)
    assert reloaded |> element("#headword") |> render() =~ "mars"
    refute has_element?(reloaded, "#disambiguation")
  end

  # ── B4: slugs, collisions and case ───────────────────────────────────────

  test "C++, C+ and c: one aggregate, three exact words, and On C++ at its own address", ctx do
    cpp = word!(ctx, "C++", ~w(wiktionary), pos: "name", slug: "c", scope: nil)
    cplus = word!(ctx, "C+", ~w(wiktionary), pos: "noun", slug: "c", scope: nil)
    c = word!(ctx, "c", ~w(wiktionary), pos: "letter", scope: nil)

    overview!("On C++", "/on/c-plus-plus", [{:supplies_lexical_material, cpp.object_id}],
      author: ctx.human,
      published: true
    )

    reading(false, fn ->
      # The aggregate is every word the slug reaches, and says where On C++ is.
      assert get(ctx.conn, "/on/c").status == 200
      {:ok, aggregate, _html} = live(ctx.conn, "/on/c")

      # Headed by `c`, the lemma spelled as the slug; the other two are named
      # and linked at their exact addresses, never merged into it.
      assert aggregate |> element("#headword h1") |> render() =~ ~r/>\s*c\s*</

      for word <- [cpp, cplus] do
        assert has_element?(
                 aggregate,
                 "#disambiguation-#{word.object_id}[href='/words/#{word.object_id}/c']"
               )
      end

      _ = c

      assert has_element?(aggregate, "#linked-overviews a[href='/on/c-plus-plus']")

      # The overview is its own page and links back to the exact word.
      {:ok, on_cpp, _html} = live(ctx.conn, "/on/c-plus-plus")
      assert has_element?(on_cpp, "#overview")

      assert has_element?(
               on_cpp,
               "#treatment-word-#{cpp.object_id}[href='/words/#{cpp.object_id}/c']"
             )

      # The exact word is C++ alone, and links its overview.
      {:ok, exact, _html} = live(ctx.conn, "/words/#{cpp.object_id}/c")
      assert exact |> element("#headword") |> render() =~ "C++"
      assert has_element?(exact, "#linked-overviews a[href='/on/c-plus-plus']")
    end)
  end

  test "Polish and polish: one On page, two words, two distinct subjects", ctx do
    word!(ctx, "Polish", ~w(wiktionary), pos: "adjective", scope: nil)
    word!(ctx, "polish", ~w(wiktionary), pos: "verb", scope: nil)

    language =
      subject!("Polish", "concepts",
        description: "West Slavic language",
        path: "/concepts/polish",
        published: true,
        actor: ctx.human
      )

    breed = subject!("Polish", "nature", description: "breed of chicken", fixture: @fixture)

    reading(false, fn ->
      {:ok, on, _html} = live(ctx.conn, "/on/polish")

      assert has_element?(
               on,
               "#{card(on, "discovered", language.entity)}-link[href='/concepts/polish']"
             )

      assert has_element?(
               on,
               "#{card(on, "discovered", breed.entity)}-link[href='/entities/#{breed.entity.object_id}/polish']"
             )
    end)
  end

  test "two works named Butterfly: two addresses in one namespace, each its own page", ctx do
    word!(ctx, "butterfly", ~w(wiktionary), pos: "noun", scope: nil)

    album =
      subject!("Butterfly", "works",
        kind: :work,
        description: "1997 album",
        path: "/works/butterfly-1997-album",
        published: true,
        actor: ctx.human
      )

    novel =
      subject!("Butterfly", "works",
        kind: :work,
        work_kind: "novel",
        description: "novel by Sonya Hartnett",
        path: "/works/butterfly-novel",
        published: true,
        actor: ctx.human
      )

    reading(false, fn ->
      {:ok, on, _html} = live(ctx.conn, "/on/butterfly")

      assert has_element?(
               on,
               "#{card(on, "discovered", album.entity)}-link[href='/works/butterfly-1997-album']"
             )

      assert has_element?(
               on,
               "#{card(on, "discovered", novel.entity)}-link[href='/works/butterfly-novel']"
             )

      assert ctx.conn |> get("/works/butterfly-1997-album") |> html_response(200) =~ "1997 album"
      assert ctx.conn |> get("/works/butterfly-novel") |> html_response(200) =~ "Sonya Hartnett"
    end)
  end

  test "a combining-mark label and its capitalized spelling reach one address", ctx do
    word!(ctx, "café", ~w(wiktionary), pos: "noun", scope: nil)

    cafe =
      subject!("Café", "concepts", path: "/concepts/café", published: true, actor: ctx.human)

    reading(false, fn ->
      canonical = "/concepts/caf%C3%A9"

      for spelling <- ["/concepts/Caf%C3%A9", "/concepts/cafe%CC%81", "/concepts/CAF%C3%89"] do
        assert get(ctx.conn, spelling) |> redirected_to(301) == canonical, spelling
      end

      assert ctx.conn |> get(canonical) |> html_response(200)

      {:ok, on, _html} = live(ctx.conn, "/on/cafe")
      assert has_element?(on, "#{card(on, "discovered", cafe.entity)}-link[href='#{canonical}']")
    end)
  end

  test "a word with three subjects, one addressed, shows each state", ctx do
    word!(ctx, "Mercury", ~w(wiktionary), pos: "noun", scope: nil)

    planet =
      subject!("Mercury", "nature", path: "/nature/mercury", published: true, actor: ctx.human)

    element = subject!("Mercury", "concepts", fixture: @fixture)

    deity =
      subject!("Mercury", "subjects",
        status: :needs_review,
        candidates: ["nature", "works"],
        fixture: @fixture
      )

    reading(false, fn ->
      {:ok, on, _html} = live(ctx.conn, "/on/mercury")

      assert has_element?(on, "#{card(on, "discovered", planet.entity)}[data-state='addressed']")

      assert has_element?(
               on,
               "#{card(on, "discovered", element.entity)}[data-state='no_address']"
             )

      assert has_element?(
               on,
               "#{card(on, "discovered", deity.entity)}[data-state='awaiting_review']"
             )

      assert on |> element(card(on, "discovered", deity.entity)) |> render() =~ "Nature or Works"
      assert has_element?(on, "#subjects", "3 subjects")
    end)
  end

  test "an edition's page is in Works and opens there", ctx do
    edition =
      subject!("Project Gutenberg #972", "works",
        kind: :edition,
        path: "/works/project-gutenberg-sharp-972",
        published: true,
        actor: ctx.human
      )

    reading(false, fn ->
      html = ctx.conn |> get("/works/project-gutenberg-sharp-972") |> html_response(200)
      assert html =~ "Project Gutenberg #972"
      assert html =~ ~s(id="subject-family")
      _ = edition
    end)
  end
end
