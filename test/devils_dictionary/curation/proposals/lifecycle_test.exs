defmodule DevilsDictionary.Curation.Proposals.LifecycleTest do
  @moduledoc """
  #264 §8 tests 22–27 and 31: no bypass (R9.6, R13.1), the proposal
  lifecycle (R10), Take and Edit-publish (R11), the quality form (R11.5),
  Dismiss (R12) and the D8 marks (R15).
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionPublication,
    CompositionReview,
    CompositionVersion,
    Compositions,
    Proposal,
    Proposals,
    Publications,
    Reviews
  }

  alias DevilsDictionary.Curation.Proposals.QualityForm

  setup do
    world = editor_world!()
    frozen = frozen!()
    Map.put(world, :frozen, frozen)
  end

  defp propose!(world, highlights \\ nil) do
    highlights = highlights || [world.johnson.object_id]
    stub_answer!(world, answer_for(world.frozen, world.bierce.object_id, highlights))
    {:ok, %{last_outcome: :proposed}} = run!(world)
    settle!()
    Repo.one!(from p in Proposal, where: p.state == :pending)
  end

  defp items(proposal), do: Compositions.items(proposal.version_id)
  defp pointer(world), do: Repo.reload!(world.composition).current_published_version_id

  defp published_item(world, object_id) do
    world |> pointer() |> Compositions.items() |> Enum.find(&(&1.item_object_id == object_id))
  end

  describe "test 22 (R9.6, R13.1): no bypass" do
    test "the step writes no review or receipt; a model version is never accepted or published",
         world do
      counts = fn ->
        {Repo.aggregate(CompositionReview, :count),
         Repo.aggregate(CompositionPublication, :count)}
      end

      before = counts.()
      proposal = propose!(world)
      assert counts.() == before

      assert {:error, :proposal_needs_take} =
               Reviews.decide(world.reviewer, proposal.version_id, :accepted,
                 reason: "accept it",
                 idempotency_key: key("review")
               )

      assert {:error, :proposal_not_publishable} =
               Publications.publish(world.reviewer, proposal.version_id,
                 reason: "publish it",
                 idempotency_key: key("publish"),
                 expected_pointer: pointer(world)
               )

      version = Repo.get!(CompositionVersion, proposal.version_id)
      reviewer = actor!(world.reviewer)

      # The database refuses an acceptance of a model version.
      assert {:refused, _code, message} =
               refused(fn ->
                 Repo.insert!(%CompositionReview{
                   composition_id: version.composition_id,
                   composition_version_id: version.id,
                   reviewer_actor_id: reviewer.id,
                   decision: :accepted,
                   reason: "direct",
                   reviewed_eligibility_fingerprint: version.eligibility_fingerprint,
                   idempotency_key: key("direct-review")
                 })
               end)

      assert message =~ "model version is never accepted"

      # And a publication of one, even past the review guard.
      Repo.query!(
        "ALTER TABLE editorial_composition_reviews DISABLE TRIGGER editorial_composition_reviews_guard"
      )

      review =
        Repo.insert!(%CompositionReview{
          composition_id: version.composition_id,
          composition_version_id: version.id,
          reviewer_actor_id: reviewer.id,
          decision: :accepted,
          reason: "direct",
          reviewed_eligibility_fingerprint: version.eligibility_fingerprint,
          idempotency_key: key("direct-review")
        })

      Repo.query!(
        "ALTER TABLE editorial_composition_reviews ENABLE TRIGGER editorial_composition_reviews_guard"
      )

      assert {:refused, _code, message} =
               refused(fn ->
                 Repo.insert!(%CompositionPublication{
                   composition_id: version.composition_id,
                   action: :publish,
                   authority_kind: :operator,
                   previous_version_id: pointer(world),
                   published_version_id: version.id,
                   authorizing_review_id: review.id,
                   actor_id: reviewer.id,
                   reason: "direct",
                   eligibility_fingerprint: version.eligibility_fingerprint,
                   idempotency_key: key("direct-publish")
                 })
               end)

      assert message =~ "model version is never published"

      # A rejection stays allowed: it is how a proposal is dismissed.
      assert {:ok, %CompositionReview{decision: :rejected}} =
               Reviews.decide(world.reviewer, version.id, :rejected,
                 reason: "no",
                 idempotency_key: key("reject")
               )
    end
  end

  describe "test 23 (R10): the lifecycle" do
    test "one transition, identity fixed, no delete, one pending per page, a human reviewer to resolve",
         world do
      proposal = propose!(world)
      contributor = actor!(world.author)

      assert {:refused, _, _} =
               refused(fn ->
                 Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id),
                   set: [packet_hash: "another"]
                 )
               end)

      assert {:refused, _, _} =
               refused(fn -> Repo.delete_all(from p in Proposal, where: p.id == ^proposal.id) end)

      # A dismissal by someone who is no reviewer, or without a rejected
      # review, or a Take without the manual version that took it.
      {:ok, rejection} =
        Reviews.decide(world.reviewer, proposal.version_id, :rejected,
          reason: "no",
          idempotency_key: key("reject")
        )

      for set <- [
            [
              state: :dismissed,
              resolved_at: DateTime.utc_now(),
              resolved_by_actor_id: contributor.id,
              resolution_reason: "x",
              resolution_review_id: rejection.id
            ],
            [
              state: :taken,
              resolved_at: DateTime.utc_now(),
              resolved_by_actor_id: actor!(world.reviewer).id,
              resolution_version_id: world.published.version.id,
              quality_form: %{}
            ]
          ] do
        assert {:refused, _, _} =
                 refused(fn ->
                   Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id), set: set)
                 end)
      end

      {:ok, dismissed} = Proposals.dismiss(world.reviewer, proposal.id, reason: "not this")
      assert dismissed.state == :dismissed

      # Once resolved, never again.
      assert {:refused, _, _} =
               refused(fn ->
                 Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id),
                   set: [
                     state: :obsolete,
                     resolution_reason: "again",
                     resolved_by_actor_id: nil,
                     resolution_review_id: nil
                   ]
                 )
               end)

      assert %{rows: [[definition]]} =
               Repo.query!(
                 "SELECT indexdef FROM pg_indexes WHERE indexname = 'curation_proposals_one_pending_index'"
               )

      assert definition =~ "UNIQUE" and definition =~ "WHERE (state = 'pending'::text)"
    end
  end

  describe "test 24 (R11.1–4): Take" do
    test "a manual version parented to the proposal, copies keeping who wrote them, published with the compare-and-switch",
         world do
      milton = published_item(world, world.profound.object_id)
      {:ok, _} = Compositions.keep(world.reviewer, world.composition.id, milton.id, [])
      proposal = propose!(world)
      offered = items(proposal)

      assert {:error, {:stale_pointer, _}} =
               Proposals.take(world.reviewer, proposal.id,
                 reason: "take",
                 expected_pointer: nil,
                 answers: all_yes(offered)
               )

      assert {:ok, %{version: version, receipt: receipt, proposal: taken}} =
               Proposals.take(world.reviewer, proposal.id,
                 reason: "a fair proposal",
                 expected_pointer: pointer(world),
                 answers: all_yes(offered),
                 note: "good"
               )

      settle!()

      assert version.origin == :manual
      assert version.parent_version_id == proposal.version_id
      assert version.created_by_actor_id == actor!(world.reviewer).id
      assert version.arrangement_hash == proposal.arrangement_hash
      assert receipt.published_version_id == version.id
      assert pointer(world) == version.id

      assert {taken.state, taken.resolution_version_id} == {:taken, version.id}
      assert QualityForm.complete?(taken.quality_form)
      assert taken.quality_form["note"] == "good"

      for {copy, source} <- Enum.zip(Compositions.items(version.id), offered) do
        assert copy.copied_from_item_id == source.id

        assert Map.take(copy, [
                 :selection_origin,
                 :note,
                 :note_author_kind,
                 :note_author_label,
                 :note_author_actor_id
               ]) ==
                 Map.take(source, [
                   :selection_origin,
                   :note,
                   :note_author_kind,
                   :note_author_label,
                   :note_author_actor_id
                 ])
      end

      carried =
        Enum.find(
          Compositions.items(version.id),
          &(&1.item_object_id == world.profound.object_id)
        )

      assert {carried.selection_origin, carried.note_author_kind} == {:manual, :human}

      model =
        Enum.find(Compositions.items(version.id), &(&1.item_object_id == world.johnson.object_id))

      assert {model.selection_origin, model.note_author_kind, model.note_author_actor_id} ==
               {:model, :model, world.bot.id}
    end

    test "is refused for a proposal that is not the newest version, and for one missing a kept item",
         world do
      proposal = propose!(world)

      # The owner keeps Johnson now; the proposal has it, so Take stands. Milton
      # it lacks.
      milton = published_item(world, world.profound.object_id)
      {:ok, _} = Compositions.keep(world.reviewer, world.composition.id, milton.id, [])

      assert {:error, {:kept_item_missing, key}} =
               Proposals.take(world.reviewer, proposal.id,
                 reason: "take",
                 expected_pointer: pointer(world),
                 answers: all_yes(items(proposal))
               )

      assert key == Compositions.reference_key(Compositions.reference(milton))

      # A draft saved after it: no longer the newest version.
      {:ok, draft} =
        Compositions.create_version(world.author, world.composition.id, %{
          lead: content_spec(world.bierce, world.love),
          highlights: [],
          reason: "a draft",
          expected_parent: proposal.version_id
        })

      assert {:error, {:stale_parent, newest}} =
               Proposals.take(world.reviewer, proposal.id,
                 reason: "take",
                 expected_pointer: pointer(world),
                 answers: all_yes(items(proposal))
               )

      assert newest == draft.id

      # Dismiss stays open.
      assert {:ok, %Proposal{state: :dismissed}} =
               Proposals.dismiss(world.reviewer, proposal.id, reason: "a draft replaced it")
    end
  end

  describe "test 25 (R11.3): Edit then publish" do
    test "items kept as offered are copies, a rewritten note and an added item are the owner's",
         world do
      proposal = propose!(world)
      lead = Enum.find(items(proposal), &(&1.role == :lead))
      johnson = Enum.find(items(proposal), &(&1.role == :highlight))
      reviewer = actor!(world.reviewer)

      congreve =
        quotation_spec(world.intense, 0) |> Map.put(:note, %{text: "Congreve, the owner's pick."})

      lead_spec = world.bierce |> content_spec(world.love) |> Map.put(:note, %{text: lead.note})

      johnson_spec =
        world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "My own words."})

      assert {:ok, %{version: version}} =
               Proposals.edit_publish(world.reviewer, proposal.id,
                 lead: lead_spec,
                 highlights: [johnson_spec, congreve],
                 reason: "edited",
                 expected_pointer: pointer(world),
                 answers: all_yes([lead, johnson])
               )

      settle!()
      taken = Compositions.items(version.id)
      l = Enum.find(taken, &(&1.role == :lead))
      [j, c] = taken |> Enum.filter(&(&1.role == :highlight)) |> Enum.sort_by(& &1.position)

      assert l.copied_from_item_id == lead.id

      assert {l.note_author_kind, l.note_author_actor_id, l.selection_origin} ==
               {:model, world.bot.id, :model}

      assert is_nil(j.copied_from_item_id)

      assert {j.note, j.note_author_kind, j.note_author_actor_id, j.selection_origin} ==
               {"My own words.", :human, reviewer.id, :manual}

      assert is_nil(c.copied_from_item_id)

      assert {c.note_author_kind, c.note_author_actor_id, c.selection_origin} ==
               {:human, reviewer.id, :manual}

      assert version.parent_version_id == proposal.version_id
      refute version.arrangement_hash == proposal.arrangement_hash
      assert Repo.reload!(proposal).state == :taken
    end
  end

  describe "test 26 (R11.5, R12): the quality form" do
    test "Take and Edit refuse an incomplete form; a reason-only Dismiss is valid and does not count; the export renders",
         world do
      proposal = propose!(world)
      [lead | _] = offered = items(proposal)
      partial = %{QualityForm.slot(lead) => %{"relevant" => "yes"}}

      for answers <- [nil, partial] do
        assert {:error, :quality_form_incomplete} =
                 Proposals.take(world.reviewer, proposal.id,
                   reason: "take",
                   expected_pointer: pointer(world),
                   answers: answers
                 )

        assert {:error, :quality_form_incomplete} =
                 Proposals.edit_publish(world.reviewer, proposal.id,
                   lead: content_spec(world.bierce, world.love),
                   highlights: [],
                   reason: "edit",
                   expected_pointer: pointer(world),
                   answers: answers
                 )
      end

      # A partial form is refused on Dismiss too; none is fine.
      assert {:error, :quality_form_incomplete} =
               Proposals.dismiss(world.reviewer, proposal.id, reason: "no", answers: partial)

      {:ok, dismissed} = Proposals.dismiss(world.reviewer, proposal.id, reason: "not useful")
      assert is_nil(dismissed.quality_form)
      refute QualityForm.counts?(dismissed)

      # A dismissal with the full form counts.
      Repo.update_all(from(c in Composition, where: c.id == ^world.composition.id),
        set: [kept_items: []]
      )

      second = propose!(world, [{world.intense.object_id, "quotation:0"}])

      {:ok, counted} =
        Proposals.dismiss(world.reviewer, second.id,
          reason: "thin",
          answers: all_yes(items(second)),
          note: "fine, but no"
        )

      assert QualityForm.counts?(counted)

      markdown = Proposals.export_forms()
      assert markdown =~ "## Quality forms"
      assert markdown =~ "2 resolved proposals; 1 with a complete form"
      assert markdown =~ "| Item | What | relevant to the word |"
      assert markdown =~ "Decision: dismissed: thin"

      assert markdown =~
               "| lead | content-#{world.bierce.object_id} (the editor's) | yes | yes | yes | yes | yes |"

      assert length(offered) == 2
    end
  end

  describe "test 27 (R12): Dismiss" do
    test "writes a rejected review with its reason and resolves the proposal; a blank reason is refused",
         world do
      proposal = propose!(world)

      assert {:error, {:required, :reason}} =
               Proposals.dismiss(world.reviewer, proposal.id, reason: " ")

      assert {:error, :unauthorized} = Proposals.dismiss(world.author, proposal.id, reason: "no")

      {:ok, dismissed} =
        Proposals.dismiss(world.reviewer, proposal.id, reason: "not for this page")

      review = Repo.get!(CompositionReview, dismissed.resolution_review_id)

      assert {review.decision, review.reason, review.composition_version_id} ==
               {:rejected, "not for this page", proposal.version_id}

      assert {dismissed.state, dismissed.resolution_reason, dismissed.resolved_by_actor_id} ==
               {:dismissed, "not for this page", actor!(world.reviewer).id}

      assert dismissed.arrangement_hash == proposal.arrangement_hash
      assert dismissed.packet_hash == proposal.packet_hash
    end
  end

  describe "test 31 (R15): the owner's marks" do
    test "are a reviewer's, in code and by the database, and write no version or item", world do
      johnson = published_item(world, world.johnson.object_id)

      counts = fn ->
        {Repo.aggregate(CompositionVersion, :count), Repo.aggregate(CompositionItem, :count)}
      end

      before = counts.()

      assert {:error, :unauthorized} =
               Compositions.keep(world.author, world.composition.id, johnson.id, [])

      assert {:error, :unauthorized} =
               Compositions.set_mode(world.author, world.composition.id, :mine, [])

      contributor = actor!(world.author)

      assert {:refused, _, _} =
               refused(fn ->
                 Repo.update_all(from(c in Composition, where: c.id == ^world.composition.id),
                   set: [
                     mode: :mine,
                     mode_set_by_actor_id: contributor.id,
                     mode_set_at: DateTime.utc_now()
                   ]
                 )
               end)

      assert {:refused, _, _} =
               refused(fn ->
                 Repo.update_all(from(c in Composition, where: c.id == ^world.composition.id),
                   set: [
                     kept_items: [
                       %{
                         "key" => "x",
                         "marked_by_actor_id" => contributor.id,
                         "marked_at" => "2026-10-27T00:00:00Z"
                       }
                     ]
                   ]
                 )
               end)

      {:ok, kept} = Compositions.keep(world.reviewer, world.composition.id, johnson.id, [])
      {:ok, mine} = Compositions.set_mode(world.reviewer, world.composition.id, :mine, [])
      settle!()

      assert [%{"key" => key, "marked_by_actor_id" => by}] = kept.kept_items
      assert key == "content-#{world.johnson.object_id}"
      assert by == actor!(world.reviewer).id
      assert {mine.mode, mine.mode_set_by_actor_id} == {:mine, actor!(world.reviewer).id}
      assert counts.() == before

      {:ok, unkept} = Compositions.unkeep(world.reviewer, world.composition.id, key, [])
      assert unkept.kept_items == []
    end

    test "a mine page's proposal is written, and flagged", world do
      {:ok, _} = Compositions.set_mode(world.reviewer, world.composition.id, :mine, [])
      proposal = propose!(world)
      assert [%{proposal: %{id: id}, composition: %{mode: :mine}}] = Proposals.list_pending()
      assert id == proposal.id
      assert pointer(world) == world.published.version.id
    end
  end
end
