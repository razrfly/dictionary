defmodule DevilsDictionary.Curation.CitationSqlTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, refused: 1]
  alias DevilsDictionary.Curation.{Compositions, CompositionItem, CompositionVersion, Digest}
  alias DevilsDictionary.Repo
  setup do: editor_world!()

  defp shelf(o, word),
    do: %{
      kind: :work,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning: {:lexeme, word.object_id},
      note: %{text: "A relevant source item illustrates the meaning."}
    }

  test "two observations of one revision have different hashes; SQL and Elixir agree; nil-object SQL stays narrow",
       world do
    metadata = %{
      "title" => "A stable fixture title with five distinct words",
      "published_at" => "2026-10-27T00:00:00Z",
      "source_url" => "https://example.test/exact"
    }

    a = observation!(world, "guardian", external_id: "same", metadata: metadata)
    b = observation!(world, "guardian", external_id: "same", metadata: metadata)
    assert a.revision.id == b.revision.id

    assert {:ok, v1} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: content_spec(world.bierce, world.love),
               highlights: [shelf(a, world.love)],
               reason: "A first observation choice.",
               expected_parent: world.published.version.id
             })

    assert {:ok, v2} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: content_spec(world.bierce, world.love),
               highlights: [shelf(b, world.love)],
               reason: "A second observation choice.",
               expected_parent: v1.id
             })

    assert v1.arrangement_hash != v2.arrangement_hash

    for version <- [v1, v2, world.published.version] do
      items = Compositions.items(version.id)

      assert %{rows: [[hash]]} =
               Repo.query!("SELECT editorial_arrangement_hash($1)", [version.id])

      assert hash == version.arrangement_hash and hash == Digest.arrangement_hash(items)
    end

    assert {:error, {:duplicate_display_identity, _}} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: content_spec(world.bierce, world.love),
               highlights: [shelf(a, world.love), shelf(b, world.love)],
               reason: "Duplicate source identity.",
               expected_parent: v2.id
             })

    chosen = Compositions.items(v2.id) |> Enum.find(& &1.shelf_citation_id)

    raw_item =
      chosen
      |> Map.from_struct()
      |> Map.take(CompositionItem.__schema__(:fields) -- [:id])
      |> Map.put(:position, 1)

    raw_version =
      v2
      |> Map.from_struct()
      |> Map.take(CompositionVersion.__schema__(:fields) -- [:id])
      |> Map.merge(%{
        version: v2.version + 1,
        parent_version_id: v2.id,
        arrangement_hash: Digest.arrangement_hash([%{chosen | role: :highlight, position: 1}]),
        eligibility_fingerprint: "raw-fixture",
        change_reason: "Raw SQL compatibility fixture"
      })

    assert :accepted =
             refused(fn ->
               {1, [%{id: id}]} =
                 Repo.insert_all(CompositionVersion, [raw_version], returning: [:id])

               assert {1, _} =
                        Repo.insert_all(CompositionItem, [
                          Map.put(raw_item, :composition_version_id, id)
                        ])
             end)

    assert {:refused, _, message} =
             refused(fn ->
               Repo.insert_all(CompositionItem, [
                 raw_item
                 |> Map.put(:composition_version_id, v2.id)
                 |> Map.put(:position, 3)
                 |> Map.put(:shelf_citation_id, nil)
               ])
             end)

    assert message =~ "registry object"
  end
end
