defmodule DevilsDictionary.Curation.CitationWindowTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  alias DevilsDictionary.Curation.{Configurations, Refresh, ShelfFocus}
  alias DevilsDictionary.Repo

  test "every completion outcome uses the claim's configured 24h,48h or7d window" do
    world = editor_world!()

    for seconds <- [86_400, 172_800, 604_800] do
      current = Repo.reload!(world.configuration)

      assert {:ok, version} =
               Configurations.create_version(world.reviewer, current.id, %{
                 reason: "Fixture assessment window",
                 refresh_window: seconds
               })

      assert {:ok, _} =
               Configurations.activate(world.reviewer, current.id, version.id,
                 reason: "Fixture window activation",
                 idempotency_key: Ecto.UUID.generate(),
                 expected: current.current_version_id
               )

      for outcome <- [
            {:needs_editor, "packet_refused"},
            {:no_change, "pending"},
            {:no_change, "merge_refused"},
            {:abstained, "abstained"},
            {:no_change, "kept_only"},
            {:no_change, "matches_published"},
            {:no_change, "dismissed_duplicate"},
            {:proposed, "written"},
            {:unchanged, "unchanged"},
            {:needs_editor, "inputs_changed"}
          ] do
        assert {:ok, :admitted} =
                 Refresh.request(world.reviewer, world.composition.id, "love", "Fixture request")

        claim = claim!(world)
        inputs = Refresh.inputs(claim, "love")
        assert {:ok, row} = Refresh.complete(claim, inputs, outcome: outcome)
        assert row.configuration_version_id == version.id
        assert DateTime.diff(row.refresh_after, row.last_completed_at) == seconds
      end
    end
  end

  test "a deferred open generation keeps its focus and rejects a different request" do
    world = editor_world!()
    DevilsDictionary.CitationFixtures.observation!(world)
    DevilsDictionary.CitationFixtures.observation!(world, "pexels", namespace: "pexels_photo")

    assert {:ok, :admitted} =
             Refresh.request(
               world.reviewer,
               world.composition.id,
               "love",
               "Fixture focused request",
               shelf: "news"
             )

    claim = claim!(world)

    {:ok, packet} =
      DevilsDictionary.Curation.Runtime.Packet.for_page(
        DevilsDictionary.RefreshFixtures.page("love"),
        instruction_version: "generic-editor-v2",
        generation: claim.generation,
        shelf: "news"
      )

    {:ok, frozen} = DevilsDictionary.Curation.Runtime.Packet.freeze(packet)
    assert {:ok, _} = Refresh.fail(claim, "fixture_offline")

    assert {:error, :shelf_focus_frozen} =
             Refresh.request(
               world.reviewer,
               world.composition.id,
               "love",
               "Different focused request",
               shelf: "images"
             )

    row = DevilsDictionary.RefreshFixtures.row!(world.composition)
    assert row.shelf_focus == "news" and row.refresh_generation == claim.generation

    assert {:ok, :admitted} =
             Refresh.request(world.reviewer, world.composition.id, "love", "Retry the same focus",
               shelf: "news"
             )

    {:ok, again} =
      DevilsDictionary.Curation.Runtime.Packet.for_page(
        DevilsDictionary.RefreshFixtures.page("love"),
        instruction_version: "generic-editor-v2",
        generation: row.refresh_generation,
        shelf: row.shelf_focus
      )

    {:ok, retry} = DevilsDictionary.Curation.Runtime.Packet.freeze(again)
    assert retry.hash == frozen.hash
  end

  test "stable shelf rotation reaches every item within K times ceiling n/slots and a retry is identical" do
    kinds = DevilsDictionary.Curation.Shelf.kinds()

    queue =
      for kind <- kinds,
          n <- 1..5,
          do: %{packet: %{"key" => "#{kind}-#{n}", "shelf" => %{"shelf_kind" => kind}}, sort: n}

    generations = length(kinds) * 3

    offered =
      for generation <- 0..(generations - 1), reduce: MapSet.new() do
        seen ->
          {ordered, _, focus} = ShelfFocus.order(queue, generation, nil, 2)

          assert ShelfFocus.order(queue, generation, nil, 2) ==
                   {ordered, elem(ShelfFocus.order(queue, generation, nil, 2), 1), focus}

          Enum.reduce(Enum.take(ordered, 2), seen, &MapSet.put(&2, &1.packet["key"]))
      end

    assert MapSet.size(offered) == length(queue)
    {ordered, _, focus} = ShelfFocus.order(queue, 7, "news", 2)
    assert focus["focus"] == "news" and focus["source"] == "requested"
    assert Enum.all?(Enum.take(ordered, 2), &(&1.packet["shelf"]["shelf_kind"] == "news"))
  end
end
