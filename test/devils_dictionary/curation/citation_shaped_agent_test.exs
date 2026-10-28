defmodule DevilsDictionary.Curation.CitationShapedAgentTest do
  use DevilsDictionary.DataCase, async: false
  import Ecto.Query
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.ProviderCitationFixtures
  alias DevilsDictionary.Curation.{Shelf, Compositions, Proposals, Receipt, ItemBasis}
  @moduletag :unboxed
  for slug <- Shelf.providers() do
    test "#{slug}: adapter-shaped candidate through agent choice, owner Take and public receipt" do
      world = editor_world!()
      o = provider_observation!(world, unquote(slug))

      if unquote(slug) == "poetrydb" do
        rows =
          DevilsDictionary.Repo.all(
            from r in DevilsDictionary.Discovery.Result, where: r.run_id == ^o.adapter_run_id
          )

        assert length(rows) == 2

        for row <- rows do
          expected = row.source_record_revision_id

          DevilsDictionary.Repo.query!(
            "UPDATE discovery_results SET source_record_revision_id=NULL WHERE id=$1",
            [row.id]
          )

          legacy = %{row | source_record_revision_id: nil}
          assert DevilsDictionary.Curation.ShelfCitations.bound_revision(legacy).id == expected
        end
      end

      frozen = frozen!()
      lead = Enum.find(frozen.packet["candidates"], &(&1["object_id"] == world.bierce.object_id))

      shelf =
        Enum.find(
          frozen.packet["candidates"],
          &(&1["kind"] == "shelf" and &1["shelf"]["result"] == o.result.id)
        )

      assert shelf && shelf["shelf"]["revision"] == o.revision.id

      answer =
        DevilsDictionary.RuntimeFixtures.selection(
          {lead["candidate_id"], lead["required_meaning"]},
          [{shelf["candidate_id"], shelf["required_meaning"], nil}]
        )

      stub_answer!(world, answer)
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      proposal = Proposals.pending(world.composition.id)
      items = Compositions.items(proposal.version_id)
      chosen = Enum.find(items, & &1.shelf_citation_id)
      assert ItemBasis.get(chosen.id).origin == "model"

      result =
        if unquote(slug) == "guardian" do
          lead_item = Enum.find(items, &(&1.role == :lead))

          Proposals.edit_publish(world.reviewer, proposal.id,
            reason: "This source choice belongs on the page.",
            expected_pointer: world.published.version.id,
            answers: all_yes(items),
            lead: %{
              kind: :content,
              object_id: world.bierce.object_id,
              content_revision_id: lead_item.content_revision_id,
              meaning: {:lexeme, lead_item.meaning_lexeme_id},
              note: %{text: lead_item.note}
            },
            highlights: [
              %{
                kind: :work,
                shelf: o.spec,
                source_record_revision_id: o.revision.id,
                meaning: {:lexeme, chosen.meaning_lexeme_id},
                note: %{text: chosen.note}
              }
            ]
          )
        else
          Proposals.take(world.reviewer, proposal.id,
            reason: "This source choice belongs on the page.",
            expected_pointer: world.published.version.id,
            answers: all_yes(items)
          )
        end

      assert {:ok, %{version: taken}} = result
      assert {:ok, receipt} = Receipt.read("love", taken.version)
      row = Enum.find(receipt.items, & &1.citation)
      assert row.status == :shown
      assert row.citation.discovery_result_id == o.result.id
      assert row.citation.cited_revision_id == o.revision.id
      assert row.citation.cited_checksum == o.revision.checksum
      assert row.basis.origin == "model" && row.basis.attempt_id
      assert row.basis.supplied_sha256 == shelf["label_sha256"]
    end
  end
end
