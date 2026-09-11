defmodule DevilsDictionaryWeb.EvidenceEffectiveVisibilityTest do
  @moduledoc "Public exact-evidence routes obey both cited and current display policy."

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup %{conn: conn} do
    %{sources: sources} = Fixtures.seed_catalog!()

    reviewer =
      user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()

    %{conn: conn, reviewer_conn: log_in_user(conn, reviewer), sources: sources}
  end

  test "historical evidence obeys subsequent content withdrawal", %{conn: conn} do
    {:ok, content} =
      Registry.create_content(%{content_kind: :passage, body: "WITHDRAWN SECRET PASSAGE"})

    old = Registry.current_content_revision(content.object_id)

    {:ok, _refreshed} =
      Registry.add_content_revision(content.object_id, %{body: "Public corrected passage"})

    {:ok, before_withdrawal, _html} = live(conn, "/evidence/content/#{old.id}")
    assert has_element?(before_withdrawal, "#evidence-body", "WITHDRAWN SECRET PASSAGE")

    {:ok, withdrawn} =
      Registry.add_content_revision(content.object_id, %{
        body: "withdrawn",
        lifecycle_state: :withdrawn
      })

    {:ok, historical, _html} = live(conn, "/evidence/content/#{old.id}")
    refute has_element?(historical, "#evidence-body", "WITHDRAWN SECRET PASSAGE")
    assert has_element?(historical, "#evidence-body", "not publicly displayable")
    assert has_element?(historical, "#evidence-header", "revision #{old.id}")

    {:ok, current, _html} = live(conn, "/evidence/content/#{withdrawn.id}")
    refute has_element?(current, "#evidence-body", "withdrawn")
  end

  test "historical evidence obeys later rights restriction", %{
    conn: conn,
    reviewer_conn: reviewer_conn
  } do
    {:ok, content} =
      Registry.create_content(%{content_kind: :passage, body: "RESTRICTED SECRET PASSAGE"})

    old = Registry.current_content_revision(content.object_id)

    {:ok, _restricted} =
      Registry.add_content_revision(content.object_id, %{
        body: "RESTRICTED SECRET PASSAGE",
        rights_metadata: %{"display" => "none"}
      })

    {:ok, public_view, _html} = live(conn, "/evidence/content/#{old.id}")
    refute has_element?(public_view, "#evidence-body", "RESTRICTED SECRET PASSAGE")
    assert has_element?(public_view, "#evidence-body", "not publicly displayable")

    {:ok, internal_view, _html} = live(reviewer_conn, "/evidence/content/#{old.id}")
    assert has_element?(internal_view, "#evidence-body", "RESTRICTED SECRET PASSAGE")
  end

  test "historical sense stays readable after a refresh but not after withdrawal", ctx do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: "effective-sense-policy",
        part_of_speech: "noun"
      })

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: ctx.sources["wordnet"].id,
        external_key: "effective-sense-policy.n.01",
        gloss: "ORIGINAL SENSE GLOSS"
      })

    old = Registry.current_sense_revision(sense.object_id)
    {:ok, _} = Registry.add_sense_revision(sense.object_id, %{gloss: "Refreshed public gloss"})

    {:ok, refreshed, _html} = live(ctx.conn, "/evidence/sense/#{old.id}")
    assert has_element?(refreshed, "#evidence-body", "ORIGINAL SENSE GLOSS")

    {:ok, withdrawn} =
      Registry.add_sense_revision(sense.object_id, %{
        gloss: "Withdrawn gloss",
        lifecycle_state: :withdrawn
      })

    {:ok, historical, _html} = live(ctx.conn, "/evidence/sense/#{old.id}")
    refute has_element?(historical, "#evidence-body", "ORIGINAL SENSE GLOSS")

    {:ok, current, _html} = live(ctx.conn, "/evidence/sense/#{withdrawn.id}")
    refute has_element?(current, "#evidence-body", "Withdrawn gloss")

    {:ok, internal, _html} = live(ctx.reviewer_conn, "/evidence/sense/#{old.id}")
    assert has_element?(internal, "#evidence-body", "ORIGINAL SENSE GLOSS")
  end

  test "a cited restriction stales review while retaining public citation metadata", ctx do
    {:ok, artifact} =
      Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Evidence artwork"})

    {:ok, meaning} =
      Registry.create_entity(%{entity_kind: :concept, preferred_label: "Evidence meaning"})

    {:ok, evidence} =
      Registry.create_content(%{content_kind: :passage, body: "Exact reviewed body"})

    cited = Registry.current_content_revision(evidence.object_id)
    {:ok, claim} = Claims.assert(artifact.object_id, "illustrates", meaning.object_id)
    revision = Claims.current_revision(claim.id)
    {:ok, _} = Claims.add_evidence(revision.id, %{content_revision_id: cited.id})

    {:ok, review_context} =
      Claims.open_review_context(revision.id, Claims.current_context_items(revision))

    {:ok, _} = Claims.review(revision.id, :accepted, %{review_context_id: review_context.id})

    {:ok, _} =
      Registry.add_content_revision(evidence.object_id, %{
        body: "Exact reviewed body",
        rights_metadata: %{"allow_display" => false}
      })

    assert DevilsDictionary.Claims.Connection.build(claim.id).review == :changed_since_review

    {:ok, exact, _html} = live(ctx.conn, "/evidence/content/#{cited.id}")
    assert has_element?(exact, "#evidence-header", "revision #{cited.id}")
    refute has_element?(exact, "#evidence-body", "Exact reviewed body")
  end
end
