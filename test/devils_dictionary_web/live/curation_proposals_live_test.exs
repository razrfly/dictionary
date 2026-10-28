defmodule DevilsDictionaryWeb.CurationProposalsLiveTest do
  @moduledoc """
  #264 §8 tests 28, 30, 32, 33 and 36 through the real routes: the queue's
  Proposed tab and the editor's proposal strip, Take, Edit and Dismiss by
  element id (§2); no bypass on the ordinary form (R13.2–3); the
  disclosure's words (R14.3–5); the attempt page (R16); the Proposals card
  (R17).
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import Ecto.Query

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{
    CompositionPublication,
    CompositionVersion,
    Compositions,
    Configurations,
    LeadPolicy,
    Proposal,
    Proposals,
    PublishedReader,
    Refresh,
    RefreshState
  }

  alias DevilsDictionary.{Fixtures, PacketFixtures, Repo}
  alias DevilsDictionaryWeb.Opening

  setup do
    previous = Application.fetch_env(:devils_dictionary, :curation_pilot_pages)
    Application.put_env(:devils_dictionary, :curation_pilot_pages, ~w(love greed))

    on_exit(fn ->
      case previous do
        {:ok, pages} -> Application.put_env(:devils_dictionary, :curation_pilot_pages, pages)
        :error -> Application.delete_env(:devils_dictionary, :curation_pilot_pages)
      end
    end)

    :ok
  end

  defp as(conn, %{user: user}), do: log_in_user(conn, user)

  defp propose!(world, highlights \\ nil) do
    highlights = highlights || [world.johnson.object_id]
    stub_answer!(world, answer_for(frozen!(), world.bierce.object_id, highlights))
    {:ok, %{last_outcome: :proposed}} = run!(world)
    settle!()
    Repo.one!(from p in Proposal, where: p.state == :pending)
  end

  defp pointer(world), do: Repo.reload!(world.composition).current_published_version_id

  defp editor(conn, world, query \\ ""),
    do: live(as(conn, world.reviewer), "/ops/curation/on/love" <> query)

  defp quality_params(proposal, extra) do
    answers =
      Compositions.items(proposal.version_id)
      |> all_yes()

    %{"quality" => Map.merge(%{"answers" => answers, "note" => "", "reason" => ""}, extra)}
  end

  describe "test 36 (§2): the queue and the editor" do
    test "the Proposed tab lists a pending proposal with its flags, and Review opens it", %{
      conn: conn
    } do
      world = editor_world!()
      {:ok, _} = Compositions.set_mode(world.reviewer, world.composition.id, :mine, [])
      proposal = propose!(world)
      version = Repo.get!(CompositionVersion, proposal.version_id)

      {:ok, queue, _html} = live(as(conn, world.reviewer), ~p"/ops/curation?tab=proposed")
      render_async(queue)

      assert has_element?(queue, "#tab-proposed")
      assert has_element?(queue, "#curation-proposal-#{proposal.id}")

      assert has_element?(
               queue,
               "#curation-proposal-#{proposal.id}-by",
               Configurations.editor_label(world.model_config)
             )

      assert has_element?(
               queue,
               "#curation-proposal-#{proposal.id}-against",
               "v#{world.published.version.version} (yours)"
             )

      assert has_element?(queue, "#curation-proposal-#{proposal.id}-flags [data-flag='mine']")

      refute has_element?(
               queue,
               "#curation-proposal-#{proposal.id}-flags [data-flag='superseded']"
             )

      {:ok, view, _html} =
        queue
        |> element("#curation-proposal-#{proposal.id}-review")
        |> render_click()
        |> follow_redirect(as(conn, world.reviewer))

      assert has_element?(view, "#proposal-strip")
      assert has_element?(view, "#proposal-attempt", "attempt ##{version.attempt_id}")
      assert has_element?(view, "#proposal-offered")
      assert has_element?(view, "#proposal-mine")
    end

    test "Take from the strip publishes the proposal as the owner's version", %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)
      {:ok, view, _html} = editor(conn, world, "?proposal=#{proposal.version_id}")

      assert has_element?(view, "#proposal-take[disabled]")

      view
      |> form("#proposal-form", quality_params(proposal, %{"reason" => "a fair proposal"}))
      |> render_change()

      refute has_element?(view, "#proposal-take[disabled]")

      view
      |> form("#proposal-form", quality_params(proposal, %{"reason" => "a fair proposal"}))
      |> render_submit(%{"action" => "take"})

      settle!()
      assert has_element?(view, "#curation-notice", "Took the proposal")
      taken = Repo.reload!(proposal)
      assert taken.state == :taken
      assert pointer(world) == taken.resolution_version_id
    end

    test "Edit then publish fills the form from the proposal and publishes the edit", %{
      conn: conn
    } do
      world = editor_world!()
      proposal = propose!(world)
      {:ok, view, _html} = editor(conn, world, "?proposal=#{proposal.version_id}")

      view
      |> form("#proposal-form", quality_params(proposal, %{}))
      |> render_change()

      view |> element("#proposal-edit") |> render_click()
      assert has_element?(view, "#proposal-stop-edit")

      # An offered note with whitespace around it is still the editor's, in
      # the preview as in what Edit-publish writes.
      johnson_key = "content-#{world.johnson.object_id}"
      offered = Compositions.items(proposal.version_id) |> Enum.find(&(&1.role == :highlight))

      view
      |> form("#curation-form", %{
        "curation" => %{"notes" => %{johnson_key => "  #{offered.note}  "}}
      })
      |> render_change()

      label = Configurations.editor_label(world.model_config)

      assert has_element?(
               view,
               "#curation-preview-pane #opening-highlight-1-note-0-author",
               "Generated by #{label}, an AI model"
             )

      assert has_element?(view, "#curation-publish", "Publish the edited proposal")
      assert has_element?(view, "#curation-save-draft[disabled]")

      view
      |> form("#curation-form", %{"curation" => %{"reason" => "edited from the screen"}})
      |> render_submit(%{"action" => "publish"})

      settle!()
      assert has_element?(view, "#curation-notice", "Edited the proposal")
      taken = Repo.reload!(proposal)
      assert taken.state == :taken
      version = Repo.get!(CompositionVersion, taken.resolution_version_id)
      assert version.parent_version_id == proposal.version_id
      assert pointer(world) == version.id
    end

    test "Dismiss needs a reason, and records it", %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)
      {:ok, view, _html} = editor(conn, world, "?proposal=#{proposal.version_id}")

      assert has_element?(view, "#proposal-dismiss[disabled]")

      view
      |> form("#proposal-form", %{"quality" => %{"reason" => "thin for this page"}})
      |> render_submit(%{"action" => "dismiss"})

      dismissed = Repo.reload!(proposal)
      assert {dismissed.state, dismissed.resolution_reason} == {:dismissed, "thin for this page"}
      assert has_element?(view, "#curation-notice", "Dismissed the proposal")
      assert pointer(world) == world.published.version.id
    end

    test "marks and Request: keep a published item, set the page mine, request a run", %{
      conn: conn
    } do
      world = editor_world!()
      {:ok, view, _html} = editor(conn, world)
      johnson_key = "content-#{world.johnson.object_id}"

      assert has_element?(view, "#keep-#{johnson_key}")
      view |> element("#keep-#{johnson_key}") |> render_click()
      assert has_element?(view, "#unkeep-#{johnson_key}")
      assert [%{"key" => ^johnson_key}] = Repo.reload!(world.composition).kept_items

      view |> form("#curation-mode-form", %{"mode" => "mine"}) |> render_change()
      assert Repo.reload!(world.composition).mode == :mine
      assert has_element?(view, "#curation-mode-set")

      assert has_element?(view, "#curation-request-button")
      view |> element("#curation-request-button") |> render_click()
      assert has_element?(view, "#curation-notice", "Requested")
      assert row!(world.composition).state == :queued
    end

    test "Request is not offered while the editor is off", %{conn: conn} do
      world = editor_world!(%{}, enable: false)
      {:ok, view, _html} = editor(conn, world)
      refute has_element?(view, "#curation-request")

      {:ok, queue, _html} = live(as(conn, world.reviewer), ~p"/ops/curation?tab=stale")
      render_async(queue)
      refute has_element?(queue, "#curation-request-love")
    end

    test "the queue's Stale tab offers Request while the editor is on", %{conn: conn} do
      world = editor_world!()
      {:ok, queue, _html} = live(as(conn, world.reviewer), ~p"/ops/curation?tab=stale")
      render_async(queue)

      queue |> element("#curation-request-love") |> render_click()
      assert row!(world.composition).state == :queued
      assert row!(world.composition).dirty_reason == "requested"
    end
  end

  describe "test 28 (R13.2–3): no bypass on the ordinary form" do
    test "with a proposal newest, the form opens on the newest manual version and Save parents to the proposal",
         %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)

      {:ok, view, _html} = editor(conn, world)
      assert has_element?(view, "#curation-state-label", "published")

      milton =
        "quotation-#{Compositions.items(world.published.version.id) |> Enum.find(&(&1.item_kind == :sense_quotation)) |> Map.fetch!(:sense_revision_id)}-1"

      assert has_element?(view, "#pick-#{milton}[checked]")

      view
      |> form("#curation-form", %{
        "curation" => %{"reason" => "a new draft", "highlights" => [""]}
      })
      |> render_submit(%{"action" => "draft"})

      settle!()
      draft = Compositions.latest_version(world.composition.id)
      assert draft.origin == :manual
      assert draft.parent_version_id == proposal.version_id
    end

    test "Publish still publishes the held manual version, also after a Dismiss, and never the proposal",
         %{conn: conn} do
      world = editor_world!()

      {:ok, draft} =
        Compositions.create_version(world.author, world.composition.id, %{
          lead: content_spec(world.bierce, world.love),
          highlights: [world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})],
          reason: "a draft",
          expected_parent: world.published.version.id
        })

      proposal = propose!(world, [{world.intense.object_id, "quotation:0"}])
      assert Compositions.latest_version(world.composition.id).id == proposal.version_id
      {:ok, _} = Proposals.dismiss(world.reviewer, proposal.id, reason: "not now")

      {:ok, view, _html} = editor(conn, world)

      view
      |> form("#curation-form", %{"curation" => %{"reason" => "publish the draft"}})
      |> render_submit(%{"action" => "publish"})

      settle!()
      assert pointer(world) == draft.id
      receipt = Repo.one!(from r in CompositionPublication, order_by: [desc: r.id], limit: 1)
      assert receipt.published_version_id == draft.id
    end

    test "Publish publishes the held manual draft while a pending proposal is the newest version",
         %{conn: conn} do
      world = editor_world!()

      {:ok, draft} =
        Compositions.create_version(world.author, world.composition.id, %{
          lead: content_spec(world.bierce, world.love),
          highlights: [world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})],
          reason: "a draft",
          expected_parent: world.published.version.id
        })

      proposal = propose!(world, [{world.intense.object_id, "quotation:0"}])
      assert Compositions.latest_version(world.composition.id).id == proposal.version_id
      assert Compositions.latest_manual_version(world.composition.id).id == draft.id

      {:ok, view, _html} = editor(conn, world)

      view
      |> form("#curation-form", %{"curation" => %{"reason" => "publish the draft"}})
      |> render_submit(%{"action" => "publish"})

      settle!()
      assert pointer(world) == draft.id
      receipt = Repo.one!(from r in CompositionPublication, order_by: [desc: r.id], limit: 1)
      assert receipt.published_version_id == draft.id
      assert Repo.reload!(proposal).state == :pending

      assert Repo.aggregate(
               from(r in DevilsDictionary.Curation.CompositionReview,
                 where: r.composition_version_id == ^proposal.version_id
               ),
               :count
             ) == 0

      assert Repo.aggregate(
               from(p in CompositionPublication,
                 where: p.published_version_id == ^proposal.version_id
               ),
               :count
             ) == 0
    end

    test "a taken version's model notes are not loaded into the ordinary form", %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)

      {:ok, %{version: version}} =
        Proposals.take(world.reviewer, proposal.id,
          reason: "take",
          expected_pointer: pointer(world),
          answers: all_yes(Compositions.items(proposal.version_id))
        )

      {:ok, view, _html} = editor(conn, world)
      assert has_element?(view, "#curation-model-notes")
      johnson_key = "content-#{world.johnson.object_id}"
      assert has_element?(view, "#pick-#{johnson_key}[checked]")
      refute render(view) =~ "It shows the meaning."
      assert Compositions.latest_manual_version(world.composition.id).id == version.id
    end
  end

  describe "test 30 (R14.3–5): the disclosure" do
    defp disclosure(mode, reviewer? \\ false) do
      opening = PublishedReader.opening(page("love"))
      render_component(&Opening.section/1, opening: opening, mode: mode, reviewer?: reviewer?)
    end

    defp text_of(html, id) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id}")
      |> LazyHTML.text()
      |> String.trim()
    end

    test "names the editor, the attempt and the owner after a Take", %{conn: _conn} do
      world = editor_world!()
      proposal = propose!(world)
      attempt_id = Repo.get!(CompositionVersion, proposal.version_id).attempt_id

      {:ok, _} =
        Proposals.take(world.reviewer, proposal.id,
          reason: "take",
          expected_pointer: pointer(world),
          answers: all_yes(Compositions.items(proposal.version_id))
        )

      settle!()
      public = disclosure(:public)
      selected = text_of(public, "opening-about-selected")
      label = Configurations.editor_label(world.model_config)
      assert selected =~ "#{label}, an AI model"
      assert selected =~ "attempt ##{attempt_id}"
      reviewer = Compositions.author_label(actor!(world.reviewer))
      today = Calendar.strftime(Date.utc_today(), "%-d %B %Y")
      assert selected =~ "taken by #{reviewer} on #{today}"
      refute public =~ "/ops/curation/attempts/"

      # Each item the editor chose keeps its note's attribution and names
      # its attempt; the link is the reviewer's only.
      assert public =~ "Generated by #{label}, an AI model, attempt ##{attempt_id}"
      assert text_of(public, "opening-about-revision-1-attempt") == "attempt ##{attempt_id}"

      refute disclosure(:internal) =~ "/ops/curation/attempts/"
      refute disclosure(:public, true) =~ "/ops/curation/attempts/"
      internal = disclosure(:internal, true)
      assert internal =~ ~s(href="/ops/curation/attempts/#{attempt_id}")
    end

    test "the actual reader page exposes attempt links only to a local reviewer", %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)

      {:ok, _} =
        Proposals.take(world.reviewer, proposal.id,
          reason: "take",
          expected_pointer: pointer(world),
          answers: all_yes(Compositions.items(proposal.version_id))
        )

      settle!()
      {:ok, anonymous, _} = live(conn, ~p"/on/love")
      refute has_element?(anonymous, "a[href^='/ops/curation/attempts/']")
      {:ok, contributor, _} = live(as(build_conn(), world.author), ~p"/on/love")
      refute has_element?(contributor, "a[href^='/ops/curation/attempts/']")
      {:ok, reviewer, _} = live(as(build_conn(), world.reviewer), ~p"/on/love")
      assert has_element?(reviewer, "a[href^='/ops/curation/attempts/']")
      previous = Application.get_env(:devils_dictionary, :published_host)
      Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")

      try do
        proxied =
          build_conn() |> as(world.reviewer) |> put_req_header("x-forwarded-for", "203.0.113.7")

        {:ok, view, _} = live(proxied, ~p"/on/love")
        refute has_element?(view, "a[href^='/ops/curation/attempts/']")
      after
        if previous,
          do: Application.put_env(:devils_dictionary, :published_host, previous),
          else: Application.delete_env(:devils_dictionary, :published_host)
      end
    end

    test "says what the editor judged, for each outcome", %{conn: _conn} do
      world = editor_world!()
      visit!()
      {:ok, _row} = work!(world)
      row = row!(world.composition)

      for {outcome, reason, words} <- [
            {:proposed, "written",
             "judged by the editor: it proposed a change, which waits for the owner's review"},
            {:abstained, "abstained",
             "judged by the editor: the candidates were too thin to choose from, so it proposed nothing"},
            {:no_change, "matches_published", "judged by the editor: nothing to change"},
            {:needs_editor, "packet_refused:no_candidates",
             "an editor is needed, but no packet could be built (no_candidates)"}
          ] do
        set!(Repo.reload!(row), last_outcome: outcome, last_outcome_reason: reason)
        assert text_of(disclosure(:public), "opening-about-assessed") =~ words
      end
    end

    test "D3: a fallback lead the editor chose says so; none of the five pages has one" do
      for slug <- ~w(love war hope truth coward) do
        assert Enum.any?(PacketFixtures.shape(slug).entries, &(elem(&1, 0) == "bierce"))
      end

      assert LeadPolicy.statement(:editor_fallback) =~ "selected by the editor to lead"

      %{sources: sources} = Fixtures.seed_catalog!()
      greed = PacketFixtures.pilot!(%{sources: sources}, "greed")
      [johnson] = greed.entries
      reviewer = account([:reviewer])
      {configuration, version} = enabled_default!(reviewer)
      [lexeme | _] = greed.words

      item = %DevilsDictionary.Curation.CompositionItem{
        id: nil,
        role: :lead,
        position: 1,
        item_kind: :content,
        item_object_id: johnson.object_id,
        content_revision_id:
          DevilsDictionary.Registry.current_content_revision(johnson.object_id).id,
        meaning_lexeme_id: lexeme.object_id,
        selection_origin: :model
      }

      opening =
        PublishedReader.arrangement(
          PacketFixtures.page("greed"),
          %{lead: item, highlights: [], withheld: []},
          %{
            composition: %{id: 1, version: 1},
            configuration: configuration,
            configuration_version: version,
            review: %DevilsDictionary.Curation.Opening.Review{state: :published}
          }
        )

      assert Enum.any?(opening.lead.reasons, &(&1.text == LeadPolicy.statement(:editor_fallback)))
    end
  end

  describe "test 32 (R16): the attempt page" do
    test "is a reviewer's, lists what was offered and omitted, and never an excerpt", %{
      conn: conn
    } do
      world = editor_world!()
      proposal = propose!(world)
      attempt_id = Repo.get!(CompositionVersion, proposal.version_id).attempt_id
      frozen = frozen!()

      {:ok, view, html} = live(as(conn, world.reviewer), ~p"/ops/curation/attempts/#{attempt_id}")

      assert has_element?(view, "#attempt-key", "proposal:")
      assert has_element?(view, "#attempt-proposal")

      for c <- frozen.packet["candidates"] do
        assert has_element?(view, "#attempt-offered-#{c["candidate_id"]}")
        refute html =~ (c["excerpt"] || c["label"])
      end

      for o <- frozen.packet["omitted"],
          do: assert(has_element?(view, "#attempt-omitted-#{o["key"]}"))

      assert has_element?(view, "#attempt-choice-lead")

      # Any other account is answered 403.
      assert build_conn()
             |> as(world.author)
             |> get(~p"/ops/curation/attempts/#{attempt_id}")
             |> response(403) =~ "Reviewer access"
    end

    test "is 404 through the tunnel, even to a reviewer", %{conn: conn} do
      world = editor_world!()
      proposal = propose!(world)
      attempt_id = Repo.get!(CompositionVersion, proposal.version_id).attempt_id
      previous = Application.get_env(:devils_dictionary, :published_host)
      Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")

      try do
        conn =
          conn
          |> as(world.reviewer)
          |> put_req_header("x-forwarded-for", "203.0.113.7")
          |> get(~p"/ops/curation/attempts/#{attempt_id}")

        assert response(conn, 404) =~ "Not Found"
      after
        if previous,
          do: Application.put_env(:devils_dictionary, :published_host, previous),
          else: Application.delete_env(:devils_dictionary, :published_host)
      end
    end
  end

  describe "test 33 (R17): the Proposals card" do
    defp rows,
      do:
        for(
          table <-
            ~w(inference_services inference_attempts curation_proposals curation_refresh_states),
          do: Repo.aggregate(table, :count)
        )

    test "renders none and zeros on an empty database, and inserts nothing", %{conn: conn} do
      Fixtures.seed_catalog!()
      before = rows()
      {:ok, view, _html} = live(conn, ~p"/ops/health")

      assert has_element?(view, "#proposals-card-editor", "none: not enabled")
      assert has_element?(view, "#proposals-card-units", "0 pending + 0 reserved of 30")
      assert has_element?(view, "#proposals-card-proposals", "0 pending")
      assert has_element?(view, "#proposals-card-deferral", "none")
      assert rows() == before
    end

    test "renders the record's numbers, and inserts nothing", %{conn: conn} do
      world = editor_world!()
      propose!(world)

      # A deferral: the service down on the next run.
      Req.Test.stub(
        DevilsDictionary.Curation.Runtime.Ollama,
        &Req.Test.transport_error(&1, :econnrefused)
      )

      {:ok, _} =
        Compositions.keep(
          world.reviewer,
          world.composition.id,
          Compositions.items(world.published.version.id) |> hd() |> Map.fetch!(:id),
          []
        )

      {:ok, %RefreshState{state: :deferred}} = run!(world)

      before = rows()
      {:ok, view, _html} = live(conn, ~p"/ops/health")

      assert has_element?(
               view,
               "#proposals-card-editor",
               "enabled for global-default v#{world.editor_version.version}"
             )

      assert has_element?(view, "#proposals-card-units", "1 pending + 0 reserved of 30")

      assert has_element?(
               view,
               "#proposals-card-proposals",
               "1 pending (0 superseded on arrival)"
             )

      assert has_element?(view, "#proposals-card-today", "1 deferred")
      assert has_element?(view, "#proposals-card-deferral", "love · service_unreachable")
      assert rows() == before
    end

    test "today's deferrals exclude yesterday's still-deferred backlog", %{conn: conn} do
      world = editor_world!()

      Req.Test.stub(
        DevilsDictionary.Curation.Runtime.Ollama,
        &Req.Test.transport_error(&1, :econnrefused)
      )

      assert {:ok, deferred} = run!(world)
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -86_400)
      set!(deferred, last_deferred_at: yesterday, updated_at: yesterday)
      before = rows()
      snapshot = Proposals.health_snapshot(now)
      assert snapshot.today.deferred == 0
      assert snapshot.deferred_now == 1
      # A newly changed input is not a new deferral. It advances updated_at
      # while preserving the actual deferral date and the deferred state.
      Refresh.mark_dirty([world.composition.id], "candidate_added")
      dirty = Repo.reload!(deferred)
      assert dirty.state == :deferred
      assert DateTime.compare(dirty.updated_at, yesterday) == :gt
      assert dirty.last_deferred_at == yesterday
      assert Proposals.health_snapshot(now).today.deferred == 0
      assert Proposals.health_snapshot(now).last_deferral.at == yesterday
      {:ok, view, _} = live(conn, ~p"/ops/health")
      assert has_element?(view, "#proposals-card-today", "0 deferred")
      assert has_element?(view, "#proposals-card-deferred-now", "1 pages")
      assert rows() == before
      set!(Repo.reload!(deferred), last_deferred_at: now, updated_at: now)
      assert Proposals.health_snapshot(now).today.deferred == 1
    end

    test "says enabled only while the binding stands, as the step sees it", %{conn: conn} do
      world = editor_world!()
      {:ok, view, _html} = live(conn, ~p"/ops/health")
      assert has_element?(view, "#proposals-card-editor", "enabled for global-default")

      # The editor's profile retired: the switch is still on, the binding
      # no longer stands, and no run would reach the step.
      Repo.update_all(
        from(p in DevilsDictionary.Curation.Profile, where: p.id == ^world.profile.id),
        set: [state: :retired]
      )

      assert Configurations.editor_enabled(world.editor_version.id) == :off
      {:ok, view, _html} = live(conn, ~p"/ops/health")
      assert has_element?(view, "#proposals-card-editor", "none: not enabled")
    end
  end
end
