defmodule DevilsDictionaryWeb.ConnectedFlowTest do
  @moduledoc """
  #74's milestone 3, driven end to end: **a working, inspectable example, not
  just tables or a diagram.**

  The anchor the issue names: *Ambrose Bierce → authored definition → nepotism;
  Bierce → encyclopedia biography; one cultural artifact → attributed example of
  a selected sense.* The walk is the proof, because the thing being proved is
  that **one object id** carries all of it — in MVP-0 `people` held authors and
  `concepts` held encyclopedia subjects with no foreign key between them, so
  "his definitions" and "his biography" were two populations and this page could
  not exist.

  Every navigation here is a real click on a rendered link, so a section that
  renders but does not connect fails.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.{Fixtures, Registry, Repo}

  setup %{conn: conn} do
    %{sources: sources, scopes: scopes, people: people} = Fixtures.seed_catalog!()

    %{
      conn: conn,
      sources: sources,
      animals: scopes["animals"],
      bierce: people["ambrose-bierce"]
    }
  end

  # The graph #74 §E draws, with the ids it draws it with.
  defp anchor!(ctx) do
    nepotism = word!(ctx, "nepotism", ~w(bierce wordnet), scope: nil)

    definition =
      entry!(ctx, nepotism, "bierce",
        headword: "NEPOTISM",
        body: "Appointing your grandmother to office for the good of the party.",
        author: ctx.bierce.person,
        year: 1911
      )

    # The definition was printed in an edition of a work he wrote — the credit
    # chain #74 §E lays out: 105 authored_by 101, 105 published_in 103,
    # 103 edition_of 102, 102 authored_by 101.
    {:ok, _} =
      Claims.assert(definition.object_id, "published_in", ctx.bierce.edition.object_id, %{
        source_id: ctx.sources["bierce"].id
      })

    # His biography: an article *about* the same object id his definitions are
    # *authored_by*. That identity is the whole point.
    biography =
      entry!(ctx, ctx.bierce.person, "wikipedia",
        kind: :article,
        body: "American satirist; author of The Devil's Dictionary.",
        headword: "Ambrose Bierce"
      )

    # The practice the word names, and a local artifact offered as an
    # illustration of it — a thing with no Wikidata id at all, which #74's
    # decision 7 requires to be a first-class identity.
    practice = concept!("Q193741", "nepotism", description: "favouring relatives")
    sense = sense!(ctx, nepotism, "wordnet", gloss: "favoritism shown to relatives")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", practice.object_id)

    meme = concept!(nil, "an untitled illustrative meme", kind: :artifact)

    {:ok, illustration} =
      Claims.assert(meme.object_id, "illustrates", sense.object_id, %{
        rationale: "the joke is the definition",
        method: "curated"
      })

    Map.merge(ctx, %{
      nepotism: nepotism,
      definition: definition,
      biography: biography,
      practice: practice,
      sense: sense,
      meme: meme,
      illustration: illustration
    })
  end

  describe "the anchor example, walked" do
    test "definition → author → biography → works → back to the definition", ctx do
      ctx = anchor!(ctx)
      person = ctx.bierce.person

      # 1. The word page has Bierce's definition on it.
      {:ok, word_live, html} = live(ctx.conn, ~p"/define/nepotism")
      assert html =~ "Appointing your grandmother"

      # 2. Follow the actual definition's author link.
      {:ok, live, html} =
        word_live
        |> element("a[id$='-author-#{person.object_id}']")
        |> render_click()
        |> follow_redirect(ctx.conn)

      assert html =~ "Ambrose Bierce"

      # 3. His biography and his definitions are on the same page — the two
      #    populations MVP-0 could not join.
      assert html =~ ~s(id="entity-biography")
      assert html =~ "American satirist"
      assert html =~ ~s(id="entity-definitions")
      assert html =~ "Appointing your grandmother"

      # 4. And the work he wrote, with the edition the definition was printed in
      #    named beside it.
      assert html =~ ~s(id="entity-works")
      assert html =~ "The Devil&#39;s Dictionary"
      assert html =~ "Project Gutenberg"

      # 5. The definition links back to the word it defines. A real click, so a
      #    section that renders but does not connect fails here.
      {:error, {:live_redirect, %{to: back}}} =
        live
        |> element(~s(#definition-#{ctx.definition.object_id} a), "nepotism")
        |> render_click()

      assert back == "/words/#{ctx.nepotism.object_id}/nepotism"

      # 6. Which is the canonical address of the word we started from.
      {:ok, _live, html} = live(ctx.conn, back)
      assert html =~ "Appointing your grandmother"
    end

    test "definitions targeting a word and its sense both retain their word links", ctx do
      ctx = anchor!(ctx)

      {:ok, passage} =
        Registry.create_content(%{
          content_kind: :definition,
          body: "A meaning-specific definition"
        })

      {:ok, _} = Claims.assert(passage.object_id, "defines", ctx.sense.object_id)
      {:ok, _} = Claims.assert(passage.object_id, "authored_by", ctx.bierce.person.object_id)
      page = DevilsDictionary.Encyclopedia.EntityPage.build(ctx.bierce.person.object_id)
      definitions = Map.new(page.definitions, &{&1.object_id, &1})
      assert definitions[ctx.definition.object_id].defines.object_id == ctx.nepotism.object_id
      assert definitions[passage.object_id].defines.object_id == ctx.nepotism.object_id
    end

    test "the work page names its author, its edition and what the edition contains", ctx do
      ctx = anchor!(ctx)
      work = ctx.bierce.work

      {:ok, _live, html} =
        live(
          ctx.conn,
          ~p"/entities/#{work.object_id}/#{Connection.slugify(work.preferred_label)}"
        )

      assert html =~ ~s(id="entity-editions")
      assert html =~ "Project Gutenberg"

      # The work, the edition and the definition are three records, which is
      # what keeps "the 1911 text" from being a property of the poem.
      {:ok, _live, edition} =
        live(
          ctx.conn,
          ~p"/entities/#{ctx.bierce.edition.object_id}/#{Connection.slugify(ctx.bierce.edition.preferred_label)}"
        )

      assert edition =~ ~s(id="entity-contents")
      assert edition =~ "nepotism"
    end
  end

  describe "the attributed illustration" do
    test "reads the same from both endpoints, with the same status", ctx do
      ctx = anchor!(ctx)
      revision = Claims.current_revision(ctx.illustration.id)

      # From the claim's own page.
      {:ok, _live, detail} = live(ctx.conn, ~p"/connections/#{ctx.illustration.id}")
      assert detail =~ "an untitled illustrative meme"
      assert detail =~ "illustrates"
      assert detail =~ "the joke is the definition"
      assert detail =~ ~s(id="connection-review")
      assert detail =~ "needs_review"

      # From the artifact's page — the same claim, listed outgoing.
      {:ok, _live, from_meme} =
        live(
          ctx.conn,
          ~p"/entities/#{ctx.meme.object_id}/#{Connection.slugify("an untitled illustrative meme")}"
        )

      assert from_meme =~ ~s(id="connection-out-#{ctx.illustration.id}")

      # And from the meaning's side. One row, so they cannot disagree.
      assert [seen] = Claims.incoming(ctx.sense.object_id, predicate: "illustrates")
      assert seen.id == revision.id
    end

    test "and a rejected claim disappears from both, and from the counts", ctx do
      ctx = anchor!(ctx)
      revision = Claims.current_revision(ctx.illustration.id)

      Claims.review(revision.id, :rejected, reason: "the meme is about something else")

      {:ok, _live, from_meme} =
        live(
          ctx.conn,
          ~p"/entities/#{ctx.meme.object_id}/#{Connection.slugify("an untitled illustrative meme")}"
        )

      refute from_meme =~ ~s(id="connection-out-#{ctx.illustration.id}")
      assert Claims.incoming(ctx.sense.object_id, predicate: "illustrates") == []
      assert Claims.count_incoming(ctx.sense.object_id, predicate: "illustrates") == 0
    end

    test "a candidate is labelled apart from a direct example", ctx do
      ctx = anchor!(ctx)

      # `refers_to` is sense-backed: this meaning names that practice. A
      # spelling-level candidate is a different claim and never propagates
      # examples — #74 §C, and the distinction the thing panel must not blur.
      assert [refers] = Claims.outgoing(ctx.sense.object_id, predicate: "refers_to")
      assert refers.object_object_id == ctx.practice.object_id

      {:ok, _} =
        Claims.assert(
          ctx.nepotism.object_id,
          "lexeme_entity_candidate",
          ctx.practice.object_id,
          %{
            method: "title_match",
            confidence: 0.7
          }
        )

      {:ok, _live, html} = live(ctx.conn, ~p"/define/nepotism")

      # The panel shows the thing the *meaning* names, and offers the spelling's
      # possibilities separately.
      assert html =~ ~s(id="thing")
      assert html =~ "favouring relatives"
    end
  end

  describe "the contribution gate" do
    test "a public registered account cannot reach the writable composer", ctx do
      %{conn: conn} = register_and_log_in_user(%{conn: ctx.conn})

      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, ~p"/connect")
      assert flash["error"] =~ "internal testing"
    end
  end

  describe "the composer" do
    setup ctx do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
      user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))
      Map.merge(ctx, %{conn: conn, user: user})
    end

    test "needs an account, offers only valid relations, and insists on a reason", ctx do
      ctx = anchor!(ctx)

      {:ok, live, html} = live(ctx.conn, ~p"/connect")
      assert html =~ "Connect two things"

      # Names help discovery; the id is what the claim points at.
      html =
        live
        |> form("#composer-subject form", %{"q" => "untitled"})
        |> render_change()

      assert html =~ "an untitled illustrative meme"

      html =
        live
        |> element("#composer-subject-hit-#{ctx.meme.object_id}")
        |> render_click()

      # Only the relations an artifact can actually be the subject of. `defines`
      # is not one of them, and the list is read off the endpoint rules rather
      # than from a list somebody keeps in step with them.
      assert html =~ ~s(id="predicate-illustrates")
      refute html =~ ~s(id="predicate-defines")

      live |> element("#predicate-illustrates") |> render_click()

      html =
        live
        |> form("#composer-object form", %{"q" => "nepotism"})
        |> render_change()

      assert html =~ "nepotism"

      live |> element("#composer-object-hit-#{ctx.practice.object_id}") |> render_click()

      # A claim nobody explained is one nobody can review.
      html = live |> form("#composer-form", %{"rationale" => "  "}) |> render_submit()
      assert html =~ "Say why"

      live
      |> form("#composer-form", %{"rationale" => "it is the same practice"})
      |> render_change()

      {:error, {:live_redirect, %{to: to}}} =
        live |> form("#composer-form") |> render_submit()

      assert to =~ ~r"^/connections/\d+$"

      # And what landed is attributed, unreviewed, and reads from both ends.
      {:ok, _live, detail} = live(ctx.conn, to)
      assert detail =~ "it is the same practice"
      assert detail =~ "needs_review"
      assert detail =~ ctx.user.email
    end

    test "refuses a pair the endpoint rules do not allow", ctx do
      ctx = anchor!(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/connect")

      # A word cannot `illustrate` anything: the subject of `illustrates` is an
      # entity or a piece of content, never a lexeme. The composer will not even
      # offer it — which is the point of reading the rules rather than a list.
      live |> form("#composer-subject form", %{"q" => "nepotism"}) |> render_change()
      html = live |> element("#composer-subject-hit-#{ctx.nepotism.object_id}") |> render_click()

      refute html =~ ~s(id="predicate-illustrates")
    end
  end

  describe "the canonical address" do
    test "a slug naming more than one word offers the choice rather than picking", ctx do
      # `C++`, `C+` and `c` are three identities that share a slug. MVP-0 headed
      # the page `-c-` and showed one of them.
      word!(ctx, "C++", ~w(wiktionary), slug: "c", scope: nil)
      word!(ctx, "c", ~w(wiktionary), slug: "c", scope: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/define/c")

      assert html =~ ~s(id="disambiguation")
      assert html =~ "C++"
    end

    test "and the canonical address shows one word with no choice to make", ctx do
      plus = word!(ctx, "C++", ~w(wiktionary), slug: "c", scope: nil)
      word!(ctx, "c", ~w(wiktionary), slug: "c", scope: nil)

      {:ok, _live, html} = live(ctx.conn, ~p"/words/#{plus.object_id}/c")

      refute html =~ ~s(id="disambiguation")
      assert html =~ "C++"
    end

    test "a wrong slug redirects to the right one rather than erroring", ctx do
      ctx = anchor!(ctx)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(ctx.conn, ~p"/words/#{ctx.nepotism.object_id}/wrong-slug")

      assert to == "/words/#{ctx.nepotism.object_id}/nepotism"
    end

    test "an entity's slug redirects the same way", ctx do
      person = ctx.bierce.person

      assert {:error, {:live_redirect, %{to: to}}} =
               live(ctx.conn, ~p"/entities/#{person.object_id}/not-his-name")

      assert to == "/entities/#{person.object_id}/ambrose-bierce"
    end

    test "an identity that never existed is a page that says so", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/entities/999999999/nobody")
      assert html =~ ~s(id="no-such-entity")

      {:ok, _live, html} = live(ctx.conn, ~p"/connections/999999999")
      assert html =~ ~s(id="no-such-connection")
      _ = ctx
    end
  end

  describe "one identity, not two" do
    test "the definitions and the biography name the same object id", ctx do
      ctx = anchor!(ctx)
      person = ctx.bierce.person

      authored = Claims.incoming(person.object_id, predicate: "authored_by")
      about = Claims.incoming(person.object_id, predicate: "about")

      assert Enum.any?(authored, &(&1.subject_object_id == ctx.definition.object_id))
      assert Enum.any?(about, &(&1.subject_object_id == ctx.biography.object_id))

      # The completion gate's first line: "Bierce has one identity across
      # authorship and biography." There is one row in `entities` for him, and
      # `person_details` hangs off it.
      assert Registry.object(person.object_id).kind == :entity
      assert Repo.get(Registry.PersonDetails, person.object_id)
    end
  end

  describe "closure regressions" do
    test "rejected claims cannot leak through direct or historical public URLs", ctx do
      ctx = anchor!(ctx)
      first = Claims.current_revision(ctx.illustration.id)
      {:ok, _} = Claims.revise(ctx.illustration.id, %{rationale: "new wording"})
      current = Claims.current_revision(ctx.illustration.id)
      Claims.review(current.id, :rejected, %{reason: "not applicable"})

      for suffix <- ["", "?revision=#{first.revision_number}", "?revision=garbage"] do
        {:ok, view, _} = live(ctx.conn, "/connections/#{ctx.illustration.id}#{suffix}")
        assert has_element?(view, "#no-such-connection")
      end
    end

    test "source sense and evidence can be selected, saved and reviewed by an authorized reviewer",
         ctx do
      ctx = anchor!(ctx)
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: ctx.conn})
      _user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))
      {:ok, view, _} = live(conn, "/connect")
      view |> form("#composer-subject form", %{q: "untitled"}) |> render_change()
      view |> element("#composer-subject-hit-#{ctx.meme.object_id}") |> render_click()
      view |> element("#predicate-illustrates") |> render_click()
      view |> form("#composer-object form", %{q: "nepotism"}) |> render_change()
      assert has_element?(view, "#composer-object-hit-#{ctx.sense.object_id}")
      view |> element("#composer-object-hit-#{ctx.sense.object_id}") |> render_click()
      view |> form("#composer-context form", %{q: "Ambrose Bierce"}) |> render_change()
      view |> element("#composer-context-hit-#{ctx.bierce.person.object_id}") |> render_click()
      view |> form("#composer-evidence form", %{q: "NEPOTISM"}) |> render_change()
      view |> element("#composer-evidence-hit-#{ctx.definition.object_id}") |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#composer-form", %{rationale: "a precise example", locator: "paragraph 1"})
        |> render_submit()

      {:ok, detail, _} = live(conn, to)
      assert has_element?(detail, "#connection-evidence", "paragraph 1")
      refute has_element?(detail, "#connection-review-form")
      id = to |> String.split("/") |> List.last() |> String.to_integer()
      current = Claims.current_revision(id)
      assert current.context_object_id == ctx.bierce.person.object_id
      [evidence] = Claims.evidence(current.id)

      assert evidence.content_revision_id ==
               Registry.current_content_revision(ctx.definition.object_id).id

      assert {:error, :unauthorized} =
               DevilsDictionary.Claims.Contributions.review(
                 DevilsDictionary.Accounts.Scope.for_user(user),
                 id,
                 current.id,
                 "accepted",
                 "checked",
                 []
               )

      reviewer = Repo.update!(Ecto.Changeset.change(user, reviewer: true))
      {:ok, review_view, _} = live(log_in_user(build_conn(), reviewer), to)
      assert has_element?(review_view, "#connection-review-form")

      review_view
      |> form("#connection-review-form", %{reason: "checked against the cited meaning"})
      |> render_submit(%{decision: "accepted"})

      assert Claims.review_state(current.id) == :accepted
      [review] = Claims.reviews(current.id)
      assert review.review_context_id
      assert review.reviewer_actor_id
      # Revocation takes effect even with an already connected LiveView.
      Repo.update!(Ecto.Changeset.change(reviewer, reviewer: false))

      review_view
      |> form("#connection-review-form", %{reason: "attempt after revocation"})
      |> render_submit(%{decision: "rejected"})

      assert Claims.review_state(current.id) == :accepted
    end

    test "an evidence locator without a selected citation fails atomically", ctx do
      ctx = anchor!(ctx)
      %{scope: scope} = register_and_log_in_user(%{conn: ctx.conn})
      before = Repo.aggregate(DevilsDictionary.Claims.Assertion, :count)

      assert {:error, :evidence_required} =
               DevilsDictionary.Claims.Contributions.propose(
                 scope,
                 ctx.meme.object_id,
                 "illustrates",
                 ctx.sense.object_id,
                 %{rationale: "example"},
                 nil,
                 "page 3"
               )

      assert Repo.aggregate(DevilsDictionary.Claims.Assertion, :count) == before
    end
  end
end
