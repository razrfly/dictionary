defmodule DevilsDictionary.Curation.CitationClaimsTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.WordFixtures
  alias DevilsDictionary.{Claims, Repo}
  alias DevilsDictionary.Curation.{Candidates, LinkedClaims, Compositions, ItemBasis, Eligibility}
  setup do: editor_world!()

  test "all four public linked paths are selectable without writing a claim, vote or review",
       world do
    sense = world.profound
    class = concept!("Q270001", "Fixture class")
    entity = concept!("Q270002", "Fixture entity")
    link = link!(world.love, class, sense: sense)
    p31 = concept_relation!(world, entity, :instance_of, class)
    candidate = link!(world.love, entity, method: :title_match)
    named = word!(world, "Fixture Named Instance", ~w(wordnet), scope: nil)

    named_sense =
      sense!(world, named, "wordnet",
        group_key: "fixture-named-instance",
        gloss: "A named fixture"
      )

    edge =
      relation!(world, named, :instance_of, nil,
        source: "wordnet",
        from_sense: named_sense,
        to_sense: sense
      )

    rows = LinkedClaims.for_scope([world.love.object_id])

    for {assertion, path} <- [{edge, "a"}, {p31, "b"}, {link, "c"}, {candidate, "d"}] do
      choice =
        Enum.find(rows, &(&1.claim.assertion_id == assertion.id and &1.basis["path"] == path))

      assert choice

      spec = %{
        kind: :claim,
        object_id: choice.claim.subject_object_id,
        assertion_revision_id: choice.claim.id,
        meaning: choice.meaning,
        basis: choice.basis
      }

      assert Eligibility.check(Candidates.probe(spec), [world.love.object_id]) == :ok
    end

    before =
      {Repo.aggregate(DevilsDictionary.Claims.Assertion, :count),
       Repo.aggregate(DevilsDictionary.Claims.AssertionReview, :count),
       Repo.aggregate(DevilsDictionary.Claims.AssertionVote, :count)}

    choice = Enum.find(rows, &(&1.claim.assertion_id == p31.id))

    spec = %{
      kind: :claim,
      object_id: choice.claim.subject_object_id,
      assertion_revision_id: choice.claim.id,
      meaning: choice.meaning,
      basis: choice.basis,
      note: %{text: "The source places this named thing under this meaning."}
    }

    assert {:ok, v} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: DevilsDictionary.CurationFixtures.content_spec(world.bierce, world.love),
               highlights: [spec],
               reason: "An existing relationship illustrates this meaning.",
               expected_parent: world.published.version.id
             })

    item = Compositions.items(v.id) |> Enum.find(&(&1.item_kind == :claim))
    basis = ItemBasis.get(item.id)
    assert basis.witness_assertion_revision_id == Claims.current_revision(link.id).id
    entity |> Ecto.Changeset.change(preferred_label: "Renamed fixture entity") |> Repo.update!()
    assert ItemBasis.get(item.id).representation == basis.representation
    assert Eligibility.check(item, [world.love.object_id]) == :ok

    assert {Repo.aggregate(DevilsDictionary.Claims.Assertion, :count),
            Repo.aggregate(DevilsDictionary.Claims.AssertionReview, :count),
            Repo.aggregate(DevilsDictionary.Claims.AssertionVote, :count)} == before

    assert {:ok, _} = Claims.review(Claims.current_revision(link.id).id, :rejected)
    assert Eligibility.check(item, [world.love.object_id]) == {:error, :claim_unlinked}
  end
end
