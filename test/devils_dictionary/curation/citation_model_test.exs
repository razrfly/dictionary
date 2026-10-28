defmodule DevilsDictionary.Curation.CitationModelTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2]
  alias DevilsDictionary.Curation.{Compositions, Proposals, ItemBasis, Receipt}
  @moduletag :unboxed
  test "the writer proposes sense definitions and frozen linked claims through the same receipt" do
    world = editor_world!()
    entity = DevilsDictionary.WordFixtures.concept!("Q270905", "Model fixture entity")
    DevilsDictionary.WordFixtures.link!(world.love, entity, sense: world.profound)
    frozen = frozen!()
    lead = hd(frozen.packet["candidates"])

    choices =
      for kind <- ["sense_definition", "claim"],
          do: Enum.find(frozen.packet["candidates"], &(&1["kind"] == kind))

    content =
      DevilsDictionary.RuntimeFixtures.selection(
        {lead["candidate_id"], lead["required_meaning"]},
        Enum.map(choices, &{&1["candidate_id"], &1["required_meaning"], nil})
      )

    stub_answer!(world, content)
    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    proposal = Proposals.pending(world.composition.id)
    items = Compositions.items(proposal.version_id)

    for candidate <- choices do
      item = Enum.find(items, &(to_string(&1.item_kind) == candidate["kind"]))
      basis = ItemBasis.get(item.id)
      assert basis.origin == "model"
      assert basis.supplied_sha256 == (candidate["label_sha256"] || candidate["excerpt_sha256"])
    end

    assert {:ok, %{version: taken}} =
             Proposals.take(world.reviewer, proposal.id,
               reason: "These source choices fit the page.",
               expected_pointer: world.published.version.id,
               answers: all_yes(items)
             )

    assert {:ok, receipt} = Receipt.read("love", taken.version)
    assert Enum.all?(receipt.items, &(&1.basis.origin == "model" and &1.status == :shown))
  end

  test "rewritten model reasons retain original evidence and actual note author through keep, another proposal and take" do
    world = editor_world!()
    stub_answer!(world, answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id]))
    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    first = Proposals.pending(world.composition.id)

    original =
      Compositions.items(first.version_id)
      |> Enum.find(&(&1.item_object_id == world.johnson.object_id))
      |> then(&ItemBasis.get(&1.id))

    assert {:ok, %{version: edited}} =
             Proposals.edit_publish(world.reviewer, first.id,
               reason: "An owner-edited arrangement.",
               expected_pointer: world.published.version.id,
               answers: all_yes(Compositions.items(first.version_id)),
               lead:
                 Map.put(content_spec(world.bierce, world.love), :note, %{
                   text: "An owner lead reason."
                 }),
               highlights: [
                 Map.put(content_spec(world.johnson, world.love), :note, %{
                   text: "An owner rewritten reason."
                 })
               ]
             )

    kept =
      Compositions.items(edited.id) |> Enum.find(&(&1.item_object_id == world.johnson.object_id))

    assert ItemBasis.get(kept.id).reason_rewritten
    assert {:ok, _} = Compositions.keep(world.reviewer, world.composition.id, kept.id, [])

    stub_answer!(
      world,
      answer_for(frozen!(), world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])
    )

    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    next = Proposals.pending(world.composition.id)

    assert {:ok, %{version: taken}} =
             Proposals.take(world.reviewer, next.id,
               reason: "Retain the edited source choice.",
               expected_pointer: edited.id,
               answers: all_yes(Compositions.items(next.version_id))
             )

    final =
      Compositions.items(taken.id) |> Enum.find(&(&1.item_object_id == world.johnson.object_id))

    basis = ItemBasis.get(final.id)
    assert basis.reason_rewritten
    assert basis.origin == "model" and basis.attempt_id == original.attempt_id
    assert basis.supplied_sha256 == original.supplied_sha256

    assert final.note == "An owner rewritten reason." and
             final.note_author_actor_id == kept.note_author_actor_id

    assert {:ok, receipt} = Receipt.read("love", taken.version)

    assert Enum.find(receipt.items, &(&1.id == final.id)).reason_author.actor_id ==
             kept.note_author_actor_id
  end
end
