defmodule DevilsDictionary.Curation.Runtime.ContractTest do
  @moduledoc """
  C1–C3 of `docs/curation/runtime-stage-a.md`. Structured output is a claim,
  and each class of bad claim is refused with a stable reason. What is
  accepted keeps ids, meanings, reasons and quote hashes, never quoted text.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RuntimeFixtures, only: [answer: 2, abstain: 0, selection: 2]

  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.{Contract, Packet}
  alias DevilsDictionary.WordFixtures

  setup do
    world = world!()

    # A second sense, so a quotation can be tied to the wrong meaning.
    WordFixtures.sense!(world, world.love, "wiktionary", gloss: "fixture second sense")

    {:ok, packet} = Packet.build([world.love.object_id], "en")
    {:ok, frozen} = Packet.freeze(packet)
    Map.merge(world, %{frozen: frozen, packet: packet})
  end

  defp validate(ctx, content, extra \\ %{}, opts \\ []),
    do: Contract.validate(answer(content, extra), ctx.frozen, opts)

  defp reasons({:refused, reasons, _observed}), do: reasons

  test "a sound selection is accepted, and its quote kept as a hash and a range", ctx do
    assert {:ok, %{outcome: :accepted, result: result, observed: observed}} =
             validate(ctx, selection({"c1", "m0"}, [{"c3", "s1", "quotation words"}]))

    assert result["lead"] == %{
             "candidate_id" => "c1",
             "meaning_id" => "m0",
             "reason" => "It defines the word."
           }

    assert [%{"quote" => quote}] = result["highlights"]

    assert quote == %{
             "sha256" => Digest.sha256("quotation words"),
             "byte_offset" => 8,
             "byte_length" => 15
           }

    refute Jason.encode!(result) =~ "quotation words"
    assert observed["thinking_chars"] == 0
  end

  test "an abstention with a reason is valid; an inconsistent decision is not", ctx do
    assert {:ok, %{outcome: :abstained}} = validate(ctx, abstain())

    assert [["decision", "decision_inconsistent"]] =
             reasons(validate(ctx, %{abstain() | "decision" => "select"}))

    assert [["decision", "decision_inconsistent"]] =
             reasons(validate(ctx, %{selection({"c1", "m0"}, []) | "decision" => "abstain"}))
  end

  test "malformed, oversized, truncated or tool-calling output is refused", ctx do
    assert [["response", "malformed_json"]] = reasons(validate(ctx, "{\"decision\": "))
    assert [["response", "wrong_shape"]] = reasons(validate(ctx, "[1, 2]"))

    assert [["response", "output_too_large"]] =
             reasons(validate(ctx, abstain(), %{}, max_output_bytes: 10))

    assert [["response", "output_truncated"]] =
             reasons(validate(ctx, abstain(), %{"done_reason" => "length"}))

    tool = %{
      "message" => %{
        "role" => "assistant",
        "content" => Jason.encode!(abstain()),
        "tool_calls" => [%{"function" => %{"name" => "shell", "arguments" => %{}}}]
      }
    }

    assert [["response", "tool_call_refused"]] = reasons(validate(ctx, abstain(), tool))
  end

  test "extra keys, wrong types and more than three highlights are refused", ctx do
    assert [["response", "wrong_shape"]] =
             reasons(validate(ctx, Map.put(abstain(), "note", "hi")))

    many = selection({"c1", "m0"}, List.duplicate({"c2", "m0", nil}, 4))
    assert ["highlights", "too_many_highlights"] in reasons(validate(ctx, many))

    bad_lead = %{
      selection({"c1", "m0"}, [])
      | "lead" => %{"candidate_id" => 1, "meaning_id" => "m0", "reason" => "x"}
    }

    assert ["lead", "wrong_shape"] in reasons(validate(ctx, bad_lead))
  end

  test "fabricated ids, wrong meanings, fabricated quotes and duplicates are refused", ctx do
    assert [["lead", "unknown_candidate"]] = reasons(validate(ctx, selection({"c99", "m0"}, [])))

    assert [["highlight_1", "meaning_not_allowed"]] =
             reasons(validate(ctx, selection({"c1", "m0"}, [{"c3", "s2", nil}])))

    assert [["highlight_1", "fabricated_quote"]] =
             reasons(
               validate(
                 ctx,
                 selection({"c1", "m0"}, [{"c3", "s1", "words the source never said"}])
               )
             )

    assert [["selection", "duplicate_candidate"]] =
             reasons(validate(ctx, selection({"c1", "m0"}, [{"c1", "m0", nil}])))
  end

  test "Bierce first applies: another definition cannot lead where Bierce applies", ctx do
    assert [["lead", "priority_source_available"]] =
             reasons(validate(ctx, selection({"c2", "m0"}, [])))

    assert [["lead", "priority_source_missing"]] =
             reasons(validate(ctx, selection(nil, [{"c2", "m0", nil}])))

    assert ["lead", "lead_not_a_definition"] in reasons(
             validate(ctx, selection({"c3", "s1"}, []))
           )
  end

  test "evidence restricted after the packet was frozen is refused at validation", ctx do
    disallow_record!(ctx.definition)

    assert [["highlight_1", "display_restricted"]] =
             reasons(validate(ctx, selection({"c1", "m0"}, [{"c2", "m0", nil}])))
  end

  test "emitted reasoning is measured as a length and never kept", ctx do
    thinking = %{
      "message" => %{
        "role" => "assistant",
        "content" => Jason.encode!(abstain()),
        "thinking" => "hmm hmm"
      }
    }

    assert {:ok, %{outcome: :abstained, result: result, observed: %{"thinking_chars" => 7}}} =
             validate(ctx, abstain(), thinking)

    refute Jason.encode!(result) =~ "hmm"
  end
end
