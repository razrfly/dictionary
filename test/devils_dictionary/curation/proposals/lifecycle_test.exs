defmodule DevilsDictionary.Curation.Proposals.LifecycleTest do
  @moduledoc """
  #264 §8 tests 22–27 and 31: no bypass (R9.6, R13.1), the proposal
  lifecycle (R10), Take and Edit-publish (R11), the quality form (R11.5),
  Dismiss (R12) and the D8 marks (R15).
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures, only: [row!: 1]

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionPublication,
    CompositionReview,
    CompositionVersion,
    Compositions,
    Configurations,
    Proposal,
    Proposals,
    Publications,
    Reviews
  }

  alias DevilsDictionary.Curation.Proposals.QualityForm
  alias DevilsDictionary.Curation.Runtime
  alias DevilsDictionary.Curation.Runtime.Attempt
  alias DevilsDictionary.Registry

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
    defp update_proposal(proposal, set),
      do:
        refused(fn ->
          Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id), set: set)
        end)

    test "identity is fixed and a proposal is never deleted", world do
      proposal = propose!(world)

      assert {:refused, _code, message} = update_proposal(proposal, packet_hash: "another")
      assert message =~ "curation_proposals.packet_hash is fixed when the proposal is written"

      # Another version of the same composition, so only the guard refuses.
      assert {:refused, _code, message} =
               update_proposal(proposal, version_id: world.published.version.id)

      assert message =~ "curation_proposals.version_id is fixed when the proposal is written"

      assert {:refused, _code, message} =
               refused(fn -> Repo.delete_all(from p in Proposal, where: p.id == ^proposal.id) end)

      assert message =~ "curation_proposals rows are never deleted"
    end

    test "taken needs a human reviewer, even with a valid Take version and a complete form",
         world do
      proposal = propose!(world)
      offered = items(proposal)

      # A valid resolution: a manual version parented to the proposal,
      # written by the trusted Take path, and a complete form.
      {:ok, take} =
        Compositions.take_version(world.reviewer, proposal.version_id, %{
          reason: "take",
          items: Enum.map(offered, &{:copy, &1.id, &1.role, &1.position})
        })

      {:ok, form} = QualityForm.build(offered, all_yes(offered), nil, actor!(world.reviewer).id)
      assert take.parent_version_id == proposal.version_id

      taken = fn actor_id ->
        update_proposal(proposal,
          state: :taken,
          resolved_at: DateTime.utc_now(),
          resolved_by_actor_id: actor_id,
          resolution_reason: "take",
          resolution_version_id: take.id,
          quality_form: form
        )
      end

      for actor_id <- [world.bot.id, actor!(world.author).id] do
        assert {:refused, _code, message} = taken.(actor_id)
        assert message =~ "a proposal is taken or dismissed by a human reviewer"
      end

      # The same resolution by the reviewer passes every check.
      assert :accepted = taken.(actor!(world.reviewer).id)
    end

    test "dismissed needs a rejected review of this proposal's version, by a human reviewer",
         world do
      proposal = propose!(world)
      reviewer = actor!(world.reviewer).id

      dismissed = fn review_id, actor_id ->
        update_proposal(proposal,
          state: :dismissed,
          resolved_at: DateTime.utc_now(),
          resolved_by_actor_id: actor_id,
          resolution_reason: "no",
          resolution_review_id: review_id
        )
      end

      # An acceptance, and a rejection of another version.
      accepted =
        Repo.get_by!(CompositionReview, composition_version_id: world.published.version.id)

      assert accepted.decision == :accepted

      {:ok, other} =
        Reviews.decide(world.reviewer, world.published.version.id, :rejected,
          reason: "another version",
          idempotency_key: key("reject-other")
        )

      for review <- [accepted, other] do
        assert {:refused, _code, message} = dismissed.(review.id, reviewer)
        assert message =~ "a dismissed proposal is rejected by a review of its version"
      end

      {:ok, rejection} =
        Reviews.decide(world.reviewer, proposal.version_id, :rejected,
          reason: "no",
          idempotency_key: key("reject")
        )

      assert {:refused, _code, message} = dismissed.(rejection.id, actor!(world.author).id)
      assert message =~ "a proposal is taken or dismissed by a human reviewer"

      {:ok, done} = Proposals.dismiss(world.reviewer, proposal.id, reason: "not this")
      assert done.state == :dismissed

      # Once resolved, never again.
      assert {:refused, _code, message} =
               update_proposal(done,
                 state: :obsolete,
                 resolution_reason: "again",
                 resolved_by_actor_id: nil,
                 resolution_review_id: nil
               )

      assert message =~ "a proposal leaves pending once"
    end

    test "a second pending proposal for a page is refused by the one-pending index", world do
      pending = propose!(world)
      editor = Configurations.editor_enabled(world.editor_version.id) |> elem(1)
      row = row!(world.composition)

      # A second model version from an attempt of its own: everything the
      # insert guard checks holds, and only the index can refuse.
      key = Proposals.request_key(world.composition.id, world.editor_version.id, 99)
      stub_answer!(world, answer_for(world.frozen, world.bierce.object_id, []))

      {:ok, receipt} =
        Runtime.run(
          world.model_config,
          world.frozen,
          Keyword.merge(world.runtime,
            request_key: key,
            actor_id: world.bot.id,
            purpose: :request
          )
        )

      attempt = Repo.get!(Attempt, receipt.attempt_id)

      lead = %CompositionItem{
        role: :lead,
        position: 1,
        item_kind: :content,
        item_object_id: world.bierce.object_id,
        content_revision_id: Registry.current_content_revision(world.bierce.object_id).id,
        meaning_lexeme_id: world.love.object_id,
        note: "Bierce leads."
      }

      {:ok, version} =
        Compositions.write_proposal(editor, %{
          composition: Repo.reload!(world.composition),
          configuration_version: world.editor_version,
          attempt: attempt,
          items: [{:model, lead}]
        })

      second = %{
        pending
        | id: nil,
          version_id: version.id,
          request_key: key,
          refresh_generation: 99,
          refresh_state_id: row.id,
          packet_hash: attempt.packet_hash,
          arrangement_hash: version.arrangement_hash,
          inserted_at: DateTime.utc_now()
      }

      assert {:refused, :unique, "curation_proposals_one_pending_index"} =
               refused(fn -> Repo.insert!(second) end)
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

      assert [%{"key" => key, "marked_by_actor_id" => by} = mark] = kept.kept_items

      # A fragment of an existing mark is no mark: appended without its
      # setter, it is refused like any new element (#273 review, rec. 10).
      for fragment <- [%{}, %{"key" => mark["key"]}] do
        assert {:refused, _code, message} =
                 refused(fn ->
                   Repo.update_all(from(c in Composition, where: c.id == ^world.composition.id),
                     set: [kept_items: kept.kept_items ++ [fragment]]
                   )
                 end)

        assert message =~ "an item is kept by a human reviewer"
      end

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
