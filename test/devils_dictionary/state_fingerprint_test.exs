defmodule DevilsDictionary.StateFingerprintTest do
  use DevilsDictionary.DataCase, async: true
  alias DevilsDictionary.{Registry, Repo}
  alias DevilsDictionary.Health.StateFingerprint

  test "same row counts cannot hide changed content or revision churn" do
    {:ok, content} = Registry.create_content(%{content_kind: :passage, body: "original"})
    before = StateFingerprint.capture(["content_items", "content_revisions"])

    Repo.query!("UPDATE content_revisions SET body='corrupted' WHERE content_id=$1", [
      content.object_id
    ])

    after_change = StateFingerprint.capture(["content_items", "content_revisions"])
    assert before["content_revisions"]["rows"] == after_change["content_revisions"]["rows"]
    refute before["content_revisions"]["sha256"] == after_change["content_revisions"]["sha256"]
    assert before["content_items"] == after_change["content_items"]
  end

  test "pending relations are fingerprinted, endpoints and provenance included" do
    DevilsDictionary.Claims.Catalog.seed!()
    {:ok, lexeme} = Registry.create_lexeme(%{lemma: "gryphon", part_of_speech: "noun"})

    source =
      Repo.insert!(%DevilsDictionary.Sources.Source{
        slug: "fp-#{System.unique_integer([:positive])}",
        name: "fp",
        tier: :middle,
        kind: :dictionary,
        access: :dump
      })

    Repo.insert!(%DevilsDictionary.Claims.PendingRelation{
      source_id: source.id,
      subject_object_id: lexeme.object_id,
      predicate_id: DevilsDictionary.Claims.predicate!("hypernym").id,
      to_lemma: "chimaera",
      to_pos: "noun",
      metadata: %{"label" => "heraldic"},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    assert "pending_relations" in StateFingerprint.tables()
    before = StateFingerprint.capture(["pending_relations"])

    for change <- [
          "metadata = '{\"label\": \"mythical\"}'",
          "to_lemma = 'sphinx'",
          "to_pos = 'adj'"
        ] do
      Repo.query!("UPDATE pending_relations SET #{change}")
      after_change = StateFingerprint.capture(["pending_relations"])
      assert after_change["pending_relations"]["rows"] == before["pending_relations"]["rows"]
      refute after_change["pending_relations"]["sha256"] == before["pending_relations"]["sha256"]
    end
  end

  test "bookkeeping timestamps do not manufacture semantic changes" do
    {:ok, _} = Registry.create_content(%{content_kind: :passage, body: "same"})
    before = StateFingerprint.capture(["content_revisions"])
    Repo.query!("UPDATE content_revisions SET updated_at=updated_at + interval '1 second'")
    assert before == StateFingerprint.capture(["content_revisions"])
  end
end
