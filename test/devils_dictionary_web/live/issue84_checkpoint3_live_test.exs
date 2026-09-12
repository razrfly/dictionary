defmodule DevilsDictionaryWeb.Issue84Checkpoint3LiveTest do
  @moduledoc "Permanent LiveView regressions for issue #84 checkpoint 3."

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Registry.{WorkDetails}
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()
    user = user_fixture()
    user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))

    {:ok, artifact} =
      Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Needle artifact"})

    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: "meaningneedle",
        part_of_speech: "noun"
      })

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: sources["wordnet"].id,
        external_key: "meaningneedle.n.01",
        gloss: "a test meaning"
      })

    {:ok, support} =
      Registry.create_content(%{
        content_kind: :passage,
        headword: "supportneedle",
        body: "A precise supporting passage."
      })

    {:ok, counter} =
      Registry.create_content(%{
        content_kind: :passage,
        headword: "counterneedle",
        body: "A precise contradicting passage."
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: Scope.for_user(user),
      artifact: artifact,
      sense: sense,
      support: support,
      counter: counter
    }
  end

  test "local-object form warns on duplicates and creates a typed work", ctx do
    {:ok, author} =
      Registry.create_entity(%{entity_kind: :person, preferred_label: "Needle Author"})

    {:ok, view, _html} = live(ctx.conn, ~p"/connect")

    view
    |> form("#local-entity-form", %{
      "entity_kind" => "artifact",
      "target_role" => "subject",
      "preferred_label" => "Needle artifact"
    })
    |> render_change()

    assert has_element?(view, "#duplicate-result-#{ctx.artifact.object_id}")

    view
    |> form("#local-entity-form", %{
      "entity_kind" => "work",
      "target_role" => "subject",
      "preferred_label" => "Needle Work"
    })
    |> render_change()

    view |> form("#author-search", %{"q" => "Needle Author"}) |> render_change()
    view |> element("#composer-author-hit-#{author.object_id}") |> render_click()

    _html =
      view
      |> form("#local-entity-form", %{
        "entity_kind" => "work",
        "target_role" => "subject",
        "preferred_label" => "Needle Work",
        "work_kind" => "painting",
        "original_language" => "zxx",
        "first_published_year" => "2025"
      })
      |> render_submit()

    work = Repo.get_by!(Registry.Entity, preferred_label: "Needle Work")
    assert has_element?(view, "#composer-subject-chosen")
    assert Repo.get!(WorkDetails, work.object_id).first_published_year == 2025
    assert [authorship] = Claims.outgoing(work.object_id, predicate: "authored_by")
    assert authorship.object_object_id == author.object_id
  end

  test "composer saves independent claimant, context, dates, and multiple exact citations", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/connect")

    choose_connection(view, ctx)
    view |> element("#claimant-unknown") |> render_click()

    add_citation(view, ctx.support, "supports", "paragraph 2")
    add_citation(view, ctx.counter, "contradicts", "page 4")
    assert has_element?(view, "#selected-evidence-items > div", "paragraph 2")
    assert has_element?(view, "#selected-evidence-items > div", "page 4")

    {:error, {:live_redirect, %{to: to}}} =
      view
      |> form("#composer-form", %{
        "rationale" => "A bounded, exact interpretation",
        "language_tag" => "en",
        "valid_from" => "2025-01-02",
        "valid_to" => "2025-12-31"
      })
      |> render_submit()

    claim_id = to |> String.split("/") |> List.last() |> String.to_integer()
    assertion = Repo.get!(Claims.Assertion, claim_id)
    claimant = Repo.get!(Actor, assertion.origin_actor_id)
    submitter = Repo.get!(Actor, assertion.submitted_by_actor_id)
    revision = Claims.current_revision(claim_id)

    assert claimant.actor_kind == :unknown
    assert submitter.user_id == ctx.user.id
    refute claimant.id == submitter.id
    assert revision.language_tag == "en"
    assert revision.valid_from == ~U[2025-01-02 00:00:00.000000Z]
    assert revision.valid_to == ~U[2025-12-31 00:00:00.000000Z]
    assert Enum.map(Claims.evidence(revision.id), & &1.evidence_role) == [:contradicts, :supports]

    {:ok, detail, _html} = live(ctx.conn, to)
    assert has_element?(detail, "#connection-evidence a", "Open exact cited revision")
    assert has_element?(detail, "#connection-counterevidence a", "Open exact cited revision")
  end

  test "revision and challenge UI preserve history and recheck stale access", ctx do
    {:ok, claim} =
      Contributions.propose(
        ctx.scope,
        ctx.artifact.object_id,
        "illustrates",
        ctx.sense.object_id,
        %{rationale: "Initial interpretation"},
        [exact(ctx.support, :supports, "paragraph 1")]
      )

    {:ok, edit_view, _html} = live(ctx.conn, ~p"/connections/#{claim.id}/edit")

    {:error, {:live_redirect, %{to: to}}} =
      edit_view
      |> form("#connection-edit-form", %{
        "rationale" => "Revised interpretation",
        "change_reason" => "The description became more precise"
      })
      |> render_submit()

    assert to == "/connections/#{claim.id}"
    assert Claims.current_revision(claim.id).revision_number == 2

    {:ok, stale_view, _html} = live(ctx.conn, ~p"/connections/#{claim.id}/challenge")
    add_citation(stale_view, ctx.counter, "contradicts", "page 9")
    Repo.update!(Ecto.Changeset.change(ctx.user, internal_contributor: false))

    stale_view
    |> form("#connection-challenge-form", %{"change_reason" => "Access was revoked"})
    |> render_submit()

    assert Claims.current_revision(claim.id).revision_number == 2

    challenger =
      user_fixture()
      |> Ecto.Changeset.change(internal_contributor: true)
      |> Repo.update!()

    challenger_conn = log_in_user(build_conn(), challenger)
    {:ok, challenge_view, _html} = live(challenger_conn, ~p"/connections/#{claim.id}/challenge")
    add_citation(challenge_view, ctx.counter, "supports", "page 9")

    {:error, {:live_redirect, %{to: to}}} =
      challenge_view
      |> form("#connection-challenge-form", %{"change_reason" => "The source disagrees"})
      |> render_submit()

    assert to == "/connections/#{claim.id}"
    current = Claims.current_revision(claim.id)
    assert current.revision_number == 3
    assert current.metadata["last_editorial_change"]["action"] == "challenge"
    assert Enum.any?(Claims.evidence(current.id), &(&1.evidence_role == :contradicts))

    assert {:error, {:live_redirect, %{to: ^to}}} =
             live(challenger_conn, ~p"/connections/#{claim.id}/edit")
  end

  test "mutation citation validation is visible and blank duplicate searches stay empty", ctx do
    {:ok, claim} =
      Contributions.propose(
        ctx.scope,
        ctx.artifact.object_id,
        "illustrates",
        ctx.sense.object_id,
        %{rationale: "Initial interpretation"},
        []
      )

    {:ok, edit_view, _html} = live(ctx.conn, ~p"/connections/#{claim.id}/edit")

    edit_view
    |> form("#mutation-evidence-form", %{"locator" => "page 1"})
    |> render_submit()

    assert has_element?(edit_view, "#flash-error", "Choose a source meaning or passage")

    {:ok, composer, _html} = live(ctx.conn, ~p"/connect")

    composer
    |> form("#local-entity-form", %{
      "entity_kind" => "artifact",
      "target_role" => "subject",
      "preferred_label" => "   "
    })
    |> render_change()

    refute has_element?(composer, "[id^='duplicate-result-']")
  end

  test "stable evidence URLs retain exact historical versions and redact restricted text", ctx do
    old = Registry.current_content_revision(ctx.support.object_id)

    {:ok, _new} =
      Registry.add_content_revision(ctx.support.object_id, %{
        headword: "supportneedle",
        body: "A corrected supporting passage."
      })

    {:ok, historical, _html} = live(ctx.conn, ~p"/evidence/content/#{old.id}")
    assert has_element?(historical, "#evidence-header", "historical, not current")
    assert has_element?(historical, "#evidence-body", "A precise supporting passage.")

    {:ok, restricted} =
      Registry.create_content(%{
        content_kind: :passage,
        headword: "restrictedneedle",
        body: "Text that must not be reproduced.",
        rights_metadata: %{"display" => "metadata_only"}
      })

    restricted_revision = Registry.current_content_revision(restricted.object_id)
    {:ok, restricted_view, html} = live(ctx.conn, ~p"/evidence/content/#{restricted_revision.id}")
    assert has_element?(restricted_view, "#evidence-body", "not publicly displayable")
    refute html =~ "Text that must not be reproduced."

    sense_revision = Registry.current_sense_revision(ctx.sense.object_id)
    {:ok, sense_view, _html} = live(ctx.conn, ~p"/evidence/sense/#{sense_revision.id}")
    assert has_element?(sense_view, "#evidence-body", "a test meaning")
  end

  defp choose_connection(view, ctx) do
    view |> form("#subject-search", %{"q" => "Needle artifact"}) |> render_change()
    view |> element("#composer-subject-hit-#{ctx.artifact.object_id}") |> render_click()
    view |> element("#predicate-illustrates") |> render_click()
    view |> form("#object-search", %{"q" => "meaningneedle"}) |> render_change()
    view |> element("#composer-object-hit-#{ctx.sense.object_id}") |> render_click()
  end

  defp add_citation(view, content, role, locator) do
    revision = Registry.current_content_revision(content.object_id)
    query = Repo.get!(Registry.ContentRevision, revision.id).headword

    view |> form("#evidence-search", %{"q" => query}) |> render_change()
    view |> element("#composer-evidence-hit-#{content.object_id}") |> render_click()

    {selector, submitted_role} =
      if has_element?(view, "#evidence-add-form"),
        do: {"#evidence-add-form", role},
        else: {"#mutation-evidence-form", "contradicts"}

    view
    |> form(selector, %{
      "evidence_role" => submitted_role,
      "locator" => locator
    })
    |> render_submit()
  end

  defp exact(content, role, locator) do
    %{
      content_revision_id: Registry.current_content_revision(content.object_id).id,
      evidence_role: role,
      locator: locator
    }
  end
end
