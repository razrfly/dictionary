defmodule DevilsDictionary.Examples.ProvenanceTest do
  @moduledoc """
  #212 build 2: `Examples.Provenance.of/2`, stage by stage, from the records
  and only from them. `:unknown` where the record is silent, `:none` where it
  says nothing happened, `nil` where the viewer may not see the claim.

  `async: false` because the offline test empties the discovery provider
  registry, which is application-wide.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.{Claims, Discovery, Examples, ExemplarFixtures, Registry, Repo}
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision}
  alias DevilsDictionary.Curation.{Compositions, Publications, Reviews}
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Examples.{Manifest, Provenance, Seeder}
  alias DevilsDictionary.Registry.Entity

  # A fictional person, under a QID no real Wikidata answer is fetched for:
  # the stub below names whoever is asked "Pat Fixture".
  @subject "Q999999912"

  setup do
    world = world!()
    {config, _version} = enabled_test_configuration!(world.reviewer, "provenance")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [world.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    Map.merge(world, %{
      composition: composition,
      person: ExemplarFixtures.person!("Fixture Person")
    })
  end

  defp nominate!(ctx, subject, evidence \\ nil, attrs \\ %{}),
    do: ExemplarFixtures.nominate!(ctx.contributor, subject, ctx.sense, evidence, attrs)

  defp decide!(ctx, revision, decision \\ "accepted"),
    do: ExemplarFixtures.decide!(ctx.reviewer, revision, decision)

  # The item the word page would draw for this claim, as `viewer` reads it.
  defp item(ctx, revision, viewer \\ :internal) do
    Examples.exemplars([ctx.love.object_id], viewer)
    |> Enum.find(&(&1.claim.revision_id == revision.id))
  end

  defp publish!(ctx, revision) do
    {:ok, version} =
      Compositions.create_version(ctx.contributor, ctx.composition.id, %{
        lead: content_spec(ctx.bierce, ctx.love),
        highlights: [
          %{
            kind: :exemplar,
            assertion_revision_id: revision.id,
            meaning: {:sense_revision, Registry.current_sense_revision(ctx.sense.object_id).id}
          }
        ],
        reason: "an example of love",
        expected_parent: nil
      })

    {:ok, _} =
      Reviews.decide(ctx.reviewer, version.id, :accepted, reason: "fine", idempotency_key: key())

    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "ship it",
        idempotency_key: key(),
        expected_pointer: nil
      )

    settle!()
    {version, receipt}
  end

  defp manifest do
    manifest = %{
      "schema_version" => 1,
      "kind" => "exemplars",
      "manifest" => "fixture-v1",
      "rows" => [
        %{
          "word" => "love",
          "sense" => %{"source" => "wiktionary", "match" => "a meaning of love"},
          "subject" => %{"wikidata" => @subject, "label" => "Pat Fixture", "kind" => "person"},
          "rationale" => "fixture manifest rationale",
          "evidence" => [
            %{"url" => "https://example.test/manifest", "attribution" => "Fixture, 1 Jan"}
          ],
          "curator" => "fixture curator"
        }
      ],
      "row_count" => 1
    }

    Map.put(manifest, "checksum", Manifest.checksum(manifest))
  end

  defp seed!(ctx) do
    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(&{&1, Conformance.human(&1, "Pat Fixture")})

      Req.Test.json(conn, %{"entities" => entities})
    end)

    Seeder.run(manifest(), ctx.contributor, claim: fn _ -> {:ok, 0} end)
  end

  defp claim_counts do
    {Repo.aggregate(Assertion, :count), Repo.aggregate(AssertionRevision, :count),
     Repo.aggregate("assertion_reviews", :count)}
  end

  describe "the nomination" do
    test "a manifest's names its curator, file and row, meaning and evidence; no model", ctx do
      assert {:ok, %{results: [%{outcome: :created, assertion_id: id}]}} = seed!(ctx)
      revision = Claims.current_revision(id)
      assertion = Repo.get!(Assertion, id)

      provenance = Provenance.of(item(ctx, revision), :internal)
      assert provenance.id == "ex:#{id}"
      assert provenance.source == :none
      assert provenance.agent == :none
      assert provenance.review == :none
      assert provenance.publication == :none
      assert provenance.featured == []
      assert %{kind: :ranked, signals: %{evidence_count: 1}} = provenance.selection

      nomination = provenance.nomination
      assert nomination.by.label == "fixture curator"
      assert nomination.origin == :manifest
      assert nomination.manifest.slug == "fixture-v1"
      assert nomination.manifest.checksum == manifest()["checksum"]
      assert nomination.manifest.row == revision.metadata["row"]
      assert nomination.rationale == "fixture manifest rationale"
      assert nomination.meaning.gloss == "a meaning of love"
      assert nomination.meaning.lemma == "love"
      assert [%{role: :supports, url: "https://example.test/manifest"}] = nomination.evidence
      assert nomination.at == assertion.inserted_at
      assert nomination.shelf == nil
    end

    test "a replayed manifest is held: no new claim, revision or nomination time", ctx do
      {:ok, %{results: [%{assertion_id: id}]}} = seed!(ctx)
      before = {claim_counts(), Provenance.of(item(ctx, Claims.current_revision(id)), :internal)}

      assert {:ok, %{results: [%{outcome: :held, assertion_id: ^id}]}} = seed!(ctx)

      assert {claim_counts(), Provenance.of(item(ctx, Claims.current_revision(id)), :internal)} ==
               before
    end

    test "a form's names the account, and the shelf it came from", ctx do
      revision =
        nominate!(ctx, ctx.person, nil, %{
          metadata: %{"from_result" => 41, "provider" => "wikidata"}
        })

      provenance = Provenance.of(item(ctx, revision), :internal)
      label = actor!(ctx.contributor).label

      assert %{kind: :user, label: ^label} = provenance.nomination.by
      assert provenance.nomination.origin == :form
      assert provenance.nomination.manifest == nil

      assert provenance.nomination.shelf == %{
               provider: "wikidata",
               name: ctx.sources["wikidata"].name,
               result_id: 41
             }
    end

    test "an unknown claimant is named as the record names it", ctx do
      revision = nominate!(ctx, ctx.person, nil, %{claimant: :unknown})
      provenance = Provenance.of(item(ctx, revision), :internal)

      assert %{kind: :unknown, label: "Unknown claimant"} = provenance.nomination.by
      assert provenance.nomination.origin == :form
    end

    test "a claim the record is silent about is unknown, never 'a contributor'", ctx do
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})

      # The legacy shape: no actor, no manifest, and (on two of dev's five
      # rows) no method either.
      {:ok, legacy} =
        Claims.assert(work.object_id, "illustrates", ctx.sense.object_id, %{
          rationale: "a legacy rationale"
        })

      revision = Claims.current_revision(legacy.id)
      item = item(ctx, revision, :public)

      assert item.claim.nominated_by.label == nil
      refute item.reason =~ "contributor"

      provenance = Provenance.of(item, :public)
      assert provenance.nomination == :unknown
      assert provenance.agent == :unknown
      assert provenance.review == :none
    end

    test "a persona's method is an agent's, whose model is unknown until #197", ctx do
      bot = bot_actor!(ctx.sources["wikidata"])
      {:ok, work} = Registry.create_work(%{preferred_label: "Fixture Work", work_kind: "artwork"})

      {:ok, claim} =
        Claims.assert(work.object_id, "illustrates", ctx.sense.object_id, %{
          rationale: "a persona's rationale",
          method: "persona:fixture@1",
          origin_actor_id: bot.id,
          submitted_by_actor_id: bot.id
        })

      provenance = Provenance.of(item(ctx, Claims.current_revision(claim.id)), :internal)

      assert provenance.nomination.origin == :agent
      assert %{kind: :bot, label: "fixture bot"} = provenance.nomination.by
      assert provenance.agent == :unknown
    end
  end

  describe "the review" do
    test "names the reviewer's label and date, and says when the claim changed since", ctx do
      revision = nominate!(ctx, ctx.person)
      review = decide!(ctx, revision)
      reviewer = actor!(ctx.reviewer).label

      assert %{state: :accepted, by: %{label: ^reviewer}, context_changed?: false} =
               Provenance.of(item(ctx, revision), :public).review

      assert Provenance.of(item(ctx, revision), :public).review.decided_at == review.inserted_at

      Repo.update_all(from(e in Entity, where: e.object_id == ^ctx.person.object_id),
        set: [preferred_label: "Fixture Person, renamed"]
      )

      assert Provenance.of(item(ctx, revision), :public).review.context_changed?
    end
  end

  describe "the selection and the publication" do
    test "a composed item has both, from its version and its receipt; the card lists it", ctx do
      revision = nominate!(ctx, ctx.person)
      decide!(ctx, revision)
      {version, receipt} = publish!(ctx, revision)
      [composed] = version.id |> Compositions.items() |> Enum.filter(&(&1.role == :highlight))
      author = actor!(ctx.contributor).label
      publisher = actor!(ctx.reviewer).label

      provenance = Provenance.of(composed, :public)
      assert provenance.id == "sel:#{composed.id}"

      assert %{
               kind: :composed,
               version: 1,
               position: 1,
               selection_origin: :manual,
               selected_by: %{kind: :human, label: ^author}
             } = provenance.selection

      assert %{authority_kind: :operator, actor: %{label: ^publisher}, withdrawn_at: nil} =
               provenance.publication

      assert provenance.publication.committed_at == receipt.committed_at

      # Both histories stay apart (C5): the nomination keeps its own actor
      # and time; the selection and the publication have theirs.
      assert provenance.nomination.at == Repo.get!(Assertion, revision.assertion_id).inserted_at

      # The card's provenance lists the opening that shows the claim now.
      assert [featured] = Provenance.of(item(ctx, revision), :public).featured
      assert featured.page == %{lemma: "love", slug: "love"}
      assert featured.version == 1
      assert featured.published_at == receipt.committed_at
      assert featured.selected_by.label == author

      # Withdrawn: the item's publication says so, and the card lists nothing.
      {:ok, withdrawal} =
        Publications.withdraw(ctx.reviewer, ctx.composition.id,
          reason: "take down",
          idempotency_key: key(),
          expected_pointer: version.id
        )

      assert Provenance.of(composed, :public).publication.withdrawn_at == withdrawal.committed_at
      assert Provenance.of(item(ctx, revision), :public).featured == []
    end

    test "an item withheld at read is not featured", ctx do
      revision = nominate!(ctx, ctx.person)
      decide!(ctx, revision)
      publish!(ctx, revision)
      assert [_] = Provenance.of(item(ctx, revision), :public).featured

      Repo.update_all(from(e in Entity, where: e.object_id == ^ctx.person.object_id),
        set: [preferred_label: "Fixture Person, renamed"]
      )

      assert Provenance.of(item(ctx, revision), :public).featured == []
    end
  end

  describe "who may see it" do
    test "a claim the viewer may not see has no provenance at all", ctx do
      pending = nominate!(ctx, ctx.person)
      internal = item(ctx, pending, :internal)

      assert item(ctx, pending, :public) == nil
      assert Provenance.of(internal, :public) == nil
      assert %Provenance{nomination: %{}, review: :none} = Provenance.of(internal, :internal)
    end

    test "an instance is source-listed: its sources apart, and no nomination" do
      instance = %{
        layer: :instance,
        id: "inst:e1",
        sources: [
          %{slug: "wikidata", name: "Wikidata", tier: :middle, assertion_ids: [1]},
          %{slug: "wordnet", name: "WordNet", tier: :middle, assertion_ids: [2, 3]}
        ],
        signals: %{source_count: 2}
      }

      provenance = Provenance.of(instance, :public)

      assert Enum.map(provenance.source, &{&1.slug, &1.assertion_id}) ==
               [{"wikidata", 1}, {"wordnet", 2}, {"wordnet", 3}]

      assert provenance.nomination == :none
      assert provenance.agent == :none
      assert provenance.publication == :none
      assert %{kind: :ranked} = provenance.selection
    end
  end

  test "reading it calls no provider and no model, and a purged shelf result moves nothing (C7)",
       ctx do
    shelf = ExemplarFixtures.shelved_quotation!(ctx, ctx.love, "fixture passage words")

    revision =
      ExemplarFixtures.nominate!(ctx.contributor, shelf.quotation, ctx.sense, [], %{
        metadata: %{"from_result" => shelf.result.id, "provider" => "wikiquote"}
      })

    decide!(ctx, revision)
    publish!(ctx, revision)

    assert {1, _records} = Discovery.purge_results([shelf.run.id])
    ExemplarFixtures.offline!()

    provenance = Provenance.of(item(ctx, revision), :public)
    assert provenance.nomination.shelf.provider == "wikiquote"
    assert provenance.nomination.shelf.name == shelf.source.name
    assert [%{page: %{slug: "love"}}] = provenance.featured
    refute Repo.get(DevilsDictionary.Discovery.Result, shelf.result.id)
  end
end
