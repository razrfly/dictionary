defmodule DevilsDictionaryWeb.WordLiveOpeningTest do
  @moduledoc """
  The published opening on the word page, through the real routes (#255 §6,
  tests 9–14): `/on/love` shows what a reviewer published for every *love*,
  `/words/:id/love` is another scope and shows nothing, a withdrawal shows on
  the next request, and no parameter chooses what is shown.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures,
    only: [
      account: 1,
      catalog_spec: 1,
      content_spec: 2,
      enabled_default!: 1,
      key: 1,
      quotation_spec: 2
    ]

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Curation.{Compositions, Published, Publications, Reviews}
  alias DevilsDictionary.{ExemplarFixtures, Fixtures, Registry, Repo}
  alias DevilsDictionary.Sources.Actor

  @johnson_note "Johnson's four senses map the word before Bierce turned it."
  @milton_note "The plainest literary use, so the two leads can be compared."

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)
    reviewer = account([:reviewer])
    {configuration, _version} = enabled_default!(reviewer)

    Map.merge(ctx, %{
      verb: verb,
      author: account([:contributor]),
      reviewer: reviewer,
      configuration: configuration
    })
  end

  defp provision!(ctx, kind, lexemes) do
    {:ok, composition} =
      Compositions.provision(ctx.author, ctx.configuration.id, %{
        scope_kind: kind,
        lexeme_ids: Enum.map(lexemes, & &1.object_id),
        language_tag: "en",
        reason: "P1 #255 test"
      })

    composition
  end

  # Provision, version, review and publish the §5.3 arrangement for `lexemes`.
  defp publish_love!(ctx, kind \\ :lexical_page, lexemes \\ nil) do
    composition = provision!(ctx, kind, lexemes || [ctx.love, ctx.verb])

    {:ok, version} =
      Compositions.create_version(ctx.author, composition.id, %{
        lead: content_spec(ctx.bierce, ctx.love),
        highlights: [
          ctx.johnson |> content_spec(ctx.love) |> Map.put(:note, %{text: @johnson_note}),
          ctx.profound |> quotation_spec(1) |> Map.put(:note, %{text: @milton_note})
        ],
        reason: "P1 #255 test",
        expected_parent: nil
      })

    {:ok, _review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "P1 #255 test",
        idempotency_key: key("review")
      )

    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "P1 #255 test",
        idempotency_key: key("publish"),
        expected_pointer: nil
      )

    %{composition: composition, version: version, receipt: receipt}
  end

  defp label(scope),
    do: Actor |> Repo.get_by!(user_id: scope.user.id) |> Compositions.author_label()

  defp opening_html(view), do: view |> element("#opening") |> render()

  test "reference layout preserves the published version, required credits and compact exact-record receipt",
       ctx do
    publish_love!(ctx)
    {:ok, view, _} = live(ctx.conn, "/on/love?layout=reference")
    assert has_element?(view, "#reference-article")
    assert has_element?(view, "#opening-lead-text", "temporary insanity")
    assert has_element?(view, "#opening-lead-credits")
    assert has_element?(view, "#opening-lead-record-details summary")
    assert has_element?(view, "#opening-lead-record-details", "1911")
    assert has_element?(view, "#opening-lead-receipt a[href*='/on/love/receipt/']")
    assert has_element?(view, "#opening-highlight-1-record-details")
    assert has_element?(view, "#rail-card-johnson[href*='view=records']")
    assert has_element?(view, "#opening-about")
  end

  test "9: with nothing published the article offers its source record", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

    refute has_element?(view, "#opening")
    assert has_element?(view, "#curated-empty")
    assert has_element?(view, "#reference-article #word-rail")
  end

  test "10: a published composition is the opening, in order, signed, with its record", ctx do
    %{composition: composition, receipt: receipt} = publish_love!(ctx)
    {:ok, view, html} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#opening-lead-text", "A temporary insanity curable by marriage")
    assert has_element?(view, "#opening-lead-register", "Satire")

    assert has_element?(
             view,
             "#opening-lead-entry[href*='view=records'][href$='#card-bierce']",
             "Read the whole entry"
           )

    assert has_element?(view, "#opening-highlight-1-register", "Sourced definition")
    assert has_element?(view, "#opening-highlight-1-text", "The passion between the sexes")

    assert has_element?(
             view,
             "#opening-highlight-1-entry[href*='view=records'][href$='#card-johnson']"
           )

    assert has_element?(view, "#opening-highlight-2-text", "cordial love")

    {first, _} = :binary.match(html, ~s(id="opening-highlight-1"))
    {second, _} = :binary.match(html, ~s(id="opening-highlight-2"))
    assert first < second

    author = label(ctx.author)
    reviewer = label(ctx.reviewer)

    for {n, note} <- [{1, @johnson_note}, {2, @milton_note}] do
      assert has_element?(view, "#opening-highlight-#{n}-why summary", "Why this is here")
      assert has_element?(view, "#opening-highlight-#{n}-note-0", note)

      assert has_element?(
               view,
               "#opening-highlight-#{n}-note-0-author",
               "Written by #{author} · reviewed by #{reviewer}"
             )
    end

    # The disclosure is the record's (#255 §2.2), and no fixture copy.
    assert has_element?(view, "#opening-about summary", "How this was curated")

    assert has_element?(
             view,
             "#opening-about-configuration",
             "global-default, version 1 · lead rule bierce_first_v1"
           )

    assert has_element?(view, "#opening-about-selected", "#{author} (operator)")
    assert has_element?(view, "#opening-about-published", "#{reviewer} (operator)")
    assert has_element?(view, "#opening-about-published", "version 1 · receipt ##{receipt.id}")
    assert has_element?(view, "#opening-about-panel", "None: published by the operator")
    assert has_element?(view, "#opening-about-withheld", "Nothing")
    assert has_element?(view, "#opening-about-composition", "##{composition.id}, version 1")

    refute has_element?(view, "#opening-fixture")
    refute has_element?(view, "#opening-about-reviewed")
    refute opening_html(view) =~ "development fixture"
    # The refresh clock's rows (#259 §2.1): this first visit queued the
    # page's first check.
    assert has_element?(view, "#opening-about-assessed", "Never · queued on your visit.")
    assert has_element?(view, "#opening-about-checked", "Just now, against the record.")
    assert has_element?(view, "#opening-about-changed", "Not recorded yet.")
    assert has_element?(view, "#opening-about-next", "Queued now.")

    # The dictionary index links to the full uncurated record.
    assert has_element?(view, "#rail-card-bierce[href*='view=records'][href$='#card-bierce']")
    refute has_element?(view, "#curated-empty")
    {:ok, records, _} = live(ctx.conn, ~p"/on/love?view=records")
    assert has_element?(records, "#card-bierce")
  end

  describe "§2.3: an item withheld since publication" do
    test "a highlight keeps its place, says why, and shows nothing of itself", ctx do
      publish_love!(ctx)
      current = Registry.current_sense_revision(ctx.profound.object_id)

      {:ok, _newer} =
        Registry.add_sense_revision(ctx.profound.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples: current.examples,
          url: current.url,
          source_record_revision_id: current.source_record_revision_id
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

      assert has_element?(view, "#curated-withheld-2", "superseded since selection")
      assert has_element?(view, "#curated-withheld-2", "Nothing was put in its place")
      refute has_element?(view, "#opening-highlight-2")
      refute opening_html(view) =~ "cordial love"
      assert has_element?(view, "#opening-highlight-1-text", "The passion between the sexes")
      assert has_element?(view, "#opening-about-withheld", "Highlight 2: its source revision")
    end

    test "a lead withheld for a Bierce entry keeps its place, and is not replaced", ctx do
      patience = word!(ctx, "patience", ~w(johnson wiktionary), scope: nil)
      johnson = entry!(ctx, patience, "johnson", headword: "PATIENCE", pos: "n. s.")
      wiktionary = entry!(ctx, patience, "wiktionary", body: "The quality of being patient.")
      composition = provision!(ctx, :lexical_page, [patience])

      {:ok, version} =
        Compositions.create_version(ctx.author, composition.id, %{
          lead: content_spec(johnson, patience),
          highlights: [content_spec(wiktionary, patience)],
          reason: "P1 #255 test",
          expected_parent: nil
        })

      {:ok, _} =
        Reviews.decide(ctx.reviewer, version.id, :accepted,
          reason: "P1 #255 test",
          idempotency_key: key("review")
        )

      {:ok, _} =
        Publications.publish(ctx.reviewer, version.id,
          reason: "P1 #255 test",
          idempotency_key: key("publish"),
          expected_pointer: nil
        )

      entry!(ctx, patience, "bierce", body: "fixture later bierce entry")
      {:ok, view, _html} = live(ctx.conn, ~p"/on/patience")

      assert has_element?(view, "#opening-withheld-lead", "only that entry may lead")
      refute has_element?(view, "#opening-lead")
      refute opening_html(view) =~ "fixture later bierce entry"
      assert has_element?(view, "#opening-highlight-1-text", "The quality of being patient")
    end
  end

  test "11: a withdrawal shows on the next request", ctx do
    %{composition: composition, version: version} = publish_love!(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")
    assert has_element?(view, "#opening-lead")

    {:ok, _} =
      Publications.withdraw(ctx.reviewer, composition.id,
        reason: "P1 #255 test",
        idempotency_key: key("withdraw"),
        expected_pointer: version.id
      )

    {:ok, fresh, _html} = live(ctx.conn, ~p"/on/love")
    refute has_element?(fresh, "#opening")
    assert has_element?(fresh, "#curated-empty")
  end

  describe "12: the fixture gate" do
    setup do
      previous = Application.get_env(:devils_dictionary, :curated_opening_fixtures)

      on_exit(fn ->
        Application.put_env(:devils_dictionary, :curated_opening_fixtures, previous)
      end)
    end

    test "with fixtures on, ?opening=fixture is the fixture, with its banner", ctx do
      publish_love!(ctx)
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, true)

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")

      assert has_element?(view, "#opening-fixture", "Development fixture")
      assert has_element?(view, "#opening-about-selection", "not a published composition")
      refute has_element?(view, "#opening-about-published")
    end

    test "with fixtures off, it is the published opening or nothing, never the fixture", ctx do
      Application.put_env(:devils_dictionary, :curated_opening_fixtures, false)

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")
      refute has_element?(view, "#opening")

      publish_love!(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/on/love?opening=fixture")

      assert has_element?(view, "#opening-about-published")
      refute has_element?(view, "#opening-fixture")
    end
  end

  test "13: no parameter chooses a configuration or a composition", ctx do
    %{composition: on} = publish_love!(ctx)
    # Another composition, of the noun alone, published too.
    %{composition: noun} = publish_love!(ctx, :lexeme, [ctx.love])

    {:ok, plain, _html} = live(ctx.conn, ~p"/on/love")
    expected = opening_html(plain)
    assert has_element?(plain, "#opening-about-composition", "##{on.id},")

    for query <- [
          "opening=published",
          "configuration=#{ctx.configuration.id + 1}",
          "configuration=global-default",
          "composition=#{noun.id}",
          "composition=#{on.id}&opening=published&version=2",
          "anything=else"
        ] do
      {:ok, view, _html} = live(ctx.conn, "/on/love?" <> query)
      assert opening_html(view) == expected, "?#{query} changed the opening"
    end

    # Nor can a parameter put a composition on a page whose words are not
    # its scope.
    {:ok, exact, _html} =
      live(ctx.conn, "/words/#{ctx.love.object_id}/love?composition=#{on.id}")

    refute has_element?(exact, "#opening")
  end

  # ── #257: the exemplar, poem, book and artwork tiles ─────────────────────

  @exemplar_note "Benevolence named: someone the record cites for this sense."
  @poem_note "A short poem whose last line turns on the word."
  @book_note "A novel of wanting more than one has."
  @artwork_note "Love personified, as the catalog says it depicts."

  # Provision, version, review and publish `highlights` under Bierce's lead.
  defp publish_highlights!(ctx, highlights) do
    composition = provision!(ctx, :lexical_page, [ctx.love, ctx.verb])

    {:ok, version} =
      Compositions.create_version(ctx.author, composition.id, %{
        lead: content_spec(ctx.bierce, ctx.love),
        highlights: highlights,
        reason: "P2 #257 test",
        expected_parent: nil
      })

    {:ok, _review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "P2 #257 test",
        idempotency_key: key("review")
      )

    {:ok, _receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "P2 #257 test",
        idempotency_key: key("publish"),
        expected_pointer: nil
      )

    composition
  end

  defp committed(name, field, value) do
    "priv/artworks/manifests/#{name}.json"
    |> Manifest.load!()
    |> Map.fetch!("rows")
    |> Enum.find(&(&1[field] == value))
  end

  defp catalog_only(name, identity, note) do
    %{
      kind: :work,
      catalog: %{manifest: name, checksum: Manifest.checksum_of(name), identity: identity},
      meaning: {:lexeme, nil},
      note: %{text: note}
    }
  end

  test "#257 test 14: an exemplar renders with its label, who named it, its sense and reason; a withdrawn claim withholds it",
       ctx do
    person = ExemplarFixtures.person!("Fixture Benefactor")
    claim = ExemplarFixtures.nominate!(ctx.author, person, ctx.benevolent)
    ExemplarFixtures.decide!(ctx.reviewer, claim)
    sense = Registry.current_sense_revision(ctx.benevolent.object_id)

    composition =
      publish_highlights!(ctx, [
        %{
          kind: :exemplar,
          assertion_revision_id: claim.id,
          meaning: {:sense_revision, sense.id},
          note: %{text: @exemplar_note}
        }
      ])

    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

    assert has_element?(view, "#opening-highlight-1-title", "Fixture Benefactor")
    assert has_element?(view, "#opening-highlight-1-named", "Nominated by #{label(ctx.author)}")
    assert has_element?(view, "#opening-highlight-1-named", "accepted")
    assert has_element?(view, "#opening-highlight-1-cited", glosses().benevolent)
    assert has_element?(view, "#opening-highlight-1-note-0", @exemplar_note)
    assert has_element?(view, "#opening-highlight-1-rationale", "fixture rationale")
    assert has_element?(view, "#opening-highlight-1-stage-reviewed", "Accepted")
    assert has_element?(view, "#opening-highlight-1-stage-opening", "Published on")
    assert has_element?(view, "#opening-about-revision-1", "claim revision #{claim.id}")
    refute has_element?(view, "[id^='opening-withheld']")

    # A reviewer takes the acceptance back (the claim workflow decides
    # `accepted`, `disputed` or `rejected`): the example is withheld, says
    # why, and nothing of it is drawn.
    ExemplarFixtures.decide!(ctx.reviewer, claim, "rejected")
    {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

    assert {:ok, %{withheld: [%{role: :highlight, position: 1, reason: :claim_not_accepted}]}} =
             Published.current(composition.id)

    assert has_element?(
             view,
             "#curated-withheld-1",
             "not an example a reviewer has accepted"
           )

    refute has_element?(view, "#opening-highlight-1")
    refute opening_html(view) =~ "Fixture Benefactor"
    assert has_element?(view, "#opening-lead")
  end

  describe "#257 test 15: catalog works" do
    @describetag :tmp_dir
    @describetag :capture_log

    setup do
      previous = Application.get_env(:devils_dictionary, :committed_manifest_root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:devils_dictionary, :committed_manifest_root, previous),
          else: Application.delete_env(:devils_dictionary, :committed_manifest_root)
      end)
    end

    defp works!(ctx) do
      poem = committed("poetrydb-v1", "title", "Summum Bonum")
      book = committed("open-library-v1", "olid", "OL100203W")
      artwork = committed("wikidata-famous-v1", "qid", "Q8777422")

      composition =
        publish_highlights!(ctx, [
          %{
            catalog_only("poetrydb-v1", poem["poem_id"], @poem_note)
            | meaning: {:lexeme, ctx.love.object_id}
          },
          %{
            catalog_only("open-library-v1", "OL100203W", @book_note)
            | meaning: {:lexeme, ctx.love.object_id}
          },
          ctx.love |> catalog_spec() |> Map.put(:note, %{text: @artwork_note})
        ])

      %{poem: poem, book: book, artwork: artwork, composition: composition}
    end

    test "a poem, a book and an artwork render with their credits and licence", ctx do
      %{poem: poem, artwork: artwork} = works!(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

      # The poem: its row's title, poet and length, its source and licence.
      assert has_element?(view, "#opening-highlight-1 h3", "Poem: Summum Bonum")
      assert has_element?(view, "#opening-highlight-1-title", "Summum Bonum")
      assert has_element?(view, "#opening-highlight-1-byline", "Robert Browning")
      assert has_element?(view, "#opening-highlight-1-facts", "#{poem["line_count"]} lines")

      assert has_element?(
               view,
               "#opening-highlight-1-source[href='#{poem["source_url"]}']",
               "Find it at PoetryDB"
             )

      assert has_element?(
               view,
               "#opening-highlight-1-credits",
               "Public domain poetry; API under MIT"
             )

      assert has_element?(view, "#opening-highlight-1-note-0", @poem_note)

      # The book: title, author and year, its public-domain basis, Open Library.
      assert has_element?(view, "#opening-highlight-2-title", "Sister Carrie")
      assert has_element?(view, "#opening-highlight-2-byline", "Theodore Dreiser · 1900")
      assert has_element?(view, "#opening-highlight-2-facts", "Public domain")

      assert has_element?(
               view,
               "#opening-highlight-2-source[href='https://openlibrary.org/works/OL100203W']",
               "Open at Open Library"
             )

      assert has_element?(view, "#opening-highlight-2-credits", "published in or before 1929")

      # The artwork: P1's tile, from the committed row.
      assert view |> element("#opening-highlight-3 img") |> render() =~
               Phoenix.HTML.html_escape(artwork["image_url"]) |> Phoenix.HTML.safe_to_string()

      assert has_element?(view, "#opening-highlight-3-credits", artwork["credit_line"])
      assert has_element?(view, "#opening-highlight-3-note-0", @artwork_note)

      assert has_element?(
               view,
               "#opening-about-revision-1",
               "catalog poetrydb-v1 row #{poem["poem_id"]}"
             )

      refute has_element?(view, "[id^='opening-withheld']")
    end

    test "a changed manifest checksum withholds the work as :catalog_changed",
         %{tmp_dir: root} = ctx do
      %{composition: composition} = works!(ctx)

      # This build's manifests, as files under another root: the poem's and
      # the book's exactly, the artwork's catalog changed.
      for name <- ~w(poetrydb-v1 open-library-v1) do
        path = Path.join([root, "artworks/manifests", "#{name}.json"])
        File.mkdir_p!(Path.dirname(path))

        File.cp!(
          Path.join(:code.priv_dir(:devils_dictionary), "artworks/manifests/#{name}.json"),
          path
        )
      end

      committed_manifest!(root, :not_compiled)
      Application.put_env(:devils_dictionary, :committed_manifest_root, root)

      {:ok, view, _html} = live(ctx.conn, ~p"/on/love")

      # The record withholds it: Eligibility reads the file the page reads.
      assert {:ok, %{withheld: [%{role: :highlight, position: 3, reason: :catalog_changed}]}} =
               Published.current(composition.id)

      assert has_element?(view, "#curated-withheld-3", "its catalog has changed")
      refute has_element?(view, "#opening-highlight-3")
      refute opening_html(view) =~ "Cupid"
      assert has_element?(view, "#opening-highlight-1-title", "Summum Bonum")
      assert has_element?(view, "#opening-highlight-2-title", "Sister Carrie")
    end
  end

  test "14: the exact-word page is another scope and shows nothing", ctx do
    publish_love!(ctx)

    {:ok, on, _html} = live(ctx.conn, ~p"/on/love")
    {:ok, noun, _html} = live(ctx.conn, ~p"/words/#{ctx.love.object_id}/love")
    {:ok, verb, _html} = live(ctx.conn, ~p"/words/#{ctx.verb.object_id}/love")

    assert has_element?(on, "#opening-lead")
    refute has_element?(noun, "#opening")
    refute has_element?(verb, "#opening")
    assert has_element?(noun, "#rail-card-bierce[href*='view=records']")
  end

  describe "#259: the refresh clock on the page" do
    alias DevilsDictionary.Curation.{PublishedReader, RefreshState}
    alias DevilsDictionary.RefreshFixtures

    defp curation_jobs, do: RefreshFixtures.curation_jobs()

    test "23: a plain HTTP visit admits one check; a mount and a burst after it admit none",
         ctx do
      %{composition: composition} = publish_love!(ctx)

      conn = get(ctx.conn, ~p"/on/love")
      assert html_response(conn, 200) =~ ~s(id="opening")
      assert [%{args: %{"slug" => "love"}}] = curation_jobs()

      assert %RefreshState{state: :queued, refresh_generation: 1} =
               Repo.get_by!(RefreshState, composition_id: composition.id)

      {:ok, _view, _html} = live(build_conn(), ~p"/on/love")
      for _ <- 1..5, do: get(build_conn(), ~p"/on/love")

      assert length(curation_jobs()) == 1
    end

    test "an exact-word page and a fixture request admit nothing", ctx do
      publish_love!(ctx)

      get(ctx.conn, ~p"/words/#{ctx.love.object_id}/love")
      get(build_conn(), ~p"/on/love?demo=1")
      assert curation_jobs() == []
    end

    test "24: the disclosure says never before a check, then checked and not judged, in five words",
         ctx do
      %{composition: composition, receipt: receipt} = publish_love!(ctx)

      # Before any visit, the reader has no clock to read.
      page = RefreshFixtures.page("love")
      opening = PublishedReader.opening(page)
      assert opening.review.assessment == nil

      html = render_component(&DevilsDictionaryWeb.Opening.section/1, opening: opening)
      assert html =~ ~r{id="opening-about-assessed"[^>]*>\s*Never\.}
      assert html =~ ~r{id="opening-about-next"[^>]*>\s*On the next visit\.}

      # A visit queues the first check; the worker completes it.
      {:ok, _view, _html} = live(ctx.conn, ~p"/on/love")
      RefreshFixtures.drain!()
      row = Repo.get_by!(RefreshState, composition_id: composition.id)

      {:ok, view, _html} = live(build_conn(), ~p"/on/love")
      published_on = Calendar.strftime(receipt.committed_at, "%-d %B %Y")
      assert has_element?(view, "#opening-about-summary", "Published #{published_on}")

      assert has_element?(
               view,
               "#opening-about-assessed",
               "the inputs were checked, not judged: nothing has changed since this version was accepted."
             )

      assert has_element?(view, "#opening-about-checked", "Just now, against the record.")
      assert has_element?(view, "#opening-about-changed", "Not since this version was accepted.")

      next = Calendar.strftime(row.refresh_after, "%-d %B %Y")

      assert has_element?(
               view,
               "#opening-about-next",
               "After #{next}, or sooner if an input changes."
             )

      # A periodic check is not a judgement either: it says an editor is needed.
      RefreshFixtures.set!(row, refresh_after: RefreshFixtures.ago(1))
      {:ok, _view, _html} = live(build_conn(), ~p"/on/love")
      RefreshFixtures.drain!()

      {:ok, view, _html} = live(build_conn(), ~p"/on/love")

      assert has_element?(
               view,
               "#opening-about-assessed",
               "the inputs were checked, not judged: an editor is needed (the periodic re-assessment came due)."
             )
    end
  end
end
