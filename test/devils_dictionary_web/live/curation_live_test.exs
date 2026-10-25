defmodule DevilsDictionaryWeb.CurationLiveTest do
  @moduledoc """
  The owner's curation screen through the real routes (#257 §6, tests
  6–13): an operator surface a reviewer reaches locally and nobody reaches
  through the tunnel; a queue of the pilot pages; an editor that holds the
  lead rule, the three-highlight cap and attribution as the form changes,
  writes through the record's own services, and previews exactly what the
  page will show.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures, only: [account: 1, enabled_default!: 1]

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{ExemplarFixtures, Fixtures, Repo}

  alias DevilsDictionary.Curation.{
    Candidates,
    Composition,
    CompositionItem,
    CompositionPublication,
    CompositionReview,
    CompositionVersion,
    Compositions
  }

  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionaryWeb.CurationLive

  @johnson_note "Johnson's numbered senses, before Bierce turned the word."
  @milton_note "The plainest literary use of the word in the canon."

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)
    reviewer = account([:reviewer])
    {configuration, _version} = enabled_default!(reviewer)

    previous = Application.fetch_env(:devils_dictionary, :curation_pilot_pages)
    Application.put_env(:devils_dictionary, :curation_pilot_pages, ~w(love greed))

    on_exit(fn ->
      case previous do
        {:ok, pages} -> Application.put_env(:devils_dictionary, :curation_pilot_pages, pages)
        :error -> Application.delete_env(:devils_dictionary, :curation_pilot_pages)
      end
    end)

    Map.merge(ctx, %{
      verb: verb,
      reviewer: reviewer,
      contributor: account([:contributor]),
      configuration: configuration,
      candidates: Candidates.for_page(CurationLive.page("love"))
    })
  end

  defp as(conn, %{user: user}), do: log_in_user(conn, user)

  defp editor(ctx, scope \\ nil) do
    {:ok, view, _html} = live(as(ctx.conn, scope || ctx.reviewer), ~p"/ops/curation/on/love")
    view
  end

  # The candidate keys a test picks, by what they are.
  defp key_of(ctx, kind, fun \\ fn _ -> true end) do
    ctx.candidates
    |> Map.fetch!(if kind == :lead, do: :leads, else: :highlights)
    |> Enum.find(&((kind == :lead or &1.kind == kind) and fun.(&1)))
    |> Map.fetch!(:key)
  end

  defp johnson(ctx), do: key_of(ctx, :content, &(&1.spec.object_id == ctx.johnson.object_id))
  defp bierce(ctx), do: key_of(ctx, :lead, &(&1.spec.object_id == ctx.bierce.object_id))

  defp milton(ctx),
    do: key_of(ctx, :sense_quotation, &(&1.text =~ "cordial love"))

  defp change(view, params),
    do: view |> form("#curation-form", %{curation: params}) |> render_change()

  defp submit(view, action),
    do: render_submit(view, "submit", %{"curation" => current(view), "action" => action})

  # What the form holds now, as the browser would send it.
  defp current(view) do
    html = view |> element("#curation-form") |> render() |> LazyHTML.from_fragment()

    checked = fn selector ->
      html |> LazyHTML.query(selector) |> LazyHTML.attribute("value")
    end

    notes =
      html
      |> LazyHTML.query("textarea[name^='curation[notes]']")
      |> Enum.map(fn node ->
        [name] = LazyHTML.attribute(node, "name")
        [_, key] = Regex.run(~r/curation\[notes\]\[(.+)\]/, name)
        {key, LazyHTML.text(node)}
      end)
      |> Map.new()

    %{
      "lead" => List.first(checked.("input[name='curation[lead]'][checked]")),
      "highlights" => checked.("input[name='curation[highlights][]'][checked]"),
      "notes" => notes,
      "reason" => html |> LazyHTML.query("#curation-reason") |> LazyHTML.text(),
      "lead_note" => ""
    }
  end

  defp label(scope),
    do: Actor |> Repo.get_by!(user_id: scope.user.id) |> Compositions.author_label()

  describe "test 6: who reaches it" do
    test "a reviewer reaches both screens locally", ctx do
      conn = as(ctx.conn, ctx.reviewer)
      assert conn |> get(~p"/ops/curation") |> html_response(200) =~ "Curation"
      assert conn |> get(~p"/ops/curation/on/love") |> html_response(200) =~ "On love"
    end

    test "any other account is answered 403, and a visitor is sent to log in", ctx do
      for scope <- [ctx.contributor, account([])] do
        for path <- [~p"/ops/curation", ~p"/ops/curation/on/love"] do
          assert ctx.conn |> as(scope) |> get(path) |> response(403) =~ "Reviewer access"
        end
      end

      assert ctx.conn |> get(~p"/ops/curation") |> redirected_to() == ~p"/users/log-in"
    end

    test "a socket that live-navigates in is held to the reviewer role", ctx do
      # A contributor reaches another operator page in the same live
      # session, and is turned away from the editor at mount.
      {:ok, view, _html} = live(as(ctx.conn, ctx.contributor), ~p"/ops/health")

      assert {:error, {:redirect, %{to: "/"}}} =
               live_redirect(view, to: ~p"/ops/curation/on/love")
    end

    test "through the tunnel both are 404, even to a reviewer", ctx do
      previous = Application.get_env(:devils_dictionary, :published_host)
      Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")

      try do
        for path <- [~p"/ops/curation", ~p"/ops/curation/on/love"] do
          conn =
            ctx.conn
            |> as(ctx.reviewer)
            |> put_req_header("x-forwarded-for", "203.0.113.7")
            |> get(path)

          assert response(conn, 404) =~ "Not Found"
        end
      after
        if previous,
          do: Application.put_env(:devils_dictionary, :published_host, previous),
          else: Application.delete_env(:devils_dictionary, :published_host)
      end
    end
  end

  test "the pilot pages default to #253 D2's ten, and configuration may name others" do
    Application.delete_env(:devils_dictionary, :curation_pilot_pages)

    assert CurationLive.pilot_pages() ==
             ~w(nepotism greed war love coward patience justice truth hope bestiality)

    Application.put_env(:devils_dictionary, :curation_pilot_pages, ~w(war))
    assert CurationLive.pilot_pages() == ~w(war)
  end

  @tag :capture_log
  test "a queue whose pages cannot be read says so and offers another read", ctx do
    Application.put_env(:devils_dictionary, :curation_pilot_pages, [:not_a_slug])
    {:ok, view, _html} = live(as(ctx.conn, ctx.reviewer), ~p"/ops/curation")
    render_async(view)

    assert has_element?(view, "#curation-load-error", "could not be read")
    refute has_element?(view, "#curation-loading")

    Application.put_env(:devils_dictionary, :curation_pilot_pages, ~w(love))
    view |> element("#curation-retry") |> render_click()
    render_async(view)
    assert has_element?(view, "#curation-page-love")
    refute has_element?(view, "#curation-load-error")
  end

  describe "test 7: the queue" do
    test "lists the configured pilot pages with their state and candidate marks", ctx do
      greed = word!(ctx, "greed", ~w(wiktionary johnson), scope: nil)
      entry!(ctx, greed, "wiktionary", body: "A selfish desire for more than is needed.")

      {:ok, view, _html} = live(as(ctx.conn, ctx.reviewer), ~p"/ops/curation")
      render_async(view)

      assert has_element?(view, "#curation-page-love")
      assert has_element?(view, "#curation-page-greed")
      assert has_element?(view, "#curation-page-love-state", "never curated")

      for {mark, present} <- [{"B", true}, {"J", true}, {"Q", true}, {"W", true}, {"E", false}] do
        assert has_element?(
                 view,
                 "#curation-page-love-marks [data-mark='#{mark}'][data-present='#{present}']"
               )
      end

      assert has_element?(
               view,
               "#curation-page-greed-marks [data-mark='B'][data-present='false']"
             )

      assert has_element?(view, "#curation-page-greed-open", "Curate")
      # The Stale tab is #259's (P5); Proposed stays P6's.
      assert has_element?(view, "#tab-stale[href='/ops/curation?tab=stale']", "Stale")
      assert has_element?(view, "#tab-proposed[aria-disabled='true']", "P6")

      # Published by hand, the queue says so on its next read.
      view = editor(ctx)
      change(view, %{reason: "First curation of love."})
      submit(view, "publish")

      {:ok, queue, _html} = live(as(ctx.conn, ctx.reviewer), ~p"/ops/curation")
      render_async(queue)
      assert has_element?(queue, "#curation-page-love-state", "published")
      assert has_element?(queue, "#curation-page-love", "v1 · 0 highlights")

      queue |> element("#tab-published") |> render_click()
      assert has_element?(queue, "#curation-published [id^='curation-published-']", "love")
    end
  end

  describe "test 8: the editor's scope and lead" do
    test "shows the page's words and allows only the Bierce entry to lead", ctx do
      view = editor(ctx)

      assert has_element?(view, "#curation-scope", "love (noun #{ctx.love.object_id}")
      assert has_element?(view, "#curation-scope", "love (verb #{ctx.verb.object_id}")

      assert has_element?(
               view,
               "#curation-shared",
               "Exact-word pages overlap this editing scope and cannot have a separate active lexical-page composition; they do not currently display this composition."
             )

      assert has_element?(view, "#curation-bierce", "Bierce leads")

      assert has_element?(view, "#lead-#{bierce(ctx)} input:not([disabled])[checked]")
      assert has_element?(view, "#lead-#{johnson(ctx)} input[disabled]")
      assert has_element?(view, "#lead-#{johnson(ctx)}-verdict", "Bierce leads")
      assert has_element?(view, "#lead-none input[disabled]")

      # A lead the rule refuses, sent anyway, changes nothing.
      render_change(view, "change", %{"curation" => %{"lead" => johnson(ctx)}})
      assert has_element?(view, "#lead-#{bierce(ctx)} input[checked]")
      refute has_element?(view, "#lead-#{johnson(ctx)} input[checked]")
    end
  end

  describe "test 9: the cap and the reasons" do
    test "a fourth highlight cannot be selected", ctx do
      keys = Enum.filter(ctx.candidates.highlights, &(&1.status == :ok)) |> Enum.map(& &1.key)
      [a, b, c | _] = Enum.reject(keys, &(&1 == bierce(ctx)))
      extra = ExemplarFixtures.person!("A fourth")
      claim = ExemplarFixtures.nominate!(ctx.contributor, extra, ctx.benevolent)
      ExemplarFixtures.decide!(ctx.reviewer, claim)
      view = editor(ctx)
      fourth = "exemplar-#{claim.id}"

      change(view, %{highlights: [a, b, c]})
      assert has_element?(view, "#curation-highlight-count", "3 of 3")
      assert has_element?(view, "#pick-#{fourth}[disabled]")
      assert has_element?(view, "#candidate-#{fourth}-why-not", "Three highlights are chosen")

      # Sent anyway, the fourth is not taken.
      render_change(view, "change", %{"curation" => %{"highlights" => [a, b, c, fourth]}})
      assert has_element?(view, "#curation-highlight-count", "3 of 3")
      refute has_element?(view, "#pick-#{fourth}[checked]")
    end

    test "an empty reason blocks Publish and not Save draft", ctx do
      view = editor(ctx)
      change(view, %{highlights: [johnson(ctx)], reason: "Johnson beside Bierce."})

      assert has_element?(view, "#curation-publish[disabled]")
      refute has_element?(view, "#curation-save-draft[disabled]")
      assert has_element?(view, "#curation-blockers [data-blocker='reason_missing']")

      submit(view, "publish")
      assert Repo.aggregate(CompositionPublication, :count) == 0

      submit(view, "draft")
      assert has_element?(view, "#curation-notice", "Saved version 1 as a draft")
      assert [%CompositionVersion{version: 1}] = Repo.all(CompositionVersion)

      # A written version takes its reason with it; the next act needs its own.
      assert has_element?(view, "#curation-blockers [data-blocker='required']")
      change(view, %{notes: %{johnson(ctx) => @johnson_note}, reason: "Publish the draft."})
      refute has_element?(view, "#curation-publish[disabled]")
    end
  end

  describe "test 10: writing" do
    test "Save draft attributes notes to the reviewer and never to a supplied author", ctx do
      view = editor(ctx)

      render_submit(view, "submit", %{
        "action" => "draft",
        "curation" => %{
          "lead" => bierce(ctx),
          "highlights" => [johnson(ctx)],
          "notes" => %{johnson(ctx) => @johnson_note},
          "note_author" => "Somebody Else",
          "note_author_kind" => "model",
          "reason" => "A first draft."
        }
      })

      assert [version] = Repo.all(CompositionVersion)
      assert version.change_reason == "A first draft."

      reviewer = Repo.get_by!(Actor, user_id: ctx.reviewer.user.id)
      assert version.created_by_actor_id == reviewer.id

      highlight =
        Repo.get_by!(CompositionItem, composition_version_id: version.id, role: :highlight)

      assert highlight.note == @johnson_note
      assert highlight.note_author_kind == :human
      assert highlight.note_author_actor_id == reviewer.id
      assert highlight.note_author_label == label(ctx.reviewer)
      refute highlight.note_author_label == "Somebody Else"

      # Nothing is on the page until it is published.
      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      refute has_element?(page, "#opening")
    end

    test "Publish writes a review and a receipt, and the page shows it next", ctx do
      view = editor(ctx)

      change(view, %{
        highlights: [johnson(ctx), milton(ctx)],
        reason: "Bierce leads; Johnson and Milton beside him."
      })

      change(view, %{
        notes: %{johnson(ctx) => @johnson_note, milton(ctx) => @milton_note}
      })

      submit(view, "publish")
      assert has_element?(view, "#curation-notice", "Published version 1")

      assert [version] = Repo.all(CompositionVersion)
      assert [%CompositionReview{decision: :accepted}] = Repo.all(CompositionReview)

      assert [%CompositionPublication{action: :publish, published_version_id: published}] =
               Repo.all(CompositionPublication)

      assert published == version.id
      assert has_element?(view, "#curation-standing", "Published")
      assert has_element?(view, "#curation-history-version-1", "published")

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      assert has_element?(page, "#opening-lead-text", "A temporary insanity")
      assert has_element?(page, "#opening-highlight-1-note-0", @johnson_note)
      assert has_element?(page, "#opening-highlight-2-note-0", @milton_note)

      assert has_element?(
               page,
               "#opening-highlight-1-note-0-author",
               "Written by #{label(ctx.reviewer)}"
             )
    end
  end

  describe "test 11: withdraw and re-open" do
    test "withdrawal takes it off the page; re-open allows a new version; history lists both",
         ctx do
      view = editor(ctx)
      change(view, %{reason: "Bierce alone."})
      submit(view, "publish")

      # A withdrawal needs its reason.
      view |> form("#curation-withdraw-form", %{withdraw: %{reason: ""}}) |> render_submit()
      assert has_element?(view, "#curation-refusal", "Write a reason to withdraw")
      assert Repo.aggregate(CompositionPublication, :count) == 1

      view
      |> form("#curation-withdraw-form", %{withdraw: %{reason: "wording"}})
      |> render_submit()

      assert has_element?(view, "#curation-notice", "Withdrawn")
      assert has_element?(view, "#curation-state-label", "withdrawn")
      assert has_element?(view, "#curation-reopen")
      assert has_element?(view, "#curation-highlights[disabled]")
      assert has_element?(view, "#curation-publish[disabled]")

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      refute has_element?(page, "#opening")

      view |> element("#curation-reopen") |> render_click()
      refute has_element?(view, "#curation-highlights[disabled]")

      change(view, %{highlights: [johnson(ctx)], reason: "Re-opened with Johnson."})
      change(view, %{notes: %{johnson(ctx) => @johnson_note}})
      submit(view, "draft")

      # Re-opened and saved, the page is a draft again, after a reload too.
      reloaded = editor(ctx)
      assert has_element?(reloaded, "#curation-state-label", "draft v2")
      refute has_element?(reloaded, "#curation-reopen")

      change(view, %{reason: "Publish it."})
      submit(view, "publish")
      assert has_element?(view, "#curation-notice", "Published version 2")

      assert has_element?(view, "#curation-history-version-1", "Bierce alone.")
      assert has_element?(view, "#curation-history-version-2", "from version 1")
      assert has_element?(view, "#curation-history-version-2", "published")
      assert has_element?(view, "[id^='curation-history-receipt-']", "Withdrew version 1")
      assert has_element?(view, "[id^='curation-history-receipt-']", "“wording”")

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      assert has_element?(page, "#opening-highlight-1-note-0", @johnson_note)

      # Another reviewer opening it is told whose note it carries; once they
      # save a version of their own, the note is theirs.
      other = editor(ctx, account([:reviewer]))
      assert has_element?(other, "#note-#{johnson(ctx)}-carried", label(ctx.reviewer))
      change(other, %{reason: "Saved again by another reviewer."})
      change(other, %{notes: %{johnson(ctx) => @johnson_note <> " (Seen.)"}})
      submit(other, "draft")
      assert has_element?(other, "#curation-notice", "Saved version 3")
      refute has_element?(other, "#note-#{johnson(ctx)}-carried")
    end
  end

  describe "test 12: two reviewers" do
    test "publishing from the same previous version: one wins, one sees not_current", ctx do
      other = account([:reviewer])
      first = editor(ctx)
      second = editor(ctx, other)

      change(first, %{reason: "First reviewer."})
      change(second, %{highlights: [johnson(ctx)], reason: "Second reviewer."})
      change(second, %{notes: %{johnson(ctx) => @johnson_note}})

      submit(first, "publish")
      assert has_element?(first, "#curation-notice", "Published version 1")

      submit(second, "publish")
      assert has_element?(second, "#curation-not-current", "not_current")
      assert has_element?(second, "#curation-not-current", "stale_parent")

      assert [%CompositionPublication{}] = Repo.all(CompositionPublication)

      assert [%CompositionVersion{change_reason: "First reviewer."}] =
               Repo.all(CompositionVersion)
    end
  end

  describe "test 12: a pointer that moved" do
    # A draft, then two reviewers: one publishes the draft as it stands, the
    # other edits and publishes from the same pointer.
    defp draft!(ctx, params) do
      view = editor(ctx)
      change(view, params)
      submit(view, "draft")
      assert has_element?(view, "#curation-notice", "Saved version")
    end

    test "the loser writes nothing at all, and cannot write again until it reloads", ctx do
      draft!(ctx, %{reason: "Bierce alone, as a draft."})
      other = account([:reviewer])
      first = editor(ctx)
      second = editor(ctx, other)

      change(first, %{reason: "Publish the draft."})
      submit(first, "publish")
      assert has_element?(first, "#curation-notice", "Published version 1")

      change(second, %{highlights: [johnson(ctx)], reason: "Johnson beside him."})
      change(second, %{notes: %{johnson(ctx) => @johnson_note}})
      submit(second, "publish")

      assert has_element?(second, "#curation-not-current", "stale_pointer")
      assert [%CompositionVersion{version: 1}] = Repo.all(CompositionVersion)
      assert [%CompositionPublication{}] = Repo.all(CompositionPublication)
      assert [%CompositionReview{}] = Repo.all(CompositionReview)

      # A second click is refused by the form, and still writes nothing.
      assert has_element?(second, "#curation-publish[disabled]")
      assert has_element?(second, "#curation-save-draft[disabled]")
      render_submit(second, "submit", %{"curation" => current(second), "action" => "publish"})
      assert has_element?(second, "#curation-not-current")
      assert Repo.aggregate(CompositionVersion, :count) == 1
      assert Repo.aggregate(CompositionPublication, :count) == 1

      # Reloaded, it sees what the other reviewer did.
      second |> element("#curation-reload") |> render_click()
      refute has_element?(second, "#curation-not-current")
      assert has_element?(second, "#curation-state-label", "published")
    end

    test "a held draft that another reviewer replaced is not published over it", ctx do
      draft!(ctx, %{reason: "Bierce alone, as a draft."})
      other = account([:reviewer])
      first = editor(ctx)
      second = editor(ctx, other)

      change(first, %{highlights: [johnson(ctx)], reason: "A second draft."})
      change(first, %{notes: %{johnson(ctx) => @johnson_note}})
      submit(first, "draft")
      assert has_element?(first, "#curation-notice", "Saved version 2")

      change(second, %{reason: "Publish the first draft."})
      submit(second, "publish")

      assert has_element?(second, "#curation-not-current", "stale_parent")
      assert Repo.aggregate(CompositionPublication, :count) == 0
      assert Repo.aggregate(CompositionReview, :count) == 0
    end
  end

  describe "test 13: the preview" do
    test "of a held draft is what publishing it shows, and publishing it writes no copy",
         ctx do
      view = editor(ctx)
      change(view, %{highlights: [milton(ctx)], reason: "A draft with Milton."})
      change(view, %{notes: %{milton(ctx) => @milton_note}})
      submit(view, "draft")

      fresh = editor(ctx)
      change(fresh, %{reason: "Publish the draft as it stands."})
      preview = fresh |> element("#curation-preview-pane #opening") |> render()

      submit(fresh, "publish")
      assert has_element?(fresh, "#curation-notice", "Published version 1")
      assert Repo.aggregate(CompositionVersion, :count) == 1

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      published = page |> element("#opening") |> render()

      assert normalize(preview) == normalize(published),
             inspect(first_difference(normalize(preview), normalize(published)), pretty: true)
    end

    test "a draft whose revision was superseded is published as a new version", ctx do
      view = editor(ctx)
      change(view, %{highlights: [johnson(ctx)], reason: "Johnson beside Bierce."})
      change(view, %{notes: %{johnson(ctx) => @johnson_note}})
      submit(view, "draft")

      {:ok, _newer} =
        DevilsDictionary.Registry.add_content_revision(ctx.johnson.object_id, %{
          body: "1. The passion between the sexes. (A newer reading.)",
          body_format: :markdown,
          headword: "LOVE",
          canonical_url: "https://example.test/entry"
        })

      fresh = editor(ctx)
      change(fresh, %{reason: "Publish on the current revision."})
      submit(fresh, "publish")

      assert has_element?(fresh, "#curation-notice", "Published version 2")

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      assert has_element?(page, "#opening-highlight-1-text", "A newer reading")
    end

    test "is the published rendering of the same selection, modulo ids", ctx do
      person = ExemplarFixtures.person!("Fixture Exemplar")
      claim = ExemplarFixtures.nominate!(ctx.contributor, person, ctx.benevolent)
      ExemplarFixtures.decide!(ctx.reviewer, claim)

      view = editor(ctx)
      exemplar = "exemplar-#{claim.id}"
      work = key_of(ctx, :work)

      change(view, %{highlights: [exemplar, milton(ctx), work], reason: "Three kinds of example."})

      change(view, %{
        notes: %{
          exemplar => "Benevolence, by someone the record names.",
          milton(ctx) => @milton_note,
          work => "Love personified, as the catalog says it depicts."
        }
      })

      assert has_element?(view, "#curation-preview-pane #opening-highlight-1", "Fixture Exemplar")
      assert has_element?(view, "#curation-preview-pane #opening-highlight-3", "Cupid and Psyche")
      preview = view |> element("#curation-preview-pane #opening") |> render()

      submit(view, "publish")
      assert has_element?(view, "#curation-notice", "Published version 1")

      {:ok, page, _html} = live(ctx.conn, ~p"/on/love")
      published = page |> element("#opening") |> render()

      assert normalize(preview) == normalize(published),
             inspect(first_difference(normalize(preview), normalize(published)), pretty: true)
    end
  end

  # Ids are what a preview cannot know: the composition's, until it is
  # provisioned, and the receipt's, until it is written. The section's own
  # class is where the page places it, which the preview pane does not.
  # The page's refresh-clock rows (#259 §2.1) are the composition's, not the
  # selection's, so the preview has none: they are set aside before comparing.
  defp normalize(html) do
    html
    |> String.replace(
      ~r/<div[^>]*class="grid[^"]*">\s*<dt[^>]*>[^<]*<\/dt>\s*<dd id="opening-about-(assessed|checked|changed|next)"[^>]*>.*?<\/dd>\s*<\/div>/s,
      ""
    )
    |> String.replace(~r/^(<section[^>]*?) class="[^"]*"/, "\\1")
    |> String.replace(~r/ · receipt #\d+/, "")
    |> String.replace(~r/#(\d+|—), version/, "#ID, version")
  end

  defp first_difference(a, b) do
    shortest = min(String.length(a), String.length(b))
    n = Enum.find(0..shortest, shortest, &(String.at(a, &1) != String.at(b, &1)))
    {String.slice(a, max(n - 200, 0), 400), String.slice(b, max(n - 200, 0), 400)}
  end

  test "a version's item the screen does not offer is named, not dropped silently", ctx do
    {:ok, composition} =
      Compositions.provision(ctx.reviewer, ctx.configuration.id, %{
        scope_kind: :lexical_page,
        lexeme_ids: [ctx.love.object_id, ctx.verb.object_id],
        language_tag: "en",
        reason: "A poem no seam offers."
      })

    poem =
      "priv/artworks/manifests/poetrydb-v1.json"
      |> DevilsDictionary.Artworks.Corpus.Manifest.load!()
      |> Map.fetch!("rows")
      |> Enum.find(&(&1["title"] == "Summum Bonum"))

    {:ok, _version} =
      Compositions.create_version(ctx.reviewer, composition.id, %{
        lead: DevilsDictionary.CurationFixtures.content_spec(ctx.bierce, ctx.love),
        highlights: [
          %{
            kind: :work,
            catalog: %{
              manifest: "poetrydb-v1",
              checksum: DevilsDictionary.Artworks.Corpus.Manifest.checksum_of("poetrydb-v1"),
              identity: poem["poem_id"]
            },
            meaning: {:lexeme, ctx.love.object_id}
          }
        ],
        reason: "Written through the record.",
        expected_parent: nil
      })

    view = editor(ctx)
    assert has_element?(view, "#curation-notice", "holds 1 item this screen does not offer")
    assert has_element?(view, "#lead-#{bierce(ctx)} input[checked]")
  end

  test "the record is written only through the screen's services", ctx do
    # The arrangement a published version holds is the record's own:
    # provisioned for the page's words, versioned, reviewed and published.
    view = editor(ctx)
    change(view, %{reason: "Bierce alone."})
    submit(view, "publish")

    [composition] = Repo.all(Composition)
    assert composition.scope_kind == :lexical_page

    assert Compositions.member_ids(composition.id) ==
             Enum.sort([ctx.love.object_id, ctx.verb.object_id])

    # Re-using a published arrangement is not a second publication.
    change(view, %{reason: "Again."})
    submit(view, "publish")
    assert has_element?(view, "#curation-refusal[data-reason='already_published']")
    assert Repo.aggregate(CompositionPublication, :count) == 1
  end

  describe "#259: the refresh clock on the screen" do
    alias DevilsDictionary.RefreshFixtures

    defp stale_tab(ctx) do
      {:ok, view, _html} = live(as(ctx.conn, ctx.reviewer), ~p"/ops/curation?tab=stale")
      render_async(view)
      view
    end

    defp public_visit!, do: live(build_conn(), ~p"/on/love")

    test "25: the Stale tab lists each pilot page's clock, and re-open clears a withdrawal's suppression",
         ctx do
      view = editor(ctx)
      change(view, %{reason: "Bierce alone."})
      submit(view, "publish")

      tab = stale_tab(ctx)
      assert has_element?(tab, "#tab-stale[aria-current='page']", "Stale")
      assert has_element?(tab, "#curation-stale-love-why", "never assessed")
      assert has_element?(tab, "#curation-stale-love-assessed", "never")
      assert has_element?(tab, "#curation-stale-love-next", "next visit")

      assert has_element?(
               tab,
               "#curation-stale-greed-why",
               "no composition yet: Curate to start its clock"
             )

      {:ok, _page, _html} = public_visit!()
      RefreshFixtures.drain!()

      tab = stale_tab(ctx)
      assert has_element?(tab, "#curation-stale-love-why", "—")
      assert has_element?(tab, "#curation-stale-love-assessed", "unchanged")
      assert has_element?(tab, "#tab-stale", "0")

      view
      |> form("#curation-withdraw-form", %{withdraw: %{reason: "wording"}})
      |> render_submit()

      assert has_element?(view, "#curation-standing", "not assessed again until you Re-open")

      tab = stale_tab(ctx)

      assert has_element?(
               tab,
               "#curation-stale-love-why",
               "withdrawn: not assessed until re-opened"
             )

      jobs = length(RefreshFixtures.curation_jobs())
      {:ok, _page, _html} = public_visit!()
      assert length(RefreshFixtures.curation_jobs()) == jobs

      view |> element("#curation-reopen") |> render_click()
      assert has_element?(view, "#curation-notice", "its next visit queues one")

      tab = stale_tab(ctx)

      assert has_element?(
               tab,
               "#curation-stale-love-why",
               "input changed: re-opened by the operator"
             )

      {:ok, _page, _html} = public_visit!()
      assert length(RefreshFixtures.curation_jobs()) == jobs + 1

      # Re-opened is remembered: a reloaded editor offers no Re-open again.
      refute has_element?(editor(ctx), "#curation-reopen")
    end

    test "26: after a claim review the editor says the inputs changed, and why", ctx do
      view = editor(ctx)
      change(view, %{reason: "Bierce alone."})
      submit(view, "publish")
      {:ok, _page, _html} = public_visit!()
      RefreshFixtures.drain!()

      fresh = editor(ctx)
      assert has_element?(fresh, "#curation-clock-assessed", "last assessed")
      assert has_element?(fresh, "#curation-clock-assessed", "unchanged")
      refute has_element?(fresh, "#curation-clock-changed")

      person = ExemplarFixtures.person!("Fixture Exemplar")
      claim = ExemplarFixtures.nominate!(ctx.contributor, person, ctx.benevolent)
      ExemplarFixtures.decide!(ctx.reviewer, claim)

      changed = editor(ctx)

      assert has_element?(
               changed,
               "#curation-clock-changed",
               "Inputs changed since the last assessment:"
             )

      assert has_element?(changed, "#curation-clock-changed", "a claim was reviewed")
      assert has_element?(changed, "#curation-clock-changed", "on the page's next visit")

      assert has_element?(
               changed,
               "#curation-shared",
               "they do not currently display this composition"
             )
    end
  end
end
