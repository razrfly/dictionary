defmodule DevilsDictionary.Curation.ExemplarItemsTest do
  @moduledoc """
  #212 build 1: the `exemplar` composition item, proved by hand.

  A contributor nominates, a reviewer accepts the claim, an author composes,
  an operator reviews and publishes, and `Published.current/1` reads it back
  with providers unreachable. Then every way the claim can stop being
  accepted withholds the item with its reason (C2–C4), and nothing here
  writes a claim (C1).

  Every subject is a fixture: a fictional person, a placeholder passage. No
  words are attributed to anyone real.

  `async: false` because the offline test empties the discovery provider
  registry, which is application-wide.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.{Claims, Discovery, Registry, WordFixtures}
  alias DevilsDictionary.Claims.{Assertion, AssertionReview, AssertionRevision, Contributions}

  alias DevilsDictionary.Curation.{
    CompositionItem,
    CompositionPublication,
    Compositions,
    Published,
    Publications,
    Reviews
  }

  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.Examples.Community
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Sources.{Actor, Source}

  @evidence "https://example.test/fixture-evidence"

  setup do
    world = world!()
    {config, config_version} = enabled_test_configuration!(world.reviewer, "exemplar")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [world.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    {:ok, person} = Registry.create_person(%{preferred_label: "Fixture Person"})

    Map.merge(world, %{
      config: config,
      config_version: config_version,
      composition: composition,
      person: person,
      sense_revision: Registry.current_sense_revision(world.sense.object_id)
    })
  end

  # ── the steps ─────────────────────────────────────────────────────────────

  # A contributor's nomination through the one path every nomination takes.
  # A person needs evidence (#105 rule 2); a passage may go without.
  defp nominate!(ctx, subject, object, evidence \\ nil) do
    evidence =
      evidence ||
        [
          Map.merge(Community.cite!(@evidence, "Fixture"), %{
            locator: @evidence,
            evidence_role: :supports
          })
        ]

    {:ok, assertion} =
      Contributions.propose(
        ctx.contributor,
        subject.object_id,
        "illustrates",
        object.object_id,
        %{rationale: "fixture rationale"},
        evidence
      )

    Claims.current_revision(assertion.id)
  end

  # A reviewer's decision on exactly what is displayed, which opens the
  # review context the item's eligibility compares against.
  defp decide_claim!(ctx, revision, decision \\ "accepted") do
    {:ok, review} =
      Contributions.review(
        ctx.reviewer,
        revision.assertion_id,
        revision.id,
        decision,
        "Checked.",
        Contributions.context_items(revision)
      )

    review
  end

  defp exemplar(revision, meaning),
    do: %{kind: :exemplar, assertion_revision_id: revision.id, meaning: meaning}

  defp by_sense(ctx), do: {:sense_revision, ctx.sense_revision.id}

  defp compose(ctx, highlights, expected \\ nil) do
    Compositions.create_version(ctx.contributor, ctx.composition.id, %{
      lead: content_spec(ctx.bierce, ctx.love),
      highlights: highlights,
      reason: "an example of love",
      expected_parent: expected
    })
  end

  defp compose!(ctx, highlights, expected \\ nil) do
    {:ok, version} = compose(ctx, highlights, expected)
    version
  end

  defp accept_version!(ctx, version) do
    {:ok, review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "reads well",
        idempotency_key: key("review")
      )

    review
  end

  defp publish(ctx, version, key, expected) do
    Publications.publish(ctx.reviewer, version.id,
      reason: "ship it",
      idempotency_key: key,
      expected_pointer: expected
    )
  end

  defp publish!(ctx, version, expected \\ nil) do
    accept_version!(ctx, version)
    {:ok, receipt} = publish(ctx, version, key("publish"), expected)
    settle!()
    receipt
  end

  defp current!(ctx) do
    {:ok, published} = Published.current(ctx.composition.id)
    published
  end

  # Nominated, accepted, composed, reviewed and published.
  defp published!(ctx) do
    claim = nominate!(ctx, ctx.person, ctx.sense)
    decide_claim!(ctx, claim)
    version = compose!(ctx, [exemplar(claim, by_sense(ctx))])
    publish!(ctx, version)

    assert [%{item_kind: :exemplar}] = current!(ctx).highlights
    Map.merge(ctx, %{claim: claim, version: version})
  end

  defp assert_withheld(ctx, reason) do
    published = current!(ctx)
    assert published.highlights == []
    assert published.withheld == [%{role: :highlight, position: 1, reason: reason}]
    assert published.lead.item_object_id == ctx.bierce.object_id
  end

  defp claim_counts do
    {Repo.aggregate(Assertion, :count), Repo.aggregate(AssertionRevision, :count),
     Repo.aggregate(AssertionReview, :count)}
  end

  # A quotation as a provider with a durable identity leaves it behind: a
  # `content/quotation` object whose first revision cites the provider's
  # record (Wikiquote's `identity_record/1`), and a shelf result naming it.
  defp shelved_quotation!(ctx, body) do
    {:ok, source} =
      %Source{}
      |> Source.changeset(Wikiquote.source_attrs())
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:slug])

    source = Repo.get_by!(Source, slug: source.slug)
    record = WordFixtures.record!(put_in(ctx.sources["wikiquote"], source), "wikiquote")

    record_revision =
      Repo.one!(
        from r in "source_record_revisions", where: r.source_record_id == ^record.id, select: r.id
      )

    {:ok, quotation} =
      Registry.create_content(%{
        content_kind: :quotation,
        source_id: source.id,
        headword: "Fixture quotation",
        body: body,
        source_record_revision_id: record_revision
      })

    run = shelf_run!(ctx, source)

    result =
      Repo.insert!(
        Result.changeset(%Result{}, %{
          run_id: run.id,
          external_namespace: "wikiquote_item",
          external_id: "fixture-#{quotation.object_id}",
          object_id: quotation.object_id,
          source_record_id: record.id,
          position: 0,
          match_details: %{},
          preview_metadata: %{},
          display_allowed: true,
          resolution_state: :newly_created
        })
      )

    %{quotation: quotation, record_revision: record_revision, run: run, result: result}
  end

  defp shelf_run!(ctx, source) do
    actor =
      Repo.insert!(Actor.changeset(%Actor{}, %{actor_kind: :import, label: "fixture shelf"}))

    mapping =
      Repo.insert!(
        Mapping.create_changeset(%Mapping{}, %{
          mapping_key: "wikiquote:#{ctx.love.object_id}",
          version: 1,
          target_object_id: ctx.love.object_id,
          source_id: source.id,
          operation: "term_quote_discovery",
          parameters: %{},
          configured_by_actor_id: actor.id,
          enabled: true
        })
      )

    now = DateTime.utc_now()

    run =
      Repo.insert!(
        Run.create_changeset(%Run{}, %{
          mapping_id: mapping.id,
          adapter_version: "wikiquote.fixture",
          request_parameters: %{},
          request_key: "fixture-request",
          position_key: "fixture-position",
          page_context: Ecto.UUID.generate(),
          page: 0,
          status: :pending
        })
      )

    Repo.update!(
      Run.lifecycle_changeset(run, %{
        status: :succeeded,
        started_at: now,
        completed_at: now,
        refresh_after: DateTime.add(now, 3_600),
        expires_at: DateTime.add(now, 86_400),
        completion_reason: :results,
        result_count: 1,
        request_count: 1
      })
    )
  end

  # C7: no provider and no model is reachable. Every HTTP plug the test
  # configuration routes through raises, and the provider registry is empty.
  defp offline! do
    for plug <- [
          DevilsDictionary.Absorb.Clients,
          DevilsDictionary.Discovery.Providers.CineGraph,
          DevilsDictionary.Quotations.Verifier
        ] do
      Req.Test.stub(plug, fn _conn -> raise "a curation read made an HTTP request" end)
    end

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [])
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, providers) end)
  end

  # An item written past the service, into a version that already stands.
  # Every one of these is refused at insert, before the deferred arrangement
  # check would refuse it again at commit, so each test names the refusal.
  defp raw(ctx, attrs) do
    struct(
      CompositionItem,
      Map.merge(
        %{
          composition_version_id: ctx.version.id,
          role: :highlight,
          position: 2,
          item_kind: :exemplar,
          item_object_id: ctx.person.object_id,
          assertion_revision_id: ctx.claim.id,
          meaning_sense_revision_id: ctx.sense_revision.id
        },
        attrs
      )
    )
  end

  # ── the proof ─────────────────────────────────────────────────────────────

  describe "the manual proof" do
    test "a nomination, accepted, composed, reviewed and published, reads back offline", ctx do
      claim = nominate!(ctx, ctx.person, ctx.sense)
      review = decide_claim!(ctx, claim)

      # C1: from here on, composing, reviewing and publishing write no claim.
      before = claim_counts()

      version = compose!(ctx, [exemplar(claim, by_sense(ctx))])
      items = Compositions.items(version.id)
      lead = Enum.find(items, &(&1.role == :lead))
      item = Enum.find(items, &(&1.role == :highlight))

      assert lead.item_kind == :content
      assert %CompositionItem{item_kind: :exemplar, role: :highlight, position: 1} = item
      assert item.item_object_id == ctx.person.object_id
      assert item.assertion_revision_id == claim.id
      assert item.content_revision_id == nil
      assert item.meaning_sense_revision_id == ctx.sense_revision.id
      assert item.selection_origin == :manual
      assert "assertion_revision_id" in item.required_references

      # The version records the review context the claim was accepted under.
      context = Repo.get!(Claims.ReviewContext, review.review_context_id)
      assert version.resolution["claim_contexts"] == %{"highlight:1" => context.fingerprint}

      key = key("publish")
      accept_version!(ctx, version)
      {:ok, receipt} = publish(ctx, version, key, nil)

      # A repeated publish replays its receipt and writes nothing.
      assert {:ok, ^receipt} = publish(ctx, version, key, nil)
      settle!()

      assert Repo.aggregate(CompositionPublication, :count) == 1
      assert claim_counts() == before
      assert Repo.reload!(claim) == claim

      offline!()

      published = current!(ctx)
      assert published.version.id == version.id
      assert published.receipt.id == receipt.id
      assert published.withheld == []

      assert [
               %CompositionItem{
                 item_kind: :exemplar,
                 subject: %{kind: :entity, subkind: :person, label: "Fixture Person", words: nil}
               }
             ] = published.highlights
    end

    test "a passage is shown by its pinned words, and deleting its shelf result changes nothing",
         ctx do
      shelf = shelved_quotation!(ctx, "fixture passage words")

      claim =
        nominate!(ctx, shelf.quotation, ctx.sense, [
          %{
            source_record_revision_id: shelf.record_revision,
            locator: "fixture locator",
            evidence_role: :supports
          }
        ])

      decide_claim!(ctx, claim)
      pinned = Registry.current_content_revision(shelf.quotation.object_id)
      version = compose!(ctx, [exemplar(claim, by_sense(ctx))])
      publish!(ctx, version)

      assert [%{content_revision_id: id, item_object_id: object}] =
               Compositions.items(version.id) |> Enum.filter(&(&1.item_kind == :exemplar))

      assert id == pinned.id
      assert object == shelf.quotation.object_id

      shown = current!(ctx)

      assert [
               %{
                 subject: %{
                   kind: :content,
                   subkind: :quotation,
                   label: "Fixture quotation",
                   words: "fixture passage words"
                 }
               }
             ] = shown.highlights

      # Retention takes the search cache. The claim and the item hold registry
      # ids, never a result id, so nothing moves.
      before = {claim_counts(), Repo.aggregate("assertion_evidence", :count)}
      assert {1, _records} = Discovery.purge_results([shelf.run.id])
      settle!()
      refute Repo.get(Result, shelf.result.id)

      offline!()
      assert current!(ctx) == shown
      assert {claim_counts(), Repo.aggregate("assertion_evidence", :count)} == before
    end

    test "a claim about a concept is shown under a word whose sense refers to it", ctx do
      concept = WordFixtures.concept!(nil, "fixture concept")
      {:ok, _link} = Claims.assert(ctx.sense.object_id, "refers_to", concept.object_id, %{})

      claim = nominate!(ctx, ctx.person, concept)
      decide_claim!(ctx, claim)

      # A concept's meaning is a word, not a sense.
      assert {:error, {:ineligible, [{:highlight, 1, :meaning_mismatch}]}} =
               compose(ctx, [exemplar(claim, by_sense(ctx))])

      publish!(ctx, compose!(ctx, [exemplar(claim, {:lexeme, ctx.love.object_id})]))
      assert [%{item_object_id: id}] = current!(ctx).highlights
      assert id == ctx.person.object_id
    end
  end

  # ── what withholds it (C2–C4) ─────────────────────────────────────────────

  describe "a rejected claim" do
    test "is withheld as not accepted", ctx do
      ctx = published!(ctx)
      decide_claim!(ctx, ctx.claim, "rejected")
      assert_withheld(ctx, :claim_not_accepted)
    end

    test "and a disputed one too", ctx do
      ctx = published!(ctx)
      decide_claim!(ctx, ctx.claim, "disputed")
      assert_withheld(ctx, :claim_not_accepted)
    end

    test "a disputed work is withheld though the public still sees the dispute (C2)", ctx do
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})
      claim = nominate!(ctx, work, ctx.sense, [])
      decide_claim!(ctx, claim)
      publish!(ctx, compose!(ctx, [exemplar(claim, by_sense(ctx))]))
      assert [%{subject: %{kind: :entity, subkind: :work}}] = current!(ctx).highlights

      decide_claim!(ctx, claim, "disputed")
      assert Claims.publicly_visible_revision?(claim)
      assert_withheld(ctx, :claim_not_accepted)
    end
  end

  describe "a withdrawn claim" do
    test "withdrawn by a review is not accepted", ctx do
      ctx = published!(ctx)
      {:ok, _} = Claims.review(ctx.claim.id, :withdrawn, %{reason: "withdrawn"})
      assert_withheld(ctx, :claim_not_accepted)
    end

    test "withdrawn by its revision is not current", ctx do
      ctx = published!(ctx)
      {:ok, _} = Claims.withdraw(ctx.claim.assertion_id, reason: "no longer")
      assert_withheld(ctx, :claim_not_current)
    end
  end

  describe "a superseded claim" do
    test "is withheld, and accepting its new revision does not carry the item (C3)", ctx do
      ctx = published!(ctx)
      {:ok, reworded} = Claims.revise(ctx.claim.assertion_id, %{rationale: "reworded"})
      assert_withheld(ctx, :claim_not_current)

      decide_claim!(ctx, reworded)
      assert_withheld(ctx, :claim_not_current)
    end
  end

  describe "a deleted claim revision" do
    test "nulls only its reference and withholds the item for good (C4, R7)", ctx do
      ctx = published!(ctx)
      {:ok, reworded} = Claims.revise(ctx.claim.assertion_id, %{rationale: "reworded"})
      assert {1, _} = Repo.delete_all(from r in AssertionRevision, where: r.id == ^ctx.claim.id)
      settle!()

      item = ctx.version.id |> Compositions.items() |> Enum.find(&(&1.role == :highlight))
      assert item.assertion_revision_id == nil
      assert item.item_object_id == ctx.person.object_id
      assert "assertion_revision_id" in item.required_references
      assert_withheld(ctx, :claim_deleted)

      # Nothing a reviewer does to the claim afterwards revives the item.
      decide_claim!(ctx, reworded)
      assert_withheld(ctx, :claim_deleted)
    end
  end

  describe "a changed review context" do
    test "withholds until a new version is reviewed, even after the claim is re-accepted (decision 2, C3)",
         ctx do
      ctx = published!(ctx)

      Repo.update_all(from(e in Entity, where: e.object_id == ^ctx.person.object_id),
        set: [preferred_label: "Fixture Person, renamed"]
      )

      assert Claims.display_review_state(ctx.claim.id) == :changed_since_review
      assert_withheld(ctx, :claim_context_changed)

      # The claim is accepted again, under the context now displayed. The
      # composition's review was of the old one, so the item stays withheld,
      # and the old version cannot be accepted or published again.
      decide_claim!(ctx, ctx.claim)
      assert Claims.display_review_state(ctx.claim.id) == :accepted
      assert_withheld(ctx, :claim_context_changed)

      assert {:error, {:ineligible, [{:highlight, 1, :claim_context_changed}]}} =
               Reviews.decide(ctx.reviewer, ctx.version.id, :accepted,
                 reason: "again",
                 idempotency_key: key()
               )

      # The same arrangement is a new version under the new context, with a
      # review of its own.
      reissued = compose!(ctx, [exemplar(ctx.claim, by_sense(ctx))], ctx.version.id)
      assert reissued.arrangement_hash == ctx.version.arrangement_hash
      refute reissued.eligibility_fingerprint == ctx.version.eligibility_fingerprint
      publish!(ctx, reissued, ctx.version.id)

      assert [%{subject: %{label: "Fixture Person, renamed"}}] = current!(ctx).highlights
    end
  end

  describe "a meaning mismatch" do
    test "is refused when the item means another sense, or the word, than the claim", ctx do
      claim = nominate!(ctx, ctx.person, ctx.sense)
      decide_claim!(ctx, claim)

      other = WordFixtures.sense!(ctx, ctx.love, "wiktionary", gloss: "another meaning of love")
      other_revision = Registry.current_sense_revision(other.object_id)

      for meaning <- [{:sense_revision, other_revision.id}, {:lexeme, ctx.love.object_id}] do
        assert {:error, {:ineligible, [{:highlight, 1, :meaning_mismatch}]}} =
                 compose(ctx, [exemplar(claim, meaning)])
      end
    end

    test "a concept's example needs that concept, referred to by a sense of that word", ctx do
      concept = WordFixtures.concept!(nil, "fixture concept")
      other = WordFixtures.concept!(nil, "another fixture concept")
      {:ok, _} = Claims.assert(ctx.sense.object_id, "refers_to", other.object_id, %{})

      amor_sense = WordFixtures.sense!(ctx, ctx.amor, "wiktionary", gloss: "a meaning of amor")
      {:ok, _} = Claims.assert(amor_sense.object_id, "refers_to", concept.object_id, %{})

      # Love's sense refers to another concept, and another word's sense to
      # this one: neither makes this claim an example of love.
      claim = nominate!(ctx, ctx.person, concept)
      decide_claim!(ctx, claim)

      assert {:error, {:ineligible, [{:highlight, 1, :meaning_mismatch}]}} =
               compose(ctx, [exemplar(claim, {:lexeme, ctx.love.object_id})])
    end

    test "withholds a concept's example once no sense of the word refers to it", ctx do
      concept = WordFixtures.concept!(nil, "fixture concept")
      {:ok, link} = Claims.assert(ctx.sense.object_id, "refers_to", concept.object_id, %{})
      claim = nominate!(ctx, ctx.person, concept)
      decide_claim!(ctx, claim)
      publish!(ctx, compose!(ctx, [exemplar(claim, {:lexeme, ctx.love.object_id})]))

      {:ok, _} = Claims.review(Claims.current_revision(link.id).id, :rejected, %{reason: "wrong"})
      assert_withheld(ctx, :meaning_mismatch)
    end
  end

  describe "an unaccepted claim" do
    test "cannot be composed, whatever the public gate allows (C2)", ctx do
      pending = nominate!(ctx, ctx.person, ctx.sense)
      refute Claims.publicly_visible_revision?(pending)

      assert {:error, {:ineligible, [{:highlight, 1, :claim_not_accepted}]}} =
               compose(ctx, [exemplar(pending, by_sense(ctx))])

      # A pending work is public under the person-only gate (#190 widens it).
      # It still waits for a reviewer here.
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})
      pending_work = nominate!(ctx, work, ctx.sense, [])
      assert Claims.publicly_visible_revision?(pending_work)

      assert {:error, {:ineligible, [{:highlight, 1, :claim_not_accepted}]}} =
               compose(ctx, [exemplar(pending_work, by_sense(ctx))])
    end

    test "withholds a published item sent back for review", ctx do
      ctx = published!(ctx)
      {:ok, _} = Claims.review(ctx.claim.id, :needs_review, %{reason: "look again"})
      assert_withheld(ctx, :claim_not_accepted)
    end
  end

  describe "a claim the public may not see" do
    test "a retired subject withholds it as not visible", ctx do
      ctx = published!(ctx)

      Repo.update_all(from(o in "objects", where: o.id == ^ctx.person.object_id),
        set: [lifecycle_state: "retired"]
      )

      assert_withheld(ctx, :claim_not_visible)
    end

    test "a passage whose words are restricted is withheld, rights before review", ctx do
      %{quotation: quotation} = shelved_quotation!(ctx, "fixture passage words")
      claim = nominate!(ctx, quotation, ctx.sense, [])
      decide_claim!(ctx, claim)
      publish!(ctx, compose!(ctx, [exemplar(claim, by_sense(ctx))]))

      Repo.update_all(
        from(r in "content_revisions",
          where: r.content_id == ^quotation.object_id and r.is_current
        ),
        set: [rights_metadata: %{"display" => "restricted"}]
      )

      assert_withheld(ctx, :claim_not_visible)
    end
  end

  describe "the subject shown" do
    test "a passage pinned to words it no longer has is refused", ctx do
      %{quotation: quotation} = shelved_quotation!(ctx, "fixture passage words")
      old = Registry.current_content_revision(quotation.object_id)
      {:ok, _} = Registry.add_content_revision(quotation.object_id, %{body: "fixture new words"})

      claim = nominate!(ctx, quotation, ctx.sense, [])
      decide_claim!(ctx, claim)

      assert {:error, {:ineligible, [{:highlight, 1, :revision_superseded}]}} =
               compose(ctx, [
                 Map.put(exemplar(claim, by_sense(ctx)), :content_revision_id, old.id)
               ])
    end
  end

  # ── one display identity (C6) ─────────────────────────────────────────────

  describe "one display identity per arrangement" do
    test "one person twice, under two meanings, is refused", ctx do
      first = nominate!(ctx, ctx.person, ctx.sense)
      decide_claim!(ctx, first)

      other = WordFixtures.sense!(ctx, ctx.love, "wiktionary", gloss: "another meaning of love")
      second = nominate!(ctx, ctx.person, other)
      decide_claim!(ctx, second)
      other_meaning = {:sense_revision, Registry.current_sense_revision(other.object_id).id}

      assert {:error, {:duplicate_display_identity, id}} =
               compose(ctx, [exemplar(first, by_sense(ctx)), exemplar(second, other_meaning)])

      assert id == ctx.person.object_id
    end

    test "an exemplar and a work item of the same object are refused", ctx do
      claim = nominate!(ctx, ctx.person, ctx.sense)
      decide_claim!(ctx, claim)
      {_record, revision} = owned_record!(ctx, ctx.person)

      assert {:error, {:duplicate_display_identity, id}} =
               compose(ctx, [
                 record_work_spec(ctx.person, revision, ctx.love),
                 exemplar(claim, by_sense(ctx))
               ])

      assert id == ctx.person.object_id
    end

    test "a catalog work and an exemplar of the registry work that carries its row are refused",
         ctx do
      work = WordFixtures.concept!("Q8777422", "Fixture catalog work", kind: :work)
      claim = nominate!(ctx, work, ctx.sense, [])
      decide_claim!(ctx, claim)

      assert {:error, {:duplicate_display_identity, id}} =
               compose(ctx, [catalog_spec(ctx.love), exemplar(claim, by_sense(ctx))])

      assert id == work.object_id
    end

    test "a passage whose words are already a highlight's is refused", ctx do
      %{quotation: quotation} = shelved_quotation!(ctx, "fixture quotation words")
      claim = nominate!(ctx, quotation, ctx.sense, [])
      decide_claim!(ctx, claim)

      assert {:error, {:duplicate_display_identity, id}} =
               compose(ctx, [quotation_spec(ctx.sense, 1), exemplar(claim, by_sense(ctx))])

      assert id == quotation.object_id
    end
  end

  # ── the spec and the database ─────────────────────────────────────────────

  describe "the item spec" do
    test "names a claim and no object, and is a highlight only", ctx do
      claim = nominate!(ctx, ctx.person, ctx.sense)
      decide_claim!(ctx, claim)
      spec = exemplar(claim, by_sense(ctx))

      assert {:error, {:subject_not_an_input, :highlight, 1}} =
               compose(ctx, [Map.put(spec, :object_id, ctx.person.object_id)])

      assert {:error, {:claim_required, :highlight, 1}} =
               compose(ctx, [Map.delete(spec, :assertion_revision_id)])

      assert {:error, {:entity_has_no_words, :highlight, 1}} =
               compose(ctx, [Map.put(spec, :content_revision_id, 1)])

      assert {:error, {:exemplar_is_a_highlight, :lead, 1}} =
               Compositions.create_version(ctx.contributor, ctx.composition.id, %{
                 lead: spec,
                 reason: "an exemplar cannot lead",
                 expected_parent: nil
               })
    end
  end

  describe "the database" do
    setup ctx do
      claim = nominate!(ctx, ctx.person, ctx.sense)
      decide_claim!(ctx, claim)
      version = compose!(ctx, [exemplar(claim, by_sense(ctx))])
      settle!()
      Map.merge(ctx, %{claim: claim, version: version})
    end

    test "refuses an exemplar without an illustrates claim, as a lead, or showing another object",
         ctx do
      defines = defines_claim!(ctx.definition, ctx.love)

      for {attrs, message} <- [
            {%{assertion_revision_id: nil}, "names the claim it shows"},
            {%{
               assertion_revision_id: defines.id,
               item_object_id: ctx.definition.object_id,
               content_revision_id: Registry.current_content_revision(ctx.definition.object_id).id
             }, "shows an illustrates claim"},
            {%{role: :lead, position: 1}, "editorial_composition_items_shape"},
            {%{item_object_id: ctx.love.object_id},
             "editorial_composition_items_claim_subject_fkey"}
          ] do
        assert {:refused, _code, detail} = refused(fn -> Repo.insert!(raw(ctx, attrs)) end)
        assert detail =~ message
      end
    end

    test "pins a passage's words and no entity's", ctx do
      %{quotation: quotation} = shelved_quotation!(ctx, "fixture passage words")
      passage = nominate!(ctx, quotation, ctx.sense, [])
      words = Registry.current_content_revision(quotation.object_id)

      assert {:refused, :check_violation, detail} =
               refused(fn ->
                 Repo.insert!(
                   raw(ctx, %{
                     item_object_id: quotation.object_id,
                     assertion_revision_id: passage.id
                   })
                 )
               end)

      assert detail =~ "pins its words"

      assert {:refused, :check_violation, detail} =
               refused(fn -> Repo.insert!(raw(ctx, %{content_revision_id: words.id})) end)

      assert detail =~ "pins no words"
    end

    test "the service refuses, rather than raises on, a claim about another object", ctx do
      # The claim-subject key binds every kind; slice 1's content item may
      # still carry a claim about itself (`AuditFindingsTest`, finding 1).
      bierce_defines = defines_claim!(ctx.bierce, ctx.love)

      annotated =
        Map.put(content_spec(ctx.definition, ctx.love), :assertion_revision_id, bierce_defines.id)

      assert {:error, {:ineligible, [{:highlight, 1, :claim_not_about_object}]}} =
               compose(ctx, [annotated], ctx.version.id)

      own =
        Map.put(annotated, :assertion_revision_id, defines_claim!(ctx.definition, ctx.love).id)

      assert {:ok, _version} = compose(ctx, [own], ctx.version.id)
    end

    test "binds any item that names a claim to the claim's subject", ctx do
      # PostgreSQL has no per-kind foreign key: an annotating claim on a
      # content item must be about that content, as slice 1's own use is.
      claim = defines_claim!(ctx.definition, ctx.love)

      assert {:refused, _code, detail} =
               refused(fn ->
                 Repo.insert!(
                   raw(ctx, %{
                     item_kind: :content,
                     item_object_id: ctx.bierce.object_id,
                     content_revision_id:
                       Registry.current_content_revision(ctx.bierce.object_id).id,
                     assertion_revision_id: claim.id,
                     meaning_sense_revision_id: nil,
                     meaning_lexeme_id: ctx.love.object_id
                   })
                 )
               end)

      assert detail =~ "editorial_composition_items_claim_subject_fkey"
    end
  end

  # ── the bot boundary (C10) ────────────────────────────────────────────────

  describe "the bot boundary" do
    # #197 replaces this test when it opens the bot nomination path.
    test "propose/6 refuses a bot actor's scope", ctx do
      bot = bot_actor!(ctx.sources["wikidata"])
      before = claim_counts()

      assert {:error, :unauthorized} =
               Contributions.propose(
                 %{actor: bot},
                 ctx.person.object_id,
                 "illustrates",
                 ctx.sense.object_id,
                 %{rationale: "a bot's nomination"},
                 []
               )

      assert {:error, :unauthorized} =
               Contributions.propose(
                 %{actor: %Actor{actor_kind: :bot}},
                 ctx.person.object_id,
                 "illustrates",
                 ctx.sense.object_id,
                 %{rationale: "a bot's nomination"},
                 nil,
                 nil
               )

      assert claim_counts() == before
    end
  end
end
