defmodule DevilsDictionary.Curation.CitationWithdrawalReplayTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.ProviderCitationFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, key: 1]
  alias DevilsDictionary.Curation.{Compositions, Reviews, Publications}
  setup do: editor_world!()

  test "successful withdrawal replays after another publication expires", world do
    opts = [
      reason: "Original owner withdrawal.",
      idempotency_key: key("original-withdraw"),
      expected_pointer: world.published.version.id
    ]

    assert {:ok, original} = Publications.withdraw(world.reviewer, world.composition.id, opts)
    o = provider_observation!(world, "guardian")

    spec = %{
      kind: :work,
      shelf: o.spec,
      source_record_revision_id: o.revision.id,
      meaning: {:lexeme, world.love.object_id},
      note: %{text: "A relevant source item illustrates the meaning."}
    }

    assert {:ok, v} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: content_spec(world.bierce, world.love),
               highlights: [spec],
               reason: "A relevant choice for this page.",
               expected_parent: world.published.version.id
             })

    assert {:ok, _} =
             Reviews.decide(world.reviewer, v.id, :accepted,
               reason: "The choice fits this meaning.",
               idempotency_key: key("review")
             )

    assert {:ok, _} =
             Publications.publish(world.reviewer, v.id,
               reason: "Publish the reviewed choice.",
               idempotency_key: key("publish"),
               expected_pointer: nil
             )

    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(
        config,
        :source_policies,
        Map.put(
          policies,
          "guardian",
          Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 0)
        )
      )
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)

    before_count =
      DevilsDictionary.Repo.aggregate(DevilsDictionary.Curation.CompositionPublication, :count)

    assert Publications.withdraw(world.reviewer, world.composition.id, opts) == {:ok, original}

    assert DevilsDictionary.Repo.aggregate(
             DevilsDictionary.Curation.CompositionPublication,
             :count
           ) == before_count

    assert DevilsDictionary.Repo.get!(DevilsDictionary.Curation.Composition, world.composition.id).current_published_version_id ==
             v.id

    assert {:error, :provider_text_unverifiable} =
             Publications.withdraw(world.reviewer, world.composition.id,
               reason: "A new unverified withdrawal reason.",
               idempotency_key: key("fresh-withdraw"),
               expected_pointer: v.id
             )
  end
end
