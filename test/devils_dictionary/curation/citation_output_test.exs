defmodule DevilsDictionary.Curation.CitationOutputTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures

  import DevilsDictionary.RuntimeFixtures,
    only: [selection: 2, answer: 1, abstain: 0, stub_ollama!: 2]

  alias DevilsDictionary.Curation.{Compositions, Proposals, ProviderText}
  alias DevilsDictionary.Curation.Runtime.{Packet, Contract, Attempt}
  alias DevilsDictionary.Repo
  @moduletag :unboxed
  setup do: editor_world!()

  test "copied model reason and abstention become markers before immutable completion; messages omit guard values",
       world do
    o = observation!(world)
    frozen = frozen!()
    news = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "shelf"))
    lead = hd(frozen.packet["candidates"])
    headline = o.raw["preview_metadata"]["title"]

    content =
      selection({lead["candidate_id"], lead["required_meaning"]}, [
        {news["candidate_id"], news["required_meaning"], nil}
      ])
      |> put_in(["highlights", Access.at(0), "reason"], headline)

    assert {:ok, %{result: result}} = Contract.validate(answer(content), frozen)
    [choice] = result["highlights"]
    assert choice["reason"] == nil and choice["reason_withheld"]["policy"] == "shelf-fields-v1"
    refute Jason.encode!(result) =~ headline

    assert {:ok, %{result: abstained}} =
             Contract.validate(answer(Map.put(abstain(), "abstain_reason", headline)), frozen)

    assert abstained["abstain_reason"] == nil
    assert abstained["abstain_reason_withheld"]
    rendered = Packet.messages(frozen) |> Jason.encode!()
    refute rendered =~ "expiring_text"
    refute rendered =~ "A distinctive discovery snippet for this fixture."
    stub_answer!(world, content)
    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    proposal = Proposals.pending(world.composition.id)
    items = Compositions.items(proposal.version_id)
    chosen = Enum.find(items, & &1.shelf_citation_id)
    assert chosen.note == nil

    assert DevilsDictionary.Curation.ItemBasis.get(chosen.id).original_reference[
             "reason_withheld"
           ]

    assert {:error, {:reason_required, :highlight, 1}} =
             Proposals.take(world.reviewer, proposal.id,
               reason: "This is a relevant choice.",
               expected_pointer: world.published.version.id,
               answers: all_yes(items)
             )

    attempt =
      Repo.get!(
        Attempt,
        Repo.get!(DevilsDictionary.Curation.CompositionVersion, proposal.version_id).attempt_id
      )

    refute Jason.encode!(attempt.result) =~ headline

    for text <- [
          headline,
          String.upcase(headline),
          "The distinctive headline with five particular phrase."
        ] do
      assert {:error, {:copies_provider_text, _}} = ProviderText.validate(text, items)
    end
  end

  test "unknown output ids and service errors retain no provider headline", world do
    o = observation!(world)
    frozen = frozen!()
    headline = o.raw["preview_metadata"]["title"]
    malformed = selection({headline, headline}, [])
    assert {:refused, _, observed} = Contract.validate(answer(malformed), frozen)
    refute Jason.encode!(observed) =~ headline
    stub_ollama!(world.model_config, chat: fn _ -> {:status, 500, %{"error" => headline}} end)
    assert {:ok, %{state: :deferred}} = run!(world)
    %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM inference_attempts t")
    refute Enum.any?(rows, fn [json] -> String.contains?(json, headline) end)
  end
end
