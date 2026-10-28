defmodule DevilsDictionary.Curation.CitationReceiptTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures, only: [publish!: 4]
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, key: 1]
  alias DevilsDictionary.Curation.{Receipt, Reviews, Publications}

  test "historical receipts name their own replacement and never inherit another version's withholding" do
    world = editor_world!()

    %{version: v2, receipt: p2} =
      publish!(world, world.composition, world.published.version.id,
        highlights: [
          Map.put(content_spec(world.johnson, world.love), :note, %{
            text: "A second fixture selection."
          })
        ]
      )

    %{version: v3} =
      publish!(world, world.composition, v2.id,
        highlights: [
          Map.put(content_spec(world.johnson, world.love), :note, %{
            text: "A third fixture selection."
          })
        ]
      )

    assert {:ok, old} = Receipt.read("love", world.published.version.version)

    assert Enum.all?(
             old.items,
             &(&1.status == :replaced and &1.replacement.version == v2.version and
                 &1.replacement.at == p2.committed_at)
           )

    assert {:ok, _} =
             Reviews.decide(world.reviewer, v3.id, :rejected,
               reason: "Reassess this version.",
               idempotency_key: key("reject")
             )

    assert {:ok, current} = Receipt.read("love", v3.version)

    assert Enum.all?(
             current.items,
             &(&1.status == :withheld and match?({:publication_withheld, _}, &1.status_reason))
           )

    assert DevilsDictionaryWeb.Opening.withheld_reason(hd(current.items).status_reason) =~
             "approval"

    assert {:ok, still_old} = Receipt.read("love", world.published.version.version)
    assert Enum.all?(still_old.items, &(&1.status == :replaced and &1.status_reason == nil))

    assert {:ok, _} =
             Publications.withdraw(world.reviewer, world.composition.id,
               reason: "withdrawn_by_owner",
               idempotency_key: key("withdraw"),
               expected_pointer: v3.id
             )

    assert {:ok, withdrawn} = Receipt.read("love", v3.version)
    assert Enum.all?(withdrawn.items, &(&1.status == :withdrawn))
    assert {:ok, first} = Receipt.read("love", world.published.version.version)

    assert Enum.all?(
             first.items,
             &(&1.status == :replaced and &1.replacement.version == v2.version)
           )

    assert {:error, :not_found} = Receipt.read("love", v3.version + 1)
  end
end
