defmodule DevilsDictionary.Issue84Checkpoint4Test do
  @moduledoc "Extension, attribution, scope and query-budget proof for issue #84 checkpoint 4."

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.{Catalog, Connection, Contributions, PredicateEndpointRule}
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  test "a genuinely new adaptation predicate costs data only and preserves an existing attachment" do
    # Simulate the already-fixed baseline before this checkpoint's new catalog
    # entry is loaded. There are no adaptation assertions yet, so removing just
    # this seed data is safe inside the test transaction.
    extension = Claims.predicate!("adaptation_of")
    Repo.delete_all(from r in PredicateEndpointRule, where: r.predicate_id == ^extension.id)
    Repo.delete!(extension)

    {:ok, author} = Registry.create_person(%{preferred_label: "Extension Author"})

    {:ok, original} =
      Registry.create_work(%{preferred_label: "Original Work", work_kind: "novel"})

    {:ok, attachment} = Claims.assert(original.object_id, "authored_by", author.object_id)
    attachment_revision = Claims.current_revision(attachment.id)
    migration_count = Repo.aggregate("schema_migrations", :count)

    Catalog.seed!()

    assert Claims.predicate!("adaptation_of")
    assert length(Claims.endpoint_rules("adaptation_of")) == 1
    assert Repo.aggregate("schema_migrations", :count) == migration_count
    assert Claims.current_revision(attachment.id).id == attachment_revision.id
    assert Registry.object(original.object_id).lifecycle_state == :active

    {:ok, adaptation} =
      Registry.create_work(%{preferred_label: "A New Adaptation", work_kind: "film"})

    assert {:ok, claim} =
             Claims.assert(adaptation.object_id, "adaptation_of", original.object_id)

    assert Claims.current_revision(claim.id).object_object_id == original.object_id
    assert Enum.any?(Claims.outgoing(original.object_id), &(&1.assertion_id == attachment.id))

    {:ok, artifact} =
      Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Not a work"})

    assert {:error, changeset} =
             Claims.assert(artifact.object_id, "adaptation_of", original.object_id)

    assert "does not allow these endpoint kinds" in errors_on(changeset).predicate_id
  end

  test "batched canonical resolution preserves merge chains and lifecycle events reuse one actor" do
    first = entity!(:artifact, "First historical artifact")
    second = entity!(:artifact, "Second historical artifact")
    survivor = entity!(:artifact, "Canonical artifact")

    assert {:ok, _} = Registry.merge([first.object_id], second.object_id, reason: "first merge")

    assert {:ok, _} =
             Registry.merge([second.object_id], survivor.object_id, reason: "second merge")

    assert Registry.canonical_ids([first.object_id, second.object_id, survivor.object_id]) == %{
             first.object_id => survivor.object_id,
             second.object_id => survivor.object_id,
             survivor.object_id => survivor.object_id
           }

    assert MapSet.new(Registry.canonical_family(first.object_id)) ==
             MapSet.new([first.object_id, second.object_id, survivor.object_id])

    assert Repo.aggregate(
             from(actor in DevilsDictionary.Sources.Actor,
               where: actor.actor_kind == :import and actor.label == "Registry lifecycle system"
             ),
             :count
           ) == 1
  end

  test "multiple, organization and anonymous credits work outside every scope", ctx do
    {:ok, person} = Registry.create_person(%{preferred_label: "Avery Credit"})

    {:ok, organization} =
      Registry.create_entity(%{
        entity_kind: :organization,
        preferred_label: "Example Poets Collective"
      })

    {:ok, collaborative_work} =
      Registry.create_work(%{preferred_label: "Collective Poem", work_kind: "poem"})

    {:ok, _} = Claims.assert(collaborative_work.object_id, "authored_by", person.object_id)
    {:ok, _} = Claims.assert(collaborative_work.object_id, "authored_by", organization.object_id)

    credits = Claims.outgoing(collaborative_work.object_id, predicate: "authored_by")

    assert MapSet.new(credits, & &1.object_object_id) ==
             MapSet.new([person.object_id, organization.object_id])

    assert Enum.any?(
             EntityPage.build(organization.object_id).works,
             &(&1.object_id == collaborative_work.object_id)
           )

    {:ok, anonymous_work} =
      Registry.create_work(%{preferred_label: "Anonymous Poem", work_kind: "poem"})

    assert Claims.outgoing(anonymous_work.object_id, predicate: "authored_by") == []
    assert EntityPage.build(anonymous_work.object_id).entity.object_id == anonymous_work.object_id

    {:ok, word} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: "situationship-fixture",
        part_of_speech: "noun"
      })

    {:ok, meaning} =
      Registry.create_sense(%{
        lexeme_id: word.object_id,
        source_id: ctx.sources["wiktionary"].id,
        external_key: "situationship-fixture/noun/0#0",
        gloss: "an undefined romantic relationship (offline test fixture)"
      })

    {:ok, example} =
      Registry.create_entity(%{
        entity_kind: :artifact,
        preferred_label: "Fictional situationship note"
      })

    {:ok, claim} =
      Claims.assert(example.object_id, "illustrates", meaning.object_id, %{
        rationale: "A fictional local example used only by this regression."
      })

    refute Repo.exists?(from m in ScopeMember, where: m.lexeme_id == ^word.object_id)
    assert Registry.by_external_id("wikidata", "") == nil
    assert [seen] = Claims.incoming(meaning.object_id, predicate: "illustrates")
    assert seen.assertion_id == claim.id
  end

  test "connection reader and writer stay bounded and observe fresh state without a page cache",
       ctx do
    user =
      user_fixture()
      |> Ecto.Changeset.change(internal_contributor: true)
      |> Repo.update!()

    {:ok, artifact} =
      Registry.create_entity(%{entity_kind: :artifact, preferred_label: "Budget artifact"})

    {:ok, concept} =
      Registry.create_entity(%{entity_kind: :concept, preferred_label: "Budget concept"})

    {:ok, evidence} =
      Registry.create_content(%{
        content_kind: :passage,
        source_id: ctx.sources["wordnet"].id,
        body: "Budget evidence"
      })

    {{:ok, claim}, writer_queries} =
      count_queries(fn ->
        Contributions.propose(
          Scope.for_user(user),
          artifact.object_id,
          "illustrates",
          concept.object_id,
          %{rationale: "Measure the exact contributor path"},
          [
            %{
              content_revision_id: Registry.current_content_revision(evidence.object_id).id,
              evidence_role: :supports,
              locator: "paragraph 1"
            }
          ]
        )
      end)

    {page, reader_queries} = count_queries(fn -> Connection.build(claim.id) end)

    assert writer_queries <= 24
    assert reader_queries <= 24
    assert page.review == :needs_review
    assert Application.fetch_env!(:devils_dictionary, :cache_scorecard) == false

    {:ok, changed} = Claims.revise(claim.id, %{rationale: "Changed after the measured read"})

    # Connection pages read exact database state on every build; the only named
    # application cache is for the health scorecard, not claims or evidence.
    fresh = Connection.build(claim.id)
    assert fresh.revision.id == changed.id
    assert fresh.revision.rationale == "Changed after the measured read"
  end

  test "real JSON-array sense examples load without rewriting source rows", ctx do
    {:ok, word} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: "array-example",
        part_of_speech: "noun"
      })

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: word.object_id,
        source_id: ctx.sources["wordnet"].id,
        external_key: "array-example.n.01",
        gloss: "a regression for the stored source shape",
        examples: [%{"text" => "an actual JSON array example"}]
      })

    assert Registry.current_sense_revision(sense.object_id).examples == [
             %{"text" => "an actual JSON array example"}
           ]
  end

  test "entity discovery finds aliases once and excludes retired identities" do
    {:ok, entity} =
      Registry.create_entity(%{
        entity_kind: :artifact,
        preferred_label: "Connection search canonical"
      })

    {:ok, _} = Registry.add_name(entity.object_id, entity.preferred_label, name_kind: "alias")
    {:ok, _} = Registry.add_name(entity.object_id, "Harbor ledger alias", name_kind: "alias")

    assert Enum.count(
             Encyclopedia.search_entities("Connection search canonical"),
             &(&1.object_id == entity.object_id)
           ) == 1

    assert Enum.any?(
             Encyclopedia.search_entities("Harbor ledger alias"),
             &(&1.object_id == entity.object_id)
           )

    {:ok, retired} =
      Registry.create_entity(%{
        entity_kind: :artifact,
        preferred_label: "Retired search needle"
      })

    assert {:ok, _event} = Registry.retire(retired.object_id, reason: "search visibility test")

    refute Enum.any?(
             Encyclopedia.search_entities("Retired search needle"),
             &(&1.object_id == retired.object_id)
           )
  end

  defp entity!(kind, label) do
    {:ok, entity} = Registry.create_entity(%{entity_kind: kind, preferred_label: label})
    entity
  end

  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler = "issue84-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:devils_dictionary, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {ref, :query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain_queries(ref, 0)}
  end

  defp drain_queries(ref, count) do
    receive do
      {^ref, :query} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
