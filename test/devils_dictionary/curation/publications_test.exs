defmodule DevilsDictionary.Curation.PublicationsTest do
  @moduledoc """
  R1–R4, R6 and R7 of `docs/curation/persistence-slice-1.md`: human review,
  explicit publication, the read that withholds without substitution, and
  deletion that is never blocked and keeps nothing prohibited. R5, the race,
  is `PublicationRaceTest`, on committed connections.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Claims.{Assertion, AssertionReview, AssertionRevision}

  alias DevilsDictionary.Curation.{
    CompositionItem,
    CompositionPublication,
    CompositionReview,
    Compositions,
    Configurations,
    Published,
    Publications,
    Reviews
  }

  alias DevilsDictionary.{Registry, WordFixtures}

  setup do
    world = world!()
    {config, config_version} = enabled_test_configuration!(world.reviewer, "test-a")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [world.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    {:ok, version} =
      Compositions.create_version(world.contributor, composition.id, %{
        lead: content_spec(world.bierce, world.love),
        highlights: [quotation_spec(world.sense, 1), content_spec(world.definition, world.love)],
        reason: "first arrangement",
        expected_parent: nil
      })

    Map.merge(world, %{
      config: config,
      config_version: config_version,
      composition: composition,
      version: version
    })
  end

  defp accept!(ctx, version \\ nil) do
    {:ok, review} =
      Reviews.decide(ctx.reviewer, (version || ctx.version).id, :accepted,
        reason: "reads well",
        idempotency_key: key("review")
      )

    review
  end

  defp publish(ctx, opts \\ []) do
    Publications.publish(
      ctx.reviewer,
      Keyword.get(opts, :version, ctx.version).id,
      reason: "ship it",
      idempotency_key: Keyword.get(opts, :key, key("publish")),
      expected_pointer: Keyword.get(opts, :expected, nil)
    )
  end

  defp claim_counts do
    {Repo.aggregate(Assertion, :count), Repo.aggregate(AssertionRevision, :count),
     Repo.aggregate(AssertionReview, :count)}
  end

  describe "review (R1, R2)" do
    test "a bot or a non-reviewer cannot review", ctx do
      opts = [reason: "fine", idempotency_key: key()]

      assert {:error, :unauthorized} =
               Reviews.decide(ctx.contributor, ctx.version.id, :accepted, opts)

      assert {:error, :unauthorized} = Reviews.decide(account(), ctx.version.id, :accepted, opts)
      assert {:error, :unauthorized} = Reviews.decide(nil, ctx.version.id, :accepted, opts)

      revoked = account([:reviewer])
      revoke!(revoked)
      assert {:error, :unauthorized} = Reviews.decide(revoked, ctx.version.id, :accepted, opts)

      bot = bot_actor!(ctx.sources["wikidata"])

      for actor <- [bot, actor!(ctx.contributor)] do
        assert {:refused, :integrity_constraint_violation, message} =
                 refused(fn ->
                   Repo.insert!(%CompositionReview{
                     composition_id: ctx.composition.id,
                     composition_version_id: ctx.version.id,
                     reviewer_actor_id: actor.id,
                     decision: :accepted,
                     reason: "self-approval",
                     reviewed_eligibility_fingerprint: ctx.version.eligibility_fingerprint,
                     idempotency_key: key()
                   })
                 end)

        assert message =~ "reviewer role"
      end
    end

    test "approval publishes nothing and accepts no claim or page", ctx do
      before = claim_counts()
      review = accept!(ctx)
      settle!()

      assert review.decision == :accepted
      assert review.reviewed_eligibility_fingerprint == ctx.version.eligibility_fingerprint
      assert review.reviewer_actor_id == actor!(ctx.reviewer).id
      assert Repo.reload!(ctx.composition).current_published_version_id == nil
      assert Repo.aggregate(CompositionPublication, :count) == 0
      assert Published.current(ctx.composition.id) == :unpublished
      assert claim_counts() == before

      # This slice has no page tables to write, and adds none.
      for table <- ~w(pages page_composition_bindings) do
        assert %{rows: [[false]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table])
      end
    end

    test "decisions are append-only and idempotent", ctx do
      k = key()
      opts = [reason: "reads well", idempotency_key: k]
      {:ok, review} = Reviews.decide(ctx.reviewer, ctx.version.id, :accepted, opts)

      assert {:ok, ^review} = Reviews.decide(ctx.reviewer, ctx.version.id, :accepted, opts)

      assert {:error, :idempotency_conflict} =
               Reviews.decide(ctx.reviewer, ctx.version.id, :rejected, opts)

      assert {:error, :unknown_decision} =
               Reviews.decide(ctx.reviewer, ctx.version.id, :approved, opts)

      for sql <- [
            "UPDATE editorial_composition_reviews SET decision = 'rejected' WHERE id = $1",
            "DELETE FROM editorial_composition_reviews WHERE id = $1"
          ] do
        assert {:refused, :integrity_constraint_violation, _} =
                 refused(fn -> Repo.query!(sql, [review.id]) end)
      end

      # An acceptance must be of the version's own fingerprint.
      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.insert!(%CompositionReview{
                   composition_id: ctx.composition.id,
                   composition_version_id: ctx.version.id,
                   reviewer_actor_id: actor!(ctx.reviewer).id,
                   decision: :accepted,
                   reason: "of something else",
                   reviewed_eligibility_fingerprint: "another",
                   idempotency_key: key()
                 })
               end)
    end

    test "an acceptance is refused once the version no longer stands", ctx do
      withdraw_revision!(ctx.definition)

      assert {:error, {:ineligible, [{:highlight, 2, :revision_withdrawn}]}} =
               Reviews.decide(ctx.reviewer, ctx.version.id, :accepted,
                 reason: "x",
                 idempotency_key: key()
               )

      # Rejection still records, with the fingerprint the reviewer saw.
      assert {:ok, %CompositionReview{decision: :rejected} = r} =
               Reviews.decide(ctx.reviewer, ctx.version.id, :rejected,
                 reason: "a definition was withdrawn",
                 idempotency_key: key()
               )

      refute r.reviewed_eligibility_fingerprint == ctx.version.eligibility_fingerprint
    end
  end

  describe "publication (R3, R4)" do
    test "needs an accepted review, then writes a receipt and moves the pointer atomically",
         ctx do
      assert {:error, :not_approved} = publish(ctx)
      review = accept!(ctx)
      before = claim_counts()

      assert {:ok, %CompositionPublication{} = receipt} = publish(ctx)
      settle!()

      assert %{
               action: :publish,
               previous_version_id: nil,
               published_version_id: published,
               authorizing_review_id: authorizing,
               eligibility_fingerprint: fingerprint
             } = receipt

      assert {published, authorizing, fingerprint} ==
               {ctx.version.id, review.id, ctx.version.eligibility_fingerprint}

      assert receipt.actor_id == actor!(ctx.reviewer).id
      assert Repo.reload!(ctx.composition).current_published_version_id == ctx.version.id
      assert claim_counts() == before
    end

    test "is idempotent, checks the expected pointer, and refuses a replay of a different act",
         ctx do
      accept!(ctx)
      k = key()
      {:ok, receipt} = publish(ctx, key: k)

      assert {:ok, ^receipt} = publish(ctx, key: k)
      assert {:error, :already_published} = publish(ctx, expected: ctx.version.id)

      {:ok, v2} =
        Compositions.create_version(ctx.contributor, ctx.composition.id, %{
          lead: content_spec(ctx.bierce, ctx.love),
          reason: "lead only",
          expected_parent: ctx.version.id
        })

      accept!(ctx, v2)

      assert {:error, :idempotency_conflict} =
               publish(ctx, version: v2, key: k, expected: ctx.version.id)

      assert {:error, {:stale_pointer, current}} = publish(ctx, version: v2, expected: nil)
      assert current == ctx.version.id

      assert {:ok, second} = publish(ctx, version: v2, expected: ctx.version.id)
      assert second.previous_version_id == ctx.version.id
      assert Repo.aggregate(CompositionPublication, :count) == 2
      settle!()
    end

    test "stale fingerprints, a withdrawn approval and a changed configuration refuse", ctx do
      accept!(ctx)
      withdraw_revision!(ctx.definition)
      assert {:error, {:ineligible, [{:highlight, 2, :revision_withdrawn}]}} = publish(ctx)

      restore_revision!(ctx.definition)

      {:ok, _} =
        Reviews.decide(ctx.reviewer, ctx.version.id, :needs_review,
          reason: "second look",
          idempotency_key: key()
        )

      assert {:error, :not_approved} = publish(ctx)

      accept!(ctx)

      {:ok, _} =
        Configurations.disable(ctx.reviewer, ctx.config.id,
          reason: "pause",
          idempotency_key: key(),
          expected: ctx.config_version.id
        )

      assert {:error, :configuration_changed} = publish(ctx)
      assert Repo.aggregate(CompositionPublication, :count) == 0
    end

    test "the database refuses a pointer without a receipt, and a receipt without the latest acceptance",
         ctx do
      review = accept!(ctx)
      settle!()

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE editorial_compositions SET current_published_version_id = $1 WHERE id = $2",
                   [
                     ctx.version.id,
                     ctx.composition.id
                   ]
                 )
               end)

      assert message =~ "latest publication receipt"

      {:ok, _} =
        Reviews.decide(ctx.reviewer, ctx.version.id, :withdrawn,
          reason: "changed my mind",
          idempotency_key: key()
        )

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.insert!(%CompositionPublication{
                   composition_id: ctx.composition.id,
                   action: :publish,
                   published_version_id: ctx.version.id,
                   authorizing_review_id: review.id,
                   actor_id: actor!(ctx.reviewer).id,
                   reason: "on a superseded acceptance",
                   eligibility_fingerprint: ctx.version.eligibility_fingerprint,
                   idempotency_key: key()
                 })
               end)

      assert message =~ "latest review"
    end
  end

  describe "reading (R6)" do
    test "answers the published arrangement and nothing else", ctx do
      accept!(ctx)
      {:ok, receipt} = publish(ctx)

      assert {:ok, published} = Published.current(ctx.composition.id)
      assert published.version.id == ctx.version.id
      assert published.receipt.id == receipt.id
      assert published.lead.item_object_id == ctx.bierce.object_id
      assert Enum.map(published.highlights, & &1.position) == [1, 2]
      assert published.withheld == []
    end

    test "withholds an ineligible item and never substitutes another", ctx do
      accept!(ctx)
      {:ok, _} = publish(ctx)
      withdraw_revision!(ctx.definition)

      assert {:ok, published} = Published.current(ctx.composition.id)
      assert Enum.map(published.highlights, & &1.position) == [1]
      assert published.withheld == [%{role: :highlight, position: 2, reason: :revision_withdrawn}]

      # Record-level takedown and inactive sources withhold too.
      restore_revision!(ctx.definition)
      disallow_record!(ctx.bierce)

      assert {:ok, %{lead: nil, withheld: [%{role: :lead, reason: :display_restricted}]}} =
               Published.current(ctx.composition.id)
    end

    test "withholds the whole version when its approval, configuration or scope moves", ctx do
      accept!(ctx)
      {:ok, _} = publish(ctx)

      {:ok, _} =
        Reviews.decide(ctx.reviewer, ctx.version.id, :withdrawn,
          reason: "no longer",
          idempotency_key: key()
        )

      assert Published.current(ctx.composition.id) == {:withheld, [:approval_withdrawn]}

      accept!(ctx)
      assert {:ok, _} = Published.current(ctx.composition.id)

      {:ok, _} =
        Configurations.disable(ctx.reviewer, ctx.config.id,
          reason: "pause",
          idempotency_key: key(),
          expected: ctx.config_version.id
        )

      assert Published.current(ctx.composition.id) == {:withheld, [:configuration_changed]}
    end

    test "a scope change withholds until a version for the new scope is published", ctx do
      {:ok, page} =
        Compositions.provision(ctx.contributor, ctx.config.id, %{
          scope_kind: :lexical_page,
          lexeme_ids: [ctx.love.object_id],
          language_tag: "en",
          reason: "love's page"
        })

      {:ok, v} =
        Compositions.create_version(ctx.contributor, page.id, %{
          lead: content_spec(ctx.bierce, ctx.love),
          reason: "page arrangement",
          expected_parent: nil
        })

      accept!(ctx, v)
      {:ok, _} = publish(ctx, version: v)

      {:ok, _} =
        Compositions.change_scope(
          ctx.contributor,
          page.id,
          [ctx.love.object_id, ctx.amor.object_id], reason: "amor joins the page")

      assert Published.current(page.id) == {:withheld, [:scope_changed]}
      settle!()
    end

    test "a Bierce entry that appears later withholds a fallback lead, and does not promote itself",
         ctx do
      {:ok, c} =
        Compositions.provision(ctx.contributor, ctx.config.id, %{
          scope_kind: :lexeme,
          lexeme_ids: [ctx.oats.object_id],
          language_tag: "en",
          reason: "oats"
        })

      {:ok, v} =
        Compositions.create_version(ctx.contributor, c.id, %{
          lead: content_spec(ctx.oats_definition, ctx.oats),
          reason: "no Bierce entry for oats",
          expected_parent: nil
        })

      accept!(ctx, v)
      {:ok, _} = publish(ctx, version: v)
      assert {:ok, %{lead: %{item_object_id: lead}}} = Published.current(c.id)
      assert lead == ctx.oats_definition.object_id

      WordFixtures.entry!(ctx, ctx.oats, "bierce", body: "fixture later bierce entry")

      assert {:ok, %{lead: nil, withheld: [%{role: :lead, reason: :priority_source_available}]}} =
               Published.current(c.id)
    end

    test "withdrawal is its own receipt, and leaves nothing published", ctx do
      accept!(ctx)
      {:ok, published} = publish(ctx)

      opts = [reason: "take down", idempotency_key: key(), expected_pointer: ctx.version.id]

      assert {:error, :unauthorized} =
               Publications.withdraw(ctx.contributor, ctx.composition.id, opts)

      assert {:ok, receipt} = Publications.withdraw(ctx.reviewer, ctx.composition.id, opts)
      assert {:ok, ^receipt} = Publications.withdraw(ctx.reviewer, ctx.composition.id, opts)

      assert %{action: :withdraw, previous_version_id: previous, published_version_id: nil} =
               receipt

      assert previous == published.published_version_id
      assert Published.current(ctx.composition.id) == :unpublished
      settle!()
    end
  end

  describe "deletion and retention (R7)" do
    test "a deleted source revision tombstones the item, and nothing prohibited is kept", ctx do
      work = WordFixtures.concept!(nil, "fixture work")
      record = WordFixtures.record!(ctx, "wikidata", raw: %{"fixture" => "record payload"})

      [record_revision] =
        Repo.all(
          from r in "source_record_revisions",
            where: r.source_record_id == ^record.id,
            select: r.id
        )

      {:ok, v2} =
        Compositions.create_version(ctx.contributor, ctx.composition.id, %{
          lead: content_spec(ctx.bierce, ctx.love),
          highlights: [
            quotation_spec(ctx.sense, 1),
            content_spec(ctx.definition, ctx.love),
            %{
              kind: :work,
              object_id: work.object_id,
              source_record_revision_id: record_revision,
              meaning: {:lexeme, ctx.love.object_id}
            }
          ],
          reason: "with a work",
          expected_parent: ctx.version.id
        })

      accept!(ctx, v2)
      {:ok, _} = publish(ctx, version: v2)
      settle!()

      # The source is deleted: a new revision replaces the pinned one, which
      # is removed, and the work's source record goes entirely.
      pinned = Registry.current_content_revision(ctx.definition.object_id)

      {:ok, _} =
        Registry.add_content_revision(ctx.definition.object_id, %{body: "fixture replacement"})

      Repo.delete_all(from r in "content_revisions", where: r.id == ^pinned.id)
      Repo.delete_all(from r in "source_records", where: r.id == ^record.id)
      settle!()

      items = Compositions.items(v2.id)

      assert Enum.find(items, &(&1.position == 2 and &1.role == :highlight)).content_revision_id ==
               nil

      assert Enum.find(items, &(&1.position == 3)).source_record_revision_id == nil

      assert {:ok, published} = Published.current(ctx.composition.id)
      assert Enum.map(published.highlights, & &1.position) == [1]

      assert published.withheld == [
               %{role: :highlight, position: 2, reason: :revision_deleted},
               %{role: :highlight, position: 3, reason: :revision_deleted}
             ]

      # No curation row holds a source's words, only ids, hashes and locators.
      for table <-
            ~w(curation_configurations curation_configuration_versions editorial_compositions
               editorial_composition_scope_changes editorial_composition_versions
               editorial_composition_items editorial_composition_reviews
               editorial_composition_publications) do
        %{rows: rows} = Repo.query!("SELECT to_jsonb(t)::text FROM #{table} t")
        text = rows |> List.flatten() |> Enum.join("\n")

        for words <- [
              "fixture bierce entry body",
              "fixture definition body",
              "fixture quotation words",
              "record payload"
            ] do
          refute text =~ words, "#{table} keeps #{inspect(words)}"
        end
      end
    end

    test "an item's references can be nulled by a deletion, and never repointed", ctx do
      [lead | _] = Compositions.items(ctx.version.id) |> Enum.filter(&(&1.role == :lead))
      other = Registry.current_content_revision(ctx.definition.object_id)

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.update_all(from(i in CompositionItem, where: i.id == ^lead.id),
                   set: [content_revision_id: other.id]
                 )
               end)
    end
  end

  # The registry's own lifecycle and takedown switches, as a rights change or
  # a source withdrawal would set them.
  defp withdraw_revision!(content) do
    Repo.update_all(
      from(r in "content_revisions", where: r.content_id == ^content.object_id and r.is_current),
      set: [lifecycle_state: "withdrawn"]
    )
  end

  defp restore_revision!(content) do
    Repo.update_all(
      from(r in "content_revisions", where: r.content_id == ^content.object_id and r.is_current),
      set: [lifecycle_state: "active"]
    )
  end

  defp disallow_record!(content) do
    revision = Registry.current_content_revision(content.object_id)

    Repo.update_all(
      from(rec in "source_records",
        join: rev in "source_record_revisions",
        on: rev.source_record_id == rec.id,
        where: rev.id == ^revision.source_record_revision_id
      ),
      set: [display_allowed: false]
    )
  end
end
