defmodule DevilsDictionary.Curation.CitationRequestFenceTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  alias DevilsDictionary.{Repo}
  alias DevilsDictionary.Curation.{Refresh, RefreshState}
  @moduletag :unboxed
  @fields [
    :dirty_at,
    :dirty_reason,
    :dirty_seq,
    :shelf_focus,
    :next_retry_at,
    :refresh_generation
  ]
  for state <- [:queued, :running] do
    test "another configuration's #{state} work rejects focus before saving pending state" do
      world = editor_world!()
      before = current(world)
      foreign = foreign!(world, unquote(state))

      assert {:ok, :in_flight} =
               Refresh.request(
                 world.reviewer,
                 world.composition.id,
                 "love",
                 "A focused request while busy",
                 shelf: "news"
               )

      after_row = current(world)
      assert Map.take(after_row, @fields) == Map.take(before || %RefreshState{}, @fields)
      clear!(foreign)

      assert {:ok, :admitted} =
               Refresh.request(
                 world.reviewer,
                 world.composition.id,
                 "love",
                 "Retry after the older work exits",
                 shelf: "news"
               )

      assert current(world).shelf_focus == "news"
      assert claim!(world).shelf_focus == "news"
    end
  end

  test "a busy configuration does not overwrite an existing deferred generation's focus" do
    world = editor_world!()

    assert {:ok, :admitted} =
             Refresh.request(
               world.reviewer,
               world.composition.id,
               "love",
               "Original focused request",
               shelf: "news"
             )

    claim = claim!(world)
    assert {:ok, _} = Refresh.fail(claim, "fixture_offline")
    before = current(world)
    foreign = foreign!(world, :running)

    assert {:ok, :in_flight} =
             Refresh.request(
               world.reviewer,
               world.composition.id,
               "love",
               "A conflicting focused request",
               shelf: "images"
             )

    assert Map.take(current(world), @fields) == Map.take(before, @fields)
    clear!(foreign)

    assert {:ok, :admitted} =
             Refresh.request(
               world.reviewer,
               world.composition.id,
               "love",
               "Retry the original focus",
               shelf: "news"
             )

    assert current(world).shelf_focus == "news"
    assert current(world).refresh_generation == before.refresh_generation
  end

  defp current(world),
    do:
      Repo.get_by(RefreshState,
        composition_id: world.composition.id,
        configuration_version_id: world.editor_version.id
      )

  defp foreign!(world, state) do
    %{rows: [[version]]} =
      Repo.query!(
        "SELECT id FROM curation_configuration_versions WHERE configuration_id=$1 AND id<>$2 ORDER BY id LIMIT 1",
        [world.configuration.id, world.editor_version.id]
      )

    row =
      Repo.get_by(RefreshState,
        composition_id: world.composition.id,
        configuration_version_id: version
      ) || %RefreshState{composition_id: world.composition.id, configuration_version_id: version}

    row
    |> Ecto.Changeset.change(
      state: state,
      run_dirty_seq: 0,
      refresh_generation: 1,
      lease_expires_at: DateTime.add(DateTime.utc_now(), 600),
      lease_attempts: 1,
      admitted_parent_version_id: world.published.version.id
    )
    |> Repo.insert_or_update!()
  end

  defp clear!(row),
    do: row |> Ecto.Changeset.change(state: :idle, lease_expires_at: nil) |> Repo.update!()
end
