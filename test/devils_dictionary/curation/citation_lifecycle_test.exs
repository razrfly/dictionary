defmodule DevilsDictionary.Curation.CitationLifecycleTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{
    Compositions,
    Proposals,
    Receipt,
    ShelfCitation,
    ItemBasis,
    PublishedReader,
    Digest
  }

  alias DevilsDictionary.Repo
  @moduletag :unboxed

  test "agent selects exact news, owner publishes, public receipt survives expiry and actual redaction" do
    world = editor_world!()
    observation = observation!(world)
    frozen = frozen!()
    lead = Enum.find(frozen.packet["candidates"], &(&1["object_id"] == world.bierce.object_id))
    news = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "shelf"))
    assert news["shelf"]["revision"] == observation.revision.id

    answer = %{
      "decision" => "select",
      "lead" => %{
        "candidate_id" => lead["candidate_id"],
        "meaning_id" => lead["required_meaning"],
        "reason" => "This defines the word."
      },
      "highlights" => [
        %{
          "candidate_id" => news["candidate_id"],
          "meaning_id" => news["required_meaning"],
          "reason" => "A recent event gives a useful contemporary example.",
          "quote" => nil
        }
      ],
      "abstain_reason" => nil
    }

    stub_answer!(world, answer)
    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    proposal = Proposals.pending(world.composition.id)
    items = Compositions.items(proposal.version_id)
    choice = Enum.find(items, & &1.shelf_citation_id)
    assert choice
    assert ItemBasis.get(choice.id).origin == "model"
    assert ItemBasis.get(choice.id).supplied_sha256 == news["label_sha256"]

    assert {:error, :not_found} =
             Receipt.read(
               "love",
               Repo.get!(DevilsDictionary.Curation.CompositionVersion, proposal.version_id).version
             )

    assert {:ok, %{version: published}} =
             Proposals.take(world.reviewer, proposal.id,
               reason: "This choice fits the page.",
               expected_pointer: world.published.version.id,
               answers: all_yes(items)
             )

    assert {:ok, receipt} = Receipt.read("love", published.version)
    row = Enum.find(receipt.items, & &1.citation)
    assert row.status == :shown
    assert row.citation.cited_revision_id == observation.revision.id
    assert row.basis.origin == "model"

    assert row.provider_metadata["title"] ==
             observation.raw["preview_metadata"]["title"]

    assert PublishedReader.opening(page("love")).highlights != []
    c = Repo.get!(ShelfCitation, choice.shelf_citation_id)
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})
    guardian = Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 0)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, "guardian", guardian))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
    assert DevilsDictionary.Curation.ShelfCitations.check(c) == :retention_expired
    assert {:ok, expired} = Receipt.read("love", published.version)
    hidden = Enum.find(expired.items, & &1.citation)
    assert hidden.status == :withheld
    refute hidden.provider_metadata
    assert %{redacted_revisions: 1} = DevilsDictionary.Discovery.purge_expired_payloads(100)
    assert Repo.reload!(c).cited_revision_id == observation.revision.id
    assert Digest.sha256(news["label"]) == row.basis.supplied_sha256
  end
end
