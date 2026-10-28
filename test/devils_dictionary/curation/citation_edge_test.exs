defmodule DevilsDictionary.Curation.CitationEdgeTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.RefreshFixtures, only: [page: 1]
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2]
  alias DevilsDictionary.Curation.{Candidates, Compositions, Eligibility}
  alias DevilsDictionary.Repo
  setup do: editor_world!()

  defp create(world, highlights, parent \\ nil),
    do:
      Compositions.create_version(world.reviewer, world.composition.id, %{
        lead: content_spec(world.bierce, world.love),
        highlights: highlights,
        reason: "A fixture source selection.",
        expected_parent: parent || world.published.version.id
      })

  defp note(spec),
    do: Map.put(spec, :note, %{text: "A relevant choice illustrates this meaning."})

  test "a gloss and distinct quotation of the same sense are not duplicate displays", world do
    candidates = Candidates.for_page(page("love")).highlights

    quotation =
      Enum.find(
        candidates,
        &(&1.kind == :sense_quotation and &1.spec.object_id == world.profound.object_id)
      )

    gloss =
      Enum.find(
        candidates,
        &(&1.kind == :sense_definition and &1.spec.object_id == world.profound.object_id)
      )

    assert {:ok, _} = create(world, [note(gloss.spec), note(quotation.spec)])
  end

  test "a gloss behind the selected revision must still hash to the selected words", world do
    gloss =
      Candidates.for_page(page("love")).highlights |> Enum.find(&(&1.kind == :sense_definition))

    assert {:ok, v} = create(world, [note(gloss.spec)])
    item = Compositions.items(v.id) |> Enum.find(&(&1.item_kind == :sense_definition))

    Repo.update_all(
      from(revision in DevilsDictionary.Registry.SenseRevision,
        where: revision.id == ^item.sense_revision_id
      ), set: [gloss: "Changed fixture definition words."])

    assert Eligibility.check(item, Compositions.member_ids(world.composition.id)) ==
             {:error, :words_changed}
  end

  test "fresh owner representations cannot invent labels or reuse stale screen fields", world do
    entity = DevilsDictionary.WordFixtures.concept!("Q270902", "Original fixture entity")
    DevilsDictionary.WordFixtures.link!(world.love, entity, sense: world.profound)

    choice =
      Candidates.for_page(page("love")).highlights
      |> Enum.find(&(&1.kind == :claim and &1.spec.basis["shown_object_id"] == entity.object_id))

    forged =
      put_in(
        choice.spec,
        [:basis, "representation", "object_label"],
        "Invented editorial content"
      )

    assert {:error, {:claim_basis_mismatch, :highlight, 1}} = create(world, [note(forged)])
    assert {:ok, v} = create(world, [note(choice.spec)])
    entity |> Ecto.Changeset.change(preferred_label: "Renamed fixture entity") |> Repo.update!()

    assert {:error, {:claim_basis_mismatch, :highlight, 1}} =
             create(world, [note(choice.spec)], v.id)

    item = Compositions.items(v.id) |> Enum.find(&(&1.item_kind == :claim))
    assert Eligibility.check(item, Compositions.member_ids(world.composition.id)) == :ok
  end

  test "lost materialization and item revision never become originally nil-object choices",
       world do
    entity = DevilsDictionary.WordFixtures.concept!("Q270903", "Materialized fixture entity")
    o = observation!(world, "guardian", object_id: entity.object_id)
    now = DateTime.utc_now()

    Repo.insert_all("source_materialized_outputs", [
      %{
        source_record_id: o.record.id,
        output_role: "work",
        output_key: "fixture:#{entity.object_id}",
        output_object_id: entity.object_id,
        inserted_at: now,
        updated_at: now
      }
    ])

    spec = %{
      kind: :work,
      object_id: entity.object_id,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning: {:lexeme, world.love.object_id}
    }

    assert {:ok, v} = create(world, [note(spec)])
    item = Compositions.items(v.id) |> Enum.find(& &1.shelf_citation_id)
    members = Compositions.member_ids(world.composition.id)
    assert Eligibility.check(%{item | item_object_id: nil}, members) == {:error, :object_deleted}

    assert Eligibility.check(%{item | source_record_revision_id: nil}, members) ==
             {:error, :revision_deleted}
  end
end
