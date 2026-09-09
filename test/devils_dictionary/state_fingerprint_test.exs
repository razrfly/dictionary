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

  test "bookkeeping timestamps do not manufacture semantic changes" do
    {:ok, _} = Registry.create_content(%{content_kind: :passage, body: "same"})
    before = StateFingerprint.capture(["content_revisions"])
    Repo.query!("UPDATE content_revisions SET updated_at=updated_at + interval '1 second'")
    assert before == StateFingerprint.capture(["content_revisions"])
  end
end
