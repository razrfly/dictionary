defmodule Issue73AuditTest do
  use DevilsDictionary.DataCase, async: false
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Encyclopedia.EntityPage
  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    :ok
  end
  defp person(label), do: Registry.create_person(%{preferred_label: label})
  test "rejected biography relationship is hidden from person page" do
    {:ok, p} = person("Audit person")
    {:ok, article} = Registry.create_content(%{content_kind: :article, body: "Audit biography"})
    {:ok, claim} = Claims.assert(article.object_id, "about", p.object_id)
    {:ok, _} = Claims.review(Claims.current_revision(claim.id).id, :rejected)
    assert Claims.incoming(p.object_id, predicate: "about") == []
    assert EntityPage.build(p.object_id).biography == []
  end
  test "merged identity resolves on public person builder" do
    {:ok, old} = person("Old identity")
    {:ok, survivor} = person("Surviving identity")
    {:ok, _} = Registry.merge([old.object_id], survivor.object_id, reason: "Audit merge")
    assert {:merged, _} = Registry.resolve(old.object_id)
    assert EntityPage.build(old.object_id).entity.object_id == survivor.object_id
  end
  test "splitting a claim context opens reconciliation" do
    {:ok, context} = person("Context identity")
    {:ok, first} = person("First identity")
    {:ok, second} = person("Second identity")
    {:ok, work} = Registry.create_work(%{preferred_label: "Audit work"})
    {:ok, claim} = Claims.assert(work.object_id, "authored_by", first.object_id, %{context_object_id: context.object_id})
    {:ok, _} = Registry.split(context.object_id, [first.object_id, second.object_id], reason: "Audit split")
    assert Repo.exists?(from c in "reconciliation_cases", where: c.assertion_id == ^claim.id)
  end
  test "withdrawn content is not displayed in biography" do
    {:ok, p} = person("Audit withdrawn")
    {:ok, article} = Registry.create_content(%{content_kind: :article, body: "Withdrawn text", lifecycle_state: :withdrawn})
    {:ok, _} = Claims.assert(article.object_id, "about", p.object_id)
    {:ok, _} = Registry.add_content_revision(article.object_id, %{body: "Withdrawn text", lifecycle_state: :withdrawn})
    assert EntityPage.build(p.object_id).biography == []
  end
  test "merged input page does not continue presenting a separate identity" do
    {:ok, old} = person("Old display identity")
    {:ok, survivor} = person("Survivor display identity")
    {:ok, _} = Registry.merge([old.object_id], survivor.object_id, reason: "Audit merge")
    assert EntityPage.build(old.object_id).entity.object_id == survivor.object_id
  end
  test "rejected defines relationship is hidden from authored definition summary" do
    {:ok, p} = person("Audit author")
    {:ok, word} = Registry.create_lexeme(%{language_tag: "en", lemma: "auditword", part_of_speech: "noun"})
    {:ok, definition} = Registry.create_content(%{content_kind: :definition, body: "Audit definition"})
    {:ok, _} = Claims.assert(definition.object_id, "authored_by", p.object_id)
    {:ok, claim} = Claims.assert(definition.object_id, "defines", word.object_id)
    {:ok, _} = Claims.review(Claims.current_revision(claim.id).id, :rejected)
    assert Claims.outgoing(definition.object_id, predicate: "defines") == []
    assert hd(EntityPage.build(p.object_id).definitions).defines == nil
  end

  test "changed endpoint text does not display an old review as current acceptance" do
    {:ok, p} = person("Audit reviewed author")
    {:ok, article} = Registry.create_content(%{content_kind: :article, body: "Original biography"})
    {:ok, claim} = Claims.assert(article.object_id, "about", p.object_id)
    revision = Claims.current_revision(claim.id)
    original = Registry.current_content_revision(article.object_id)
    {:ok, context} = Claims.open_review_context(revision.id, [{:subject, [content_revision_id: original.id]}])
    {:ok, _} = Claims.review(revision.id, :accepted, %{review_context_id: context.id})
    {:ok, _} = Registry.add_content_revision(article.object_id, %{body: "Materially changed biography"})
    page = DevilsDictionary.Claims.Connection.build(claim.id)
    assert page.subject.detail == "Materially changed biography"
    refute page.review == :accepted
  end

end
