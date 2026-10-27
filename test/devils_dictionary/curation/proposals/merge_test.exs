defmodule DevilsDictionary.Curation.Proposals.MergeTest do
  @moduledoc """
  #264 §8 tests 17–21: the arrangement a proposal carries (R8, O2, OD-6)
  and the proposal write (R9).
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionVersion,
    Compositions,
    Proposal,
    Proposals,
    Refresh
  }

  alias DevilsDictionary.Curation.Proposals.Merge
  alias DevilsDictionary.Registry

  defp proposals, do: Repo.all(from p in Proposal, order_by: p.id)
  defp versions, do: Repo.aggregate(CompositionVersion, :count)

  defp published_item(world, object_id, version \\ nil) do
    version = version || Repo.reload!(world.composition).current_published_version_id
    Compositions.items(version) |> Enum.find(&(&1.item_object_id == object_id))
  end

  defp keep!(world, item) do
    {:ok, _} = Compositions.keep(world.reviewer, world.composition.id, item.id, [])
  end

  # Five quotations on the benevolent sense, which the cut ranks before
  # profound's: they fill the quotation quota with what the definitions left
  # it, and Milton's line is omitted `over_quota`, love's shape on v2.
  defp crowd_quotations!(world) do
    current = Registry.current_sense_revision(world.benevolent.object_id)

    {:ok, _} =
      Registry.add_sense_revision(world.benevolent.object_id, %{
        gloss: current.gloss,
        position: current.position,
        examples:
          for n <- 1..5 do
            %{
              "type" => "quotation",
              "text" => "Fixture benevolent line #{n}.",
              "ref" => "ref #{n}"
            }
          end
      })
  end

  describe "test 17 (R8.1–2): carry-forward" do
    test "a kept quotation omitted over_quota is carried as a verified copy with the owner's note and signature" do
      world = editor_world!(%{}, publish: false)
      crowd_quotations!(world)
      world = Map.put(world, :published, publish!(world, world.composition))
      milton = published_item(world, world.profound.object_id)
      keep!(world, milton)

      frozen = frozen!()

      assert %{"reason" => "over_quota"} =
               Enum.find(frozen.packet["omitted"], &(&1["object_id"] == world.profound.object_id))

      stub_answer!(world, answer_for(frozen, world.bierce.object_id, [world.johnson.object_id]))
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      settle!()

      [proposal] = proposals()
      items = Compositions.items(proposal.version_id)
      copy = Enum.find(items, &(&1.copied_from_item_id == milton.id))

      assert {copy.role, copy.position} == {:highlight, 1}
      assert copy.selection_origin == :manual

      assert {copy.note, copy.note_author_kind, copy.note_author_label, copy.note_author_actor_id} ==
               {milton.note, :human, milton.note_author_label, milton.note_author_actor_id}

      assert Compositions.reference(copy) == Compositions.reference(milton)
      assert [%{"key" => _, "carried" => true, "item_id" => item_id}] = proposal.carried
      assert item_id == milton.id

      # The editor's choice takes the next place, under its own signature.
      johnson = Enum.find(items, &(&1.item_object_id == world.johnson.object_id))

      assert {johnson.position, johnson.selection_origin, johnson.note_author_kind} ==
               {2, :model, :model}
    end
  end

  describe "test 18 (R8.3): precedence and overflow" do
    defp entry(ref, candidate_id \\ nil, opts \\ []) do
      %{
        ref: ref,
        identity: MapSet.new(Keyword.get(opts, :identity, [{:object, ref}])),
        exemplar?: Keyword.get(opts, :exemplar?, false),
        candidate_id: candidate_id
      }
    end

    test "kept items first, the editor's in the remaining places, the rest overflow" do
      carried = %{lead: entry(:bierce), highlights: [entry(:johnson), entry(:milton)]}

      choices = %{
        lead: entry(:wordnet_def, "c9"),
        highlights: [entry(:congreve, "c4"), entry(:work, "c5"), entry(:other, "c6")]
      }

      merged = Merge.arrange(carried, choices, 3)

      assert merged.lead.ref == :bierce
      assert Enum.map(merged.highlights, & &1.ref) == [:johnson, :milton, :congreve]
      # The editor's lead lost its place to the kept lead; two highlights had none.
      assert merged.overflow == ["c9", "c5", "c6"]
      assert merged.model?
    end

    test "an editor's choice equal to a kept item becomes the kept item, placed once" do
      carried = %{lead: entry(:bierce), highlights: [entry(:johnson)]}

      choices = %{
        lead: entry(:bierce, "c1"),
        highlights: [entry(:johnson, "c2"), entry(:milton, "c3")]
      }

      merged = Merge.arrange(carried, choices, 3)

      assert merged.lead.candidate_id == nil

      assert Enum.map(merged.highlights, &{&1.ref, &1.candidate_id}) == [
               {:johnson, nil},
               {:milton, "c3"}
             ]

      assert merged.overflow == []
    end

    test "a choice showing what a placed item shows is skipped (C6), and a merge of kept items alone proposes nothing" do
      carried = %{
        lead: entry(:bierce),
        highlights: [entry(:passage, nil, identity: [{:object, 7}])]
      }

      choices = %{
        lead: nil,
        highlights: [entry(:exemplar_of_7, "c8", identity: [{:object, 7}], exemplar?: true)]
      }

      merged = Merge.arrange(carried, choices, 3)
      assert Enum.map(merged.highlights, & &1.ref) == [:passage]
      assert merged.overflow == []
      refute merged.model?
    end

    test "the editor's highlights are capped at the configuration version's bound" do
      merged =
        Merge.arrange(
          %{lead: nil, highlights: []},
          %{lead: entry(:bierce, "c1"), highlights: [entry(:a, "c2"), entry(:b, "c3")]},
          1
        )

      assert Enum.map(merged.highlights, & &1.ref) == [:a]
      assert merged.overflow == ["c3"]
    end
  end

  describe "test 19 (R8.4): no proposal when nothing is the editor's or nothing changes" do
    test "kept_only, matches_published and dismissed_duplicate write nothing and release the unit" do
      world = editor_world!()
      frozen = frozen!()
      before = versions()

      # Everything the editor chose is kept already.
      for object_id <- [world.bierce.object_id, world.johnson.object_id],
          do: keep!(world, published_item(world, object_id))

      stub_answer!(world, answer_for(frozen, world.bierce.object_id, [world.johnson.object_id]))
      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:no_change, "kept_only"}
      assert is_nil(row.review_unit_reserved_at)

      # The published arrangement, in the same places.
      for key <- Enum.map(Repo.reload!(world.composition).kept_items, & &1["key"]),
          do: {:ok, _} = Compositions.unkeep(world.reviewer, world.composition.id, key, [])

      stub_answer!(
        world,
        answer_for(frozen, world.bierce.object_id, [
          world.johnson.object_id,
          {world.profound.object_id, "quotation:1"}
        ])
      )

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:no_change, "matches_published"}
      assert versions() == before
      assert proposals() == []

      # Dismissed, then the same arrangement from the same packet.
      stub_answer!(world, answer_for(frozen, world.bierce.object_id, [world.johnson.object_id]))
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      [dismissed] = proposals()
      {:ok, _} = Proposals.dismiss(world.reviewer, dismissed.id, reason: "not yet")

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:no_change, "dismissed_duplicate"}
      assert [_only] = proposals()
      assert Proposals.units_in_use() == 0
    end

    test "the same arrangement on another packet is written" do
      world = editor_world!()
      frozen = frozen!()
      stub_answer!(world, answer_for(frozen, world.bierce.object_id, [world.johnson.object_id]))
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      [dismissed] = proposals()
      {:ok, _} = Proposals.dismiss(world.reviewer, dismissed.id, reason: "not yet")

      # A new quotation joins the packet: another packet hash.
      current = Registry.current_sense_revision(world.intense.object_id)

      {:ok, _} =
        Registry.add_sense_revision(world.intense.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples:
            current.examples ++ [%{"type" => "quotation", "text" => "A new line.", "ref" => "r"}]
        })

      other = frozen!()
      refute other.hash == frozen.hash
      stub_answer!(world, answer_for(other, world.bierce.object_id, [world.johnson.object_id]))
      assert {:ok, %{last_outcome: :proposed}} = run!(world)

      [_dismissed, written] = proposals()
      assert written.arrangement_hash == dismissed.arrangement_hash
      refute written.packet_hash == dismissed.packet_hash
    end
  end

  describe "test 20 (R8.1, R8.5): marks at the write" do
    test "a mark set during the call is honoured at the write" do
      world = editor_world!()
      johnson = published_item(world, world.johnson.object_id)
      frozen = frozen!()

      content =
        answer_for(frozen, world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])

      stub_ollama!(world.model_config,
        chat: fn _request ->
          keep!(world, johnson)
          {:json, answer(content)}
        end
      )

      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      [proposal] = proposals()
      items = Compositions.items(proposal.version_id)
      assert Enum.any?(items, &(&1.copied_from_item_id == johnson.id))
    end

    test "ineligible and absent kept items are not carried, and are listed with their reasons" do
      world = editor_world!()
      v1 = world.published.version
      milton = published_item(world, world.profound.object_id, v1.id)
      johnson = published_item(world, world.johnson.object_id, v1.id)
      keep!(world, milton)
      keep!(world, johnson)

      # Version 2 drops Milton; Johnson's words are then superseded.
      publish!(world, world.composition, v1.id,
        highlights: [world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})]
      )

      {:ok, _} =
        Registry.add_content_revision(world.johnson.object_id, %{
          headword: "LOVE",
          body: "1. The passion between the sexes, revised.",
          source_id: world.johnson.source_id
        })

      frozen = frozen!()

      stub_answer!(
        world,
        answer_for(frozen, world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])
      )

      assert {:ok, %{last_outcome: :proposed}} = run!(world)

      [proposal] = proposals()
      carried = Map.new(proposal.carried, &{&1["key"], &1})

      assert %{"carried" => false, "reason" => "not_in_parent"} =
               carried[Compositions.reference_key(Compositions.reference(milton))]

      assert %{"carried" => false, "reason" => "revision_superseded"} =
               carried[Compositions.reference_key(Compositions.reference(johnson))]
    end
  end

  describe "test 21 (R9): the proposal write" do
    test "a model version by the bot from its attempt, parented to the newest version; the pointer unchanged" do
      world = editor_world!()
      pointer = Repo.reload!(world.composition).current_published_version_id

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      assert {:ok, %{last_outcome: :proposed, last_outcome_reason: "written"}} = run!(world)
      settle!()

      [proposal] = proposals()
      version = Repo.get!(CompositionVersion, proposal.version_id)
      attempt = Repo.get!(DevilsDictionary.Curation.Runtime.Attempt, version.attempt_id)

      assert version.origin == :model
      assert version.created_by_actor_id == world.bot.id
      assert version.parent_version_id == world.published.version.id
      assert version.version == world.published.version.version + 1
      assert {attempt.state, attempt.outcome} == {:completed, :accepted}
      assert proposal.published_parent_version_id == pointer
      refute proposal.superseded_on_arrival
      assert Repo.reload!(world.composition).current_published_version_id == pointer
    end

    test "no published parent is invented: none published, a draft, or after a withdrawal" do
      # Nothing ever published: the proposal is version 1.
      world = editor_world!(%{}, publish: false)

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      [first] = proposals()
      first_version = Repo.get!(CompositionVersion, first.version_id)
      assert {first_version.version, first_version.parent_version_id} == {1, nil}
      assert is_nil(first.published_parent_version_id)

      # A draft, then a proposal at version 3: still nothing published.
      {:ok, _draft} =
        Compositions.create_version(world.author, world.composition.id, %{
          lead: content_spec(world.bierce, world.love),
          highlights: [],
          reason: "a draft",
          expected_parent: first_version.id
        })

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])
      )

      keep_nothing = Repo.reload!(world.composition)
      assert keep_nothing.kept_items == []
      {:ok, _} = Proposals.dismiss(world.reviewer, first.id, reason: "clear the way")
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      second = List.last(proposals())
      assert Repo.get!(CompositionVersion, second.version_id).version == 3
      assert is_nil(second.published_parent_version_id)
    end

    test "after a withdrawal and a re-open, the proposal names no published parent" do
      world = editor_world!()
      withdraw!(world, world.composition)
      Refresh.reopen(world.composition.id)

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      [proposal] = proposals()
      assert is_nil(proposal.published_parent_version_id)
      assert is_nil(Repo.reload!(world.composition).current_published_version_id)
    end

    test "a publication during the call: superseded on arrival, and an older pending proposal is obsolete" do
      world = editor_world!()

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      assert {:ok, _} = run!(world)
      [older] = proposals()

      content =
        answer_for(frozen!(), world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])

      v1 = world.published.version.id

      stub_ollama!(world.model_config,
        chat: fn _request ->
          publish!(world, world.composition, v1,
            highlights: [
              world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})
            ]
          )

          {:json, answer(content)}
        end
      )

      {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "again")

      # A new kept mark, so the run is not a repeat of the pending proposal.
      {:ok, _} =
        Compositions.keep(
          world.reviewer,
          world.composition.id,
          published_item(world, world.bierce.object_id, v1).id,
          []
        )

      assert {:ok, row} = work!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:proposed, "superseded_on_arrival"}

      [older_now, newer] = proposals()
      assert older_now.id == older.id

      assert {older_now.state, older_now.resolution_reason, older_now.obsoleted_by_proposal_id} ==
               {:obsolete, "superseded_by_proposal", newer.id}

      assert newer.superseded_on_arrival
      assert newer.published_parent_version_id == v1
      composition = Repo.get!(Composition, world.composition.id)
      refute composition.current_published_version_id in [v1, newer.version_id]
    end
  end
end
