defmodule DevilsDictionary.Curation.Runtime.EvidenceGuidanceTest do
  use ExUnit.Case, async: true
  alias DevilsDictionary.Curation.Runtime.{Contract, SectionOutput}
  alias DevilsDictionary.Curation.{Shelf, WholeEntry}

  defp packet(instruction) do
    native =
      for {kind, index} <-
            Enum.with_index(~w(content sense_definition sense_quotation work exemplar claim)) do
        %{"kind" => kind, "candidate_id" => "n#{index}", "allowed_meanings" => ["m0"]}
      end

    shelves =
      for provider <- Shelf.providers() do
        %{
          "kind" => "shelf",
          "candidate_id" => provider,
          "allowed_meanings" => ["m0"],
          "shelf" => %{"shelf_kind" => Shelf.kind(provider)}
        }
      end

    %{
      "instruction_version" => instruction,
      "packet_version" => "runtime-packet-v4",
      "candidates" => native ++ shelves,
      "priority_candidates" => ["n0"],
      "meanings" => [%{"meaning_id" => "m0", "label" => "a supplied meaning"}]
    }
  end

  defp descriptions(%{
         "properties" => %{"candidate_id" => %{"enum" => [id]}, "reason" => reason}
       }),
       do: [{id, reason["description"]}]

  defp descriptions(value) when is_map(value),
    do: Enum.flat_map(Map.values(value), &descriptions/1)

  defp descriptions(value) when is_list(value), do: Enum.flat_map(value, &descriptions/1)
  defp descriptions(_), do: []

  test "every native adapter and registered server shelf provider gets evidence guidance, without source payloads" do
    p = packet("voltaire-whole-entry-v7")

    assert Enum.sort(Shelf.providers()) ==
             Enum.sort(
               DevilsDictionary.Discovery.Providers.all()
               |> Enum.filter(&(&1.capabilities().transport == :server))
               |> Enum.map(& &1.slug())
             )

    assert DevilsDictionary.Curation.Runtime.Packet.prompt_sha256(p) ==
             "083663d5b76b89d300f4582e6bbe2e91c10f9df08bafeb2492c782bf62e7bbed"

    [system, user] = DevilsDictionary.Curation.Runtime.Packet.messages(p)
    assert system.content =~ "DECIDE THE LEAD FIRST"
    visible = user.content |> String.replace_prefix("Packet:\n", "") |> Jason.decode!()
    assert visible["evidence_rules"]["shelf_news"] =~ "no article body"
    assert Enum.all?(visible["candidates"], &is_binary(&1["evidence_scope"]))
    schema = Contract.schema(p)
    rows = schema |> descriptions() |> Map.new()

    for provider <- Shelf.providers() do
      assert rows[provider]
      assert rows[provider] =~ "routing eligibility, not proof of relevance"
      assert rows[provider] =~ "Title/name match alone is insufficient"
    end

    assert rows["n0"] =~ "Definition excerpt"
    assert rows["n1"] =~ "Definition excerpt"
    assert rows["n2"] =~ "Quotation excerpt"
    assert rows["n3"] =~ "Catalog label only"
    assert rows["n4"] =~ "reviewed relationship"
    assert rows["n5"] =~ "claim representation"
    assert rows["guardian"] =~ "no article body"
    assert rows["unsplash"] =~ "descriptive caption"
    assert rows["wikiquote"] =~ "quotation words and creator"

    for provider <- ~w(cinegraph spotify open-library poetrydb),
        do: assert(rows[provider] =~ "no plot, themes, lyrics or passage")

    assert DevilsDictionary.Discovery.Providers.Giphy.capabilities().persistence == :transient
    refute "giphy" in Shelf.providers()
    assert schema["properties"]["decision"]["description"] =~ "2 definition candidates"

    assert Enum.sort(Map.keys(schema["properties"]["selections"]["properties"])) ==
             Enum.sort(WholeEntry.sections())
  end

  test "v6 and earlier schemas remain byte-for-byte equivalent to the original section schema" do
    for v <- 3..6 do
      p = packet("voltaire-whole-entry-v#{v}")
      assert Contract.schema(p) == SectionOutput.schema(p)
      [_, user] = DevilsDictionary.Curation.Runtime.Packet.messages(p)
      refute user.content =~ "evidence_rules"
      refute user.content =~ "evidence_scope"
    end
  end

  test "schema guidance is not a semantic validator and cannot certify a plausible free-text reason" do
    p = packet("voltaire-whole-entry-v7")

    empty =
      Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

    # This boundary is intentional: no keyword filter or fake entailment claim.
    wire = %{
      "decision" => "select",
      "lead" => %{
        "candidate_id" => "n0",
        "meaning_id" => "m0",
        "reason" => "An unsupported interpretation could still be grammatical."
      },
      "selections" => empty,
      "abstain_reason" => nil
    }

    assert {:ok, %{outcome: :accepted}} =
             Contract.validate(
               %{"done_reason" => "stop", "message" => %{"content" => Jason.encode!(wire)}},
               %{packet: p},
               registry: false
             )
  end
end
