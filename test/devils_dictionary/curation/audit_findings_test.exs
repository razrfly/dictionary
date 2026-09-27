defmodule DevilsDictionary.Curation.AuditFindingsTest do
  @moduledoc """
  Regressions for the independent audit of PR #206 (at `b8211ed`), one
  `describe` per finding. Each one runs the whole sequence the audit
  reproduced: creation, review, publication and reading, then the change
  that exposed the defect, then reading again.

    1. A deleted claim revision must not make its dependent item eligible
       again.
    2. A rejected or withdrawn `defines` claim must not authorize a lead.
    3. A new configuration version must allow an unchanged arrangement to be
       reissued, under a fresh review.
    4. Work evidence must be evidence of the selected work.
    5. A note is attributed to its authenticated author, never to a
       caller-supplied name.
    6. Every publication names its authority. Only the operator authority
       exists, and missing, forged, stale and cross-configuration
       authorizations are refused.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision

  alias DevilsDictionary.Curation.{
    CompositionItem,
    CompositionPublication,
    CompositionVersion,
    Compositions,
    Configurations,
    LeadRule,
    Published,
    Publications,
    Reviews
  }

  alias DevilsDictionary.WordFixtures

  setup do
    world = world!()
    {config, config_version} = enabled_test_configuration!(world.reviewer, "audit")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [world.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    Map.merge(world, %{config: config, config_version: config_version, composition: composition})
  end

  defp create(ctx, attrs, composition \\ nil) do
    Compositions.create_version(
      ctx.contributor,
      (composition || ctx.composition).id,
      Map.merge(
        %{lead: content_spec(ctx.bierce, ctx.love), reason: "audit", expected_parent: nil},
        attrs
      )
    )
  end

  defp version!(ctx, attrs, composition \\ nil) do
    {:ok, v} = create(ctx, attrs, composition)
    v
  end

  defp accept!(ctx, version) do
    {:ok, review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted, reason: "audit", idempotency_key: key())

    review
  end

  defp publish(ctx, version, expected \\ nil) do
    Publications.publish(ctx.reviewer, version.id,
      reason: "audit",
      idempotency_key: key(),
      expected_pointer: expected
    )
  end

  defp publish!(ctx, version, expected \\ nil) do
    accept!(ctx, version)
    {:ok, receipt} = publish(ctx, version, expected)
    settle!()
    receipt
  end

  defp current!(ctx, composition \\ nil) do
    {:ok, published} = Published.current((composition || ctx.composition).id)
    published
  end

  defp raw_receipt(ctx, attrs) do
    struct(
      CompositionPublication,
      Map.merge(
        %{
          composition_id: ctx.composition.id,
          action: :publish,
          authority_kind: :operator,
          published_version_id: ctx.v.id,
          authorizing_review_id: ctx.review.id,
          actor_id: actor!(ctx.reviewer).id,
          reason: "raw",
          eligibility_fingerprint: ctx.v.eligibility_fingerprint,
          idempotency_key: key("raw")
        },
        attrs
      )
    )
  end

  # Finding 2: v1 (the Bierce lead, the definition as a highlight) is
  # published, and v2 (the same lead, a quotation added) is accepted and
  # waiting. Then the defining claim changes.
  defp published_and_waiting!(ctx) do
    v1 = version!(ctx, %{highlights: [content_spec(ctx.definition, ctx.love)]})
    publish!(ctx, v1)

    v2 =
      version!(ctx, %{
        highlights: [content_spec(ctx.definition, ctx.love), quotation_spec(ctx.sense, 1)],
        expected_parent: v1.id
      })

    accept!(ctx, v2)
    {v1, v2}
  end

  defp assert_lead_lost!(ctx, v1, v2) do
    assert LeadRule.applicable([ctx.love.object_id]) == []

    # Reading: the published lead is withheld, and nothing takes its place.
    published = current!(ctx)
    assert published.version.id == v1.id
    assert published.lead == nil
    assert published.withheld == [%{role: :lead, position: 1, reason: :lead_not_on_scope}]
    assert [%{item_object_id: id}] = published.highlights
    assert id == ctx.definition.object_id

    # Publication: an acceptance made before the change authorizes nothing now.
    assert {:error, :lead_not_on_scope} = publish(ctx, v2, v1.id)

    # Creation: the entry cannot lead a new version either.
    assert {:error, :lead_not_on_scope} = create(ctx, %{reason: "again", expected_parent: v2.id})

    # Another definition on the page may lead instead, as a new version with
    # its own review, never by substitution.
    fallback =
      version!(ctx, %{lead: content_spec(ctx.definition, ctx.love), expected_parent: v2.id})

    assert fallback.resolution["lead_rule"] == "manual_fallback"
    assert {:error, :not_approved} = publish(ctx, fallback, v1.id)
    assert current!(ctx).version.id == v1.id
    settle!()
  end

  describe "finding 1: deleted claim evidence" do
    test "a deleted claim keeps its item withheld; an item made without one is unaffected", ctx do
      claim = defines_claim!(ctx.definition, ctx.love)

      highlight =
        Map.put(content_spec(ctx.definition, ctx.love), :assertion_revision_id, claim.id)

      v = version!(ctx, %{highlights: [highlight]})
      publish!(ctx, v)

      assert [%{assertion_revision_id: pinned}] = current!(ctx).highlights
      assert pinned == claim.id

      # The claim is revised, so the pinned revision is history and the item
      # it supported is withheld.
      {:ok, _} = Claims.revise(claim.assertion_id, %{rationale: "a replacement revision"})
      settle!()

      assert %{
               highlights: [],
               withheld: [%{role: :highlight, position: 1, reason: :claim_not_visible}]
             } =
               current!(ctx)

      # A mandatory deletion of that historical revision is not blocked...
      assert {1, _} = Repo.delete_all(from r in AssertionRevision, where: r.id == ^claim.id)
      settle!()

      [lead, item] = Enum.sort_by(Compositions.items(v.id), &(&1.role == :highlight))
      assert item.assertion_revision_id == nil
      assert "assertion_revision_id" in item.required_references
      refute "assertion_revision_id" in lead.required_references

      # ...and it does not make the item eligible again.
      published = current!(ctx)
      assert published.highlights == []
      assert published.withheld == [%{role: :highlight, position: 1, reason: :claim_deleted}]
      assert published.lead.item_object_id == ctx.bierce.object_id
    end

    test "a deleted object withholds its catalog work instead of leaving it catalog-only", ctx do
      work = catalog_work!()

      v =
        version!(ctx, %{highlights: [Map.put(catalog_spec(ctx.love), :object_id, work.object_id)]})

      publish!(ctx, v)
      assert [%{item_object_id: id}] = current!(ctx).highlights
      assert id == work.object_id

      assert {1, _} = Repo.delete_all(from o in "objects", where: o.id == ^work.object_id)
      settle!()

      assert %{
               highlights: [],
               withheld: [%{role: :highlight, position: 1, reason: :object_deleted}]
             } =
               current!(ctx)
    end
  end

  describe "finding 2: the defining claim's review" do
    test "a rejected defining claim loses its lead at read, publication and creation", ctx do
      {v1, v2} = published_and_waiting!(ctx)
      claim = defines_claim!(ctx.bierce, ctx.love)

      {:ok, _} = Claims.review(claim.id, :rejected, %{reason: "not this word"})

      refute Repo.exists?(
               Claims.visible(from(r in AssertionRevision, where: r.id == ^claim.id), :public)
             )

      assert_lead_lost!(ctx, v1, v2)
    end

    test "a withdrawn defining claim loses its lead at read, publication and creation", ctx do
      {v1, v2} = published_and_waiting!(ctx)
      claim = defines_claim!(ctx.bierce, ctx.love)

      {:ok, _} = Claims.withdraw(claim.assertion_id, reason: "the source withdrew it")

      assert_lead_lost!(ctx, v1, v2)
    end

    test "a fallback definition needs a visible claim too", ctx do
      {:ok, oats} =
        Compositions.provision(ctx.contributor, ctx.config.id, %{
          scope_kind: :lexeme,
          lexeme_ids: [ctx.oats.object_id],
          language_tag: "en",
          reason: "oats"
        })

      v = version!(ctx, %{lead: content_spec(ctx.oats_definition, ctx.oats)}, oats)
      publish!(ctx, v)

      {:ok, _} =
        Claims.review(defines_claim!(ctx.oats_definition, ctx.oats).id, :rejected, %{
          reason: "not oats"
        })

      assert %{lead: nil, withheld: [%{role: :lead, reason: :lead_not_on_scope}]} =
               current!(ctx, oats)

      assert {:error, :lead_not_on_scope} =
               create(
                 ctx,
                 %{lead: content_spec(ctx.oats_definition, ctx.oats), expected_parent: v.id},
                 oats
               )
    end

    test "a Bierce entry that may not be displayed neither leads nor blocks another lead", ctx do
      disallow_record!(ctx.bierce)

      assert LeadRule.applicable([ctx.love.object_id]) == []

      assert {:error, {:ineligible, [{:lead, 1, :display_restricted}]}} = create(ctx, %{})

      v = version!(ctx, %{lead: content_spec(ctx.definition, ctx.love)})
      assert v.resolution["lead_rule"] == "manual_fallback"
    end
  end

  describe "finding 3: a configuration upgrade" do
    test "an unchanged arrangement is reissued under the new version, and needs its own review",
         ctx do
      v1 = version!(ctx, %{})
      publish!(ctx, v1)

      {:ok, cv2} =
        Configurations.create_version(ctx.reviewer, ctx.config.id, %{
          reason: "a lower highlight limit",
          max_highlights: 2
        })

      {:ok, _} =
        Configurations.activate(ctx.reviewer, ctx.config.id, cv2.id,
          reason: "activate",
          idempotency_key: key(),
          expected: ctx.config_version.id
        )

      assert Published.current(ctx.composition.id) == {:withheld, [:configuration_changed]}

      assert {:ok, v2} = create(ctx, %{reason: "reissued under v2", expected_parent: v1.id})
      assert v2.configuration_version_id == cv2.id
      assert v2.composition_id == v1.composition_id and v2.version == 2
      assert v2.arrangement_hash == v1.arrangement_hash
      refute v2.eligibility_fingerprint == v1.eligibility_fingerprint

      # Approval never transfers: the old acceptance authorizes nothing here.
      assert {:error, :not_approved} = publish(ctx, v2, v1.id)

      # The same arrangement under the same version is still one version, in
      # the service and in the database.
      assert {:error, {:duplicate_version, id}} =
               create(ctx, %{reason: "again", expected_parent: v2.id})

      assert id == v2.id

      assert {:refused, :unique, "editorial_composition_versions_dedup_index"} =
               refused(fn ->
                 fields =
                   v2
                   |> Map.from_struct()
                   |> Map.drop([:__meta__, :id, :inserted_at])
                   |> Map.merge(%{version: 3, parent_version_id: v2.id})

                 Repo.insert!(struct(CompositionVersion, fields))
               end)

      publish!(ctx, v2, v1.id)
      assert current!(ctx).version.id == v2.id
      assert Repo.reload!(v1).configuration_version_id == ctx.config_version.id
    end
  end

  describe "finding 4: work evidence identifies the work" do
    test "a catalog pin must be the selected object's, at creation and at read", ctx do
      unrelated = WordFixtures.concept!(nil, "Unrelated work")

      assert {:error, {:ineligible, [{:highlight, 1, :work_identity_mismatch}]}} =
               create(ctx, %{
                 highlights: [Map.put(catalog_spec(ctx.love), :object_id, unrelated.object_id)]
               })

      work = catalog_work!()

      v =
        version!(ctx, %{highlights: [Map.put(catalog_spec(ctx.love), :object_id, work.object_id)]})

      publish!(ctx, v)
      assert [%{item_object_id: id}] = current!(ctx).highlights
      assert id == work.object_id

      # The registry stops treating the object as that row: the pin no longer
      # describes it, and it is withheld.
      Repo.update_all(from(x in "external_identifiers", where: x.object_id == ^work.object_id),
        set: [status: "rejected"]
      )

      assert %{
               highlights: [],
               withheld: [%{role: :highlight, position: 1, reason: :work_identity_mismatch}]
             } = current!(ctx)
    end

    test "a catalog pin without an object is still a catalog-only work", ctx do
      v = version!(ctx, %{highlights: [catalog_spec(ctx.love)]})
      publish!(ctx, v)
      assert [%{item_object_id: nil, catalog_identity: "Q8777422"}] = current!(ctx).highlights
    end

    test "a source record must have materialized the selected object", ctx do
      work = WordFixtures.concept!(nil, "Fixture work")
      other = WordFixtures.concept!(nil, "Another work")
      {_record, others_revision} = owned_record!(ctx, other)

      assert {:error, {:ineligible, [{:highlight, 1, :work_identity_mismatch}]}} =
               create(ctx, %{highlights: [record_work_spec(work, others_revision, ctx.love)]})

      {record, revision} = owned_record!(ctx, work)
      v = version!(ctx, %{highlights: [record_work_spec(work, revision, ctx.love)]})
      publish!(ctx, v)
      assert [%{item_object_id: id}] = current!(ctx).highlights
      assert id == work.object_id

      Repo.update_all(
        from(o in "source_materialized_outputs", where: o.source_record_id == ^record.id),
        set: [retired_at: DateTime.utc_now()]
      )

      assert %{withheld: [%{role: :highlight, reason: :work_identity_mismatch}]} = current!(ctx)
    end
  end

  describe "finding 5: note attribution" do
    test "a caller cannot supply a note's author or kind", ctx do
      for extra <- [%{author_label: "Ambrose Bierce"}, %{author_kind: :model}] do
        note = Map.merge(%{text: "fixture note"}, extra)

        assert {:error, {:note_attribution_not_an_input, :lead, 1}} =
                 create(ctx, %{lead: Map.put(content_spec(ctx.bierce, ctx.love), :note, note)})
      end
    end

    test "a note is its authenticated author's through creation, publication and reading", ctx do
      note = %{text: "fixture note"}
      v = version!(ctx, %{lead: Map.put(content_spec(ctx.bierce, ctx.love), :note, note)})
      publish!(ctx, v)

      author = actor!(ctx.contributor)
      lead = current!(ctx).lead

      assert {lead.note, lead.note_author_kind, lead.note_author_actor_id} ==
               {"fixture note", :human, author.id}

      assert lead.note_author_label == Compositions.author_label(author)
      refute lead.note_author_label =~ "Bierce"
    end

    test "the database refuses a note attributed to anyone but its version's author", ctx do
      v = version!(ctx, %{})
      settle!()
      author = actor!(ctx.contributor)
      someone = actor!(account([:contributor]))

      item = fn attrs ->
        struct(
          CompositionItem,
          Map.merge(
            %{
              composition_version_id: v.id,
              role: :highlight,
              position: 1,
              item_kind: :content,
              item_object_id: ctx.definition.object_id,
              content_revision_id:
                DevilsDictionary.Registry.current_content_revision(ctx.definition.object_id).id,
              meaning_lexeme_id: ctx.love.object_id,
              note: "fixture note",
              note_author_kind: :human
            },
            attrs
          )
        )
      end

      cases = [
        {%{note_author_actor_id: author.id, note_author_label: "Ambrose Bierce"}, "own label"},
        {%{
           note_author_actor_id: someone.id,
           note_author_label: Compositions.author_label(someone)
         }, "version's author"},
        {%{note_author_actor_id: nil, note_author_label: "Account"}, "names the actor"}
      ]

      for {attrs, expected} <- cases do
        assert {:refused, _code, message} = refused(fn -> Repo.insert!(item.(attrs)) end)
        assert message =~ expected
      end
    end
  end

  describe "finding 6: publication authority" do
    setup ctx do
      v = version!(ctx, %{})
      review = accept!(ctx, v)
      settle!()
      %{v: v, review: review}
    end

    test "the service's receipts name the operator authority, for publication and withdrawal",
         ctx do
      {:ok, published} = publish(ctx, ctx.v)

      {:ok, withdrawn} =
        Publications.withdraw(ctx.reviewer, ctx.composition.id,
          reason: "take down",
          idempotency_key: key(),
          expected_pointer: ctx.v.id
        )

      assert {published.authority_kind, withdrawn.authority_kind} == {:operator, :operator}
      assert published.authorizing_review_id == ctx.review.id
      settle!()
    end

    test "a receipt with no authority, or a panel authority, is refused", ctx do
      assert {:refused, _code, _} =
               refused(fn -> Repo.insert!(raw_receipt(ctx, %{authority_kind: nil})) end)

      # A panel decision needs decision records that do not exist yet. Nothing
      # may stand in for one.
      assert {:refused, _code, _} =
               refused(fn ->
                 Repo.query!(
                   """
                   INSERT INTO editorial_composition_publications
                     (composition_id, action, authority_kind, published_version_id,
                      authorizing_review_id, actor_id, reason, eligibility_fingerprint,
                      idempotency_key, committed_at)
                   VALUES ($1, 'publish', 'panel_decision', $2, $3, $4, 'forged', $5, $6, now())
                   """,
                   [
                     ctx.composition.id,
                     ctx.v.id,
                     ctx.review.id,
                     actor!(ctx.reviewer).id,
                     ctx.v.eligibility_fingerprint,
                     key("forged")
                   ]
                 )
               end)

      # The same receipt with the operator authority, moving the pointer with it, stands.
      assert :accepted =
               refused(fn ->
                 Repo.insert!(raw_receipt(ctx, %{}))

                 Repo.query!(
                   "UPDATE editorial_compositions SET current_published_version_id = $1 WHERE id = $2",
                   [ctx.v.id, ctx.composition.id]
                 )
               end)
    end

    test "a forged operator authority is refused: a bot, a non-reviewer, or a review that did not accept",
         ctx do
      bot = bot_actor!(ctx.sources["wikidata"])

      for actor <- [bot, actor!(ctx.contributor)] do
        assert {:refused, :integrity_constraint_violation, message} =
                 refused(fn -> Repo.insert!(raw_receipt(ctx, %{actor_id: actor.id})) end)

        assert message =~ "reviewer role"
      end

      {:ok, rejection} =
        Reviews.decide(ctx.reviewer, ctx.v.id, :rejected, reason: "no", idempotency_key: key())

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.insert!(raw_receipt(ctx, %{authorizing_review_id: rejection.id}))
               end)
    end

    test "a stale authority is refused: a superseded acceptance, or another fingerprint", ctx do
      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.insert!(
                   raw_receipt(ctx, %{eligibility_fingerprint: "an older fingerprint"})
                 )
               end)

      {:ok, _} =
        Reviews.decide(ctx.reviewer, ctx.v.id, :needs_review,
          reason: "second look",
          idempotency_key: key()
        )

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn -> Repo.insert!(raw_receipt(ctx, %{})) end)

      assert message =~ "latest review"
      assert {:error, :not_approved} = publish(ctx, ctx.v)
    end

    test "a cross-configuration authority is refused", ctx do
      {config_b, _} = enabled_test_configuration!(ctx.reviewer, "audit-b")

      {:ok, b} =
        Compositions.provision(ctx.contributor, config_b.id, %{
          scope_kind: :lexeme,
          lexeme_ids: [ctx.love.object_id],
          language_tag: "en",
          reason: "the same scope, another configuration"
        })

      vb = version!(ctx, %{}, b)
      review_b = accept!(ctx, vb)

      # Another configuration's version published into this composition, or
      # its acceptance cited for this composition's version.
      assert {:refused, :foreign_key, _} =
               refused(fn ->
                 Repo.insert!(
                   raw_receipt(ctx, %{
                     published_version_id: vb.id,
                     authorizing_review_id: review_b.id,
                     eligibility_fingerprint: vb.eligibility_fingerprint
                   })
                 )
               end)

      # Here the authority check refuses it before the ownership key would.
      assert {:refused, _code, _} =
               refused(fn ->
                 Repo.insert!(raw_receipt(ctx, %{authorizing_review_id: review_b.id}))
               end)

      assert %CompositionVersion{curation_configuration_id: config_id} = vb
      assert config_id == config_b.id
    end
  end
end
