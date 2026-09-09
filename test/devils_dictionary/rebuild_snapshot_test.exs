defmodule DevilsDictionary.RebuildSnapshotTest do
  use DevilsDictionary.DataCase, async: false
  @moduletag :unboxed
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Health.RebuildSnapshot

  test "independent IDs compare equally but changed text fails with identical counts" do
    database = Repo.config()[:database]
    {:ok, first} = Registry.create_content(%{content_kind: :passage, body: "same passage"})
    before = RebuildSnapshot.capture(database)
    DevilsDictionary.DataCase.truncate_all!()
    Repo.query!("SELECT setval(pg_get_serial_sequence('objects','id'), 10000)")
    {:ok, second} = Registry.create_content(%{content_kind: :passage, body: "same passage"})
    refute first.object_id == second.object_id
    assert before == RebuildSnapshot.capture(database)

    Repo.query!("UPDATE content_revisions SET body='different passage' WHERE content_id=$1", [
      second.object_id
    ])

    changed = RebuildSnapshot.capture(database)
    assert before["content"]["rows"] == changed["content"]["rows"]
    refute before["content"]["sha256"] == changed["content"]["sha256"]
  end
end
