defmodule DevilsDictionary.Issue84Checkpoint3Test do
  @moduledoc "Permanent command-layer regressions for issue #84 checkpoint 3."

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.AccountsFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims.{Assertion, Contributions}
  alias DevilsDictionary.Registry.{ExternalIdentifier, WorkDetails}
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    user = user_fixture()
    user = Repo.update!(Ecto.Changeset.change(user, internal_contributor: true))
    %{sources: sources, user: user, scope: Scope.for_user(user)}
  end

  test "malformed work author ids fail cleanly and structured display values fail closed", ctx do
    assert {:error, :invalid_author} =
             Contributions.create_local_entity(ctx.scope, %{
               entity_kind: "work",
               preferred_label: "Malformed author work",
               author_entity_id: "not-an-id"
             })

    refute Repo.get_by(Registry.Entity, preferred_label: "Malformed author work")

    refute DevilsDictionary.Claims.Visibility.body_displayable?(%{
             rights_metadata: %{"display" => %{"unexpected" => true}}
           })
  end

  defp entity(kind, label) do
    {:ok, entity} = Registry.create_entity(%{entity_kind: kind, preferred_label: label})
    entity
  end

  defp sense(ctx, lemma, gloss) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{language_tag: "en", lemma: lemma, part_of_speech: "noun"})

    {:ok, sense} =
      Registry.create_sense(%{
        lexeme_id: lexeme.object_id,
        source_id: ctx.sources["wordnet"].id,
        external_key: "#{lemma}-#{System.unique_integer([:positive])}",
        gloss: gloss
      })

    sense
  end

  defp passage(body) do
    {:ok, content} = Registry.create_content(%{content_kind: :passage, body: body})
    content
  end

  defp exact(content, role, locator) do
    %{
      content_revision_id: Registry.current_content_revision(content.object_id).id,
      evidence_role: role,
      locator: locator
    }
  end

  test "local typed work creation warns on duplicates and keeps external IDs evidentiary", ctx do
    author = entity(:person, "Pat Example")
    entity(:artifact, "Family Table")

    assert [%{preferred_label: "Family Table"}] =
             Contributions.duplicate_candidates("Family Table")

    assert {:ok, work} =
             Contributions.create_local_entity(ctx.scope, %{
               entity_kind: "work",
               preferred_label: "Family Table",
               description: "A locally catalogued artwork",
               work_kind: "painting",
               original_language: "zxx",
               first_published_year: "2024",
               author_entity_id: to_string(author.object_id),
               external_namespace: "museum",
               external_id: "FT-1",
               source_url: "https://museum.example/works/FT-1"
             })

    assert work.entity_kind == :work

    assert %{work_kind: "painting", first_published_year: 2024} =
             Repo.get!(WorkDetails, work.object_id)

    identifier = Repo.get_by!(ExternalIdentifier, object_id: work.object_id)
    assert identifier.status == :candidate
    assert identifier.metadata["evidence_url"] == "https://museum.example/works/FT-1"

    assert [authorship] = Claims.outgoing(work.object_id, predicate: "authored_by")
    assert authorship.object_object_id == author.object_id

    assert {:ok, artifact} =
             Contributions.create_local_entity(ctx.scope, %{
               entity_kind: "artifact",
               preferred_label: "Uncatalogued mask"
             })

    refute Repo.get_by(ExternalIdentifier, object_id: artifact.object_id)

    assert {:error, :external_id_evidence_required} =
             Contributions.create_local_entity(ctx.scope, %{
               entity_kind: "event",
               preferred_label: "Unverified event",
               external_namespace: "wikidata",
               external_id: "Q1"
             })
  end

  test "multiple citations pin versions and claimant stays distinct from submitter", ctx do
    artifact = entity(:artifact, "Family Table")
    meaning = sense(ctx, "nepotism", "favoritism shown to relatives")
    support = passage("The catalogue describes a family preference.")
    contradicts = passage("A critic disputes that interpretation.")
    cited_support = exact(support, :supports, "catalogue paragraph 2")

    {:ok, _new_revision} =
      Registry.add_content_revision(support.object_id, %{
        body: "The catalogue changed after citation selection."
      })

    assert {:ok, claim} =
             Contributions.propose(
               ctx.scope,
               artifact.object_id,
               "illustrates",
               meaning.object_id,
               %{
                 rationale: "The arrangement depicts preferential treatment.",
                 claimant: :unknown,
                 language_tag: "en",
                 context_object_id: artifact.object_id,
                 jurisdiction_entity_id: entity(:place, "Test jurisdiction").object_id,
                 valid_from: ~U[2024-01-01 00:00:00Z]
               },
               [cited_support, exact(contradicts, :contradicts, "review page 4")]
             )

    assertion = Repo.get!(Assertion, claim.id)
    claimant = Repo.get!(Actor, assertion.origin_actor_id)
    submitter = Repo.get!(Actor, assertion.submitted_by_actor_id)
    assert claimant.actor_kind == :unknown
    assert is_nil(claimant.entity_id)
    assert submitter.actor_kind == :user
    assert is_nil(submitter.entity_id)
    refute claimant.id == submitter.id

    revision = Claims.current_revision(claim.id)
    assert revision.language_tag == "en"
    assert revision.valid_from == ~U[2024-01-01 00:00:00.000000Z]

    evidence = Claims.evidence(revision.id)
    assert Enum.map(evidence, & &1.evidence_role) == [:contradicts, :supports]

    assert Enum.find(evidence, &(&1.evidence_role == :supports)).content_revision_id ==
             cited_support.content_revision_id

    refute cited_support.content_revision_id ==
             Registry.current_content_revision(support.object_id).id
  end

  test "revision and challenge create history without inheriting approval", ctx do
    artifact = entity(:artifact, "River image")
    river = sense(ctx, "bank", "land beside a river")
    support = passage("The photograph shows the river edge.")
    counter = passage("The location record identifies a reservoir wall.")

    {:ok, claim} =
      Contributions.propose(
        ctx.scope,
        artifact.object_id,
        "illustrates",
        river.object_id,
        %{rationale: "The image shows the river meaning."},
        [exact(support, :supports, "image caption")]
      )

    first = Claims.current_revision(claim.id)

    {:ok, review_context} =
      Claims.open_review_context(first.id, Claims.current_context_items(first))

    {:ok, _} = Claims.review(first.id, :accepted, review_context_id: review_context.id)
    assert Claims.review_state(first.id) == :accepted

    assert {:ok, second} =
             Contributions.revise(
               ctx.scope,
               claim.id,
               first.id,
               %{
                 rationale: "The crop shows the river meaning more precisely.",
                 change_reason: "crop changed"
               }
             )

    assert second.revision_number == 2
    assert Claims.display_review_state(second.id) == :needs_review
    assert length(Claims.evidence(second.id)) == 1
    assert Claims.review_state(first.id) == :accepted

    challenger = user_fixture()
    challenger = Repo.update!(Ecto.Changeset.change(challenger, internal_contributor: true))
    challenger_scope = Scope.for_user(challenger)

    assert {:ok, third} =
             Contributions.challenge(
               challenger_scope,
               claim.id,
               second.id,
               "the location is contested",
               [exact(counter, :supports, "location record")]
             )

    assert third.revision_number == 3
    assert third.metadata["last_editorial_change"]["action"] == "challenge"
    assert Claims.display_review_state(third.id) == :needs_review
    assert Enum.any?(Claims.evidence(third.id), &(&1.evidence_role == :contradicts))
    assert Enum.map(Claims.history(claim.id), & &1.revision_number) == [1, 2, 3]

    assert {:error, :unauthorized} =
             Contributions.revise(
               challenger_scope,
               claim.id,
               third.id,
               %{rationale: "unauthorized rewrite", change_reason: "try"}
             )
  end

  test "one artifact supports independent claims and a revoked stale scope cannot write", ctx do
    artifact = entity(:artifact, "One artifact")
    first = sense(ctx, "nepotism", "favoritism shown to relatives")
    second = sense(ctx, "inheritance", "something passed to an heir")

    assert {:ok, first_claim} =
             Contributions.propose(
               ctx.scope,
               artifact.object_id,
               "illustrates",
               first.object_id,
               %{rationale: "first interpretation"},
               []
             )

    assert {:ok, second_claim} =
             Contributions.propose(
               ctx.scope,
               artifact.object_id,
               "illustrates",
               second.object_id,
               %{rationale: "second interpretation"},
               []
             )

    refute first_claim.id == second_claim.id
    assert length(Claims.outgoing(artifact.object_id, predicate: "illustrates")) == 2

    Repo.update!(Ecto.Changeset.change(ctx.user, internal_contributor: false))

    assert {:error, :unauthorized} =
             Contributions.propose(
               ctx.scope,
               artifact.object_id,
               "illustrates",
               first.object_id,
               %{rationale: "stale session"},
               []
             )
  end
end
