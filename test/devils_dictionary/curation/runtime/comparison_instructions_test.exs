defmodule DevilsDictionary.Curation.Runtime.ComparisonInstructionsTest do
  @moduledoc """
  #298 C3, C4 and C9: the comparison-only instructions are pinned, admitted
  by every runtime allowlist and by no publication path; the generic
  control sees v7's guidance exactly; the fixed-lead variant differs from
  v7 only in its lead section, and its contract puts the rule's lead in.
  #307: the Hitchens and Bierce arms are v7 with only the lens changed.
  #305 D7: the cap and nudge arms are the fixed-lead variant with only the
  reason cap raised to 200 and, for the nudge, one section added; their
  schema and validation follow `WholeEntry.reason_cap/1`.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.{Digest, Shelf, WholeEntry}
  alias DevilsDictionary.Curation.Agents.Persona

  alias DevilsDictionary.Curation.Runtime.{
    Contract,
    EvidenceGuidance,
    Packet,
    SectionOutput
  }

  @v7 "voltaire-whole-entry-v7"
  @generic "generic-whole-entry-v1"
  @fixed "voltaire-whole-entry-v7-fixed-lead-v1"
  @personas %{"hitchens" => "hitchens-whole-entry-v1", "bierce" => "bierce-whole-entry-v1"}
  @cap200 "voltaire-whole-entry-v7-fixed-lead-cap200-v1"
  @nudge "voltaire-whole-entry-v7-fixed-lead-cap200-nudge-v1"

  defp packet(instruction, extra \\ %{}) do
    native =
      for {kind, index} <-
            Enum.with_index(~w(content sense_definition sense_quotation work exemplar claim)) do
        %{
          "kind" => kind,
          "candidate_id" => "n#{index}",
          "allowed_meanings" => ["m0"],
          "required_meaning" => "m0"
        }
      end

    shelves =
      for provider <- Shelf.providers() do
        %{
          "kind" => "shelf",
          "candidate_id" => provider,
          "allowed_meanings" => ["m0"],
          "required_meaning" => "m0",
          "shelf" => %{"shelf_kind" => Shelf.kind(provider)}
        }
      end

    Map.merge(
      %{
        "instruction_version" => instruction,
        "packet_version" => "runtime-packet-v4",
        "candidates" => native ++ shelves,
        "priority_candidates" => ["n0"],
        "meanings" => [%{"meaning_id" => "m0", "label" => "a supplied meaning"}]
      },
      extra
    )
  end

  defp empty_sections,
    do: Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

  # The lines `b` drops from `a` and the lines it adds, in order.
  defp changed_lines(a, b) do
    diff = List.myers_difference(String.split(a, "\n"), String.split(b, "\n"))

    {Keyword.get_values(diff, :del) |> List.flatten(),
     Keyword.get_values(diff, :ins) |> List.flatten()}
  end

  # A schema with every reason cap raised from 100 to 200.
  defp raised(%{"maxLength" => 100} = map), do: raised(%{map | "maxLength" => 200})
  defp raised(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, raised(v)} end)
  defp raised(list) when is_list(list), do: Enum.map(list, &raised/1)
  defp raised(value), do: value

  defp validate(wire, packet) do
    Contract.validate(
      %{"done_reason" => "stop", "message" => %{"content" => Jason.encode!(wire)}},
      %{packet: packet},
      registry: false
    )
  end

  describe "pinned texts" do
    test "the comparison instructions are pinned and v7 is unchanged" do
      assert Digest.sha256(Packet.instruction!(@v7)) ==
               "a3219a5c496dbbfc6d731d87138191293a7f8243f4080f8b2067f27d5d8e853c"

      assert Digest.sha256(Packet.instruction!(@generic)) ==
               "0423863dffdbf3b1d7780b66ce0a2483bcca5082d116d2a743e614ec6c27d28f"

      assert Digest.sha256(Packet.instruction!(@fixed)) ==
               "2af1ca1aee77687ef4e302253c36ded81ea64cdfcd35ab12d0447515a4754183"

      assert Digest.sha256(Packet.instruction!(@personas["hitchens"])) ==
               "3463bce9960a3919fbe8d9ef79aea83a06e8cfc3d15800338ee1cfdf73abe9ab"

      assert Digest.sha256(Packet.instruction!(@personas["bierce"])) ==
               "b02355a9a294f4f4c5deca7d07325ae705fda6dec045ab2b64e7ac92efcb57f0"

      assert Digest.sha256(Packet.instruction!(@cap200)) ==
               "3a3ef1f2511d3294dcaf77b238e971653eac61153dadfab788184128a3bca2ec"

      assert Digest.sha256(Packet.instruction!(@nudge)) ==
               "75fd00d7658a2f99f992f6b2841db5d8f3e1a2d9986e72a43c22d22007ae970e"
    end

    test "the generic control is v7's evidence policy without a dossier" do
      generic = Packet.instruction!(@generic)
      assert generic == Packet.grounded_policy()
      assert String.starts_with?(Packet.instruction!(@v7), generic)
      refute generic =~ "Selection lens"
      refute generic =~ "Voltaire"
      assert generic =~ "ONE EVIDENCE RULE ACROSS ALL TYPES AND PROVIDERS"
      assert generic =~ "Sections: one additional definition or null"
    end

    test "v7 is the grounded body with the Voltaire lens, composed by slug" do
      lens = "voltaire" |> Persona.manifest!(5) |> Persona.lens()
      assert Packet.grounded_with_lens(lens) == Packet.instruction!(@v7)
    end

    test "a persona arm is v7's policy byte for byte with its dossier's lens (#307)" do
      v7 = Packet.instruction!(@v7)
      v7_lens = "voltaire" |> Persona.manifest!(5) |> Persona.lens()
      policy = String.replace_suffix(v7, v7_lens, "")
      assert byte_size(policy) == byte_size(v7) - byte_size(v7_lens)

      for {slug, instruction} <- @personas do
        text = Packet.instruction!(instruction)

        # The dossier on disk, read without `Persona`: disclosure, a newline
        # and selection, as Voltaire's lens is compiled.
        %{"template_version" => ^instruction, "dossier" => d} =
          "priv/curation/agents/personas/#{slug}/v1/profile.json"
          |> File.read!()
          |> Jason.decode!()

        lens = d["disclosure"] <> "\n" <> d["selection"]
        assert lens == slug |> Persona.manifest!(1) |> Persona.lens()
        assert text == policy <> lens
        assert text == Packet.grounded_with_lens(lens)
        assert String.starts_with?(text, Packet.grounded_policy())
        refute text =~ "Voltaire"
      end
    end

    test "the fixed-lead variant differs from v7 only by its lead clause" do
      fixed = Packet.instruction!(@fixed)
      assert String.replace(fixed, Packet.fixed_lead_clause(), "") == Packet.instruction!(@v7)
      assert fixed =~ "If fixed_lead is null, DECIDE THE LEAD FIRST:\n"
      [before, _after] = String.split(fixed, "CHECK EVERY OPTIONAL CHOICE:")
      [v7_before, _] = String.split(Packet.instruction!(@v7), "CHECK EVERY OPTIONAL CHOICE:")
      assert String.replace(before, Packet.fixed_lead_clause(), "") == v7_before
    end

    test "the cap arm differs from the fixed-lead variant only by its cap sentence (#305 D7)" do
      fixed = Packet.instruction!(@fixed)
      cap200 = Packet.instruction!(@cap200)
      old = "Keep each original reason under 100 characters."
      new = "Keep each original reason under 200 characters."

      assert [_, _] = String.split(fixed, old)
      assert String.replace(cap200, new, old) == fixed
      assert {[line], [cap_line]} = changed_lines(fixed, cap200)
      assert String.starts_with?(line, old)
      assert cap_line == String.replace(line, old, new)
    end

    test "the nudge arm is the cap arm with one section before the output rules (#305 D7)" do
      cap200 = Packet.instruction!(@cap200)
      nudge = Packet.instruction!(@nudge)
      section = Packet.after_lead_section()

      assert String.replace(nudge, section, "") == cap200
      assert nudge =~ section <> "OUTPUT AND SAFETY:\n"
      assert {[], added} = changed_lines(cap200, nudge)
      assert Enum.join(added, "\n") <> "\n" == section

      # The nudge never weakens the grounding rule it sits under.
      assert section =~
               "a candidate's own supplied fields support both its meaning and its reason"

      assert section =~ "Leave a section empty only when no candidate in it is so supported."
      assert section =~ "never lowers the evidence bar"
      assert nudge =~ "Sparse sections may honestly remain empty."
      assert nudge =~ "every optional section may honestly stay empty"
    end
  end

  describe "allowlists" do
    test "every runtime allowlist admits the comparison instructions" do
      assert WholeEntry.comparison_instructions() ==
               [@generic, @fixed, @personas["hitchens"], @personas["bierce"], @cap200, @nudge]

      for instruction <- WholeEntry.comparison_instructions() do
        assert instruction in Packet.instruction_versions()
        assert instruction in WholeEntry.instructions()
        assert SectionOutput.enabled?(%{"instruction_version" => instruction})

        assert Contract.version(instruction) ==
                 if(instruction in [@cap200, @nudge],
                   do: "selection-output-v5",
                   else: "selection-output-v4"
                 )

        assert EvidenceGuidance.policy(instruction) == "evidence-guidance-v1"
        assert {:ok, _frozen} = Packet.freeze(packet(instruction))
      end

      assert EvidenceGuidance.policy(@v7) == "evidence-guidance-v1"
      assert is_nil(EvidenceGuidance.policy("voltaire-whole-entry-v6"))
      assert WholeEntry.fixed_lead_instructions() == [@fixed, @cap200, @nudge]
    end

    test "no publication path admits a comparison instruction" do
      for instruction <- WholeEntry.comparison_instructions() do
        refute instruction in WholeEntry.publishing_instructions()

        refute WholeEntry.coherent?(%{
                 "selection_scope" => "whole_entry_v1",
                 "max_highlights" => 12,
                 "editor" => %{"instruction_version" => instruction}
               })

        refute WholeEntry.coherent?(%{
                 "max_highlights" => 3,
                 "editor" => %{"instruction_version" => instruction}
               })
      end

      assert WholeEntry.coherent?(%{
               "selection_scope" => "whole_entry_v1",
               "max_highlights" => 12,
               "editor" => %{"instruction_version" => @v7}
             })
    end
  end

  describe "guidance parity" do
    test "the generic control sees exactly v7's packet, guidance and schema" do
      [v7_system, v7_user] = Packet.messages(packet(@v7))
      [generic_system, generic_user] = Packet.messages(packet(@generic))

      assert generic_user.content == v7_user.content
      assert v7_user.content =~ "evidence_rules"
      assert Contract.schema(packet(@generic)) == Contract.schema(packet(@v7))
      refute generic_system.content == v7_system.content

      assert Packet.evidence_fingerprint(packet(@generic)) ==
               Packet.evidence_fingerprint(packet(@v7))

      refute Packet.prompt_sha256(packet(@generic)) == Packet.prompt_sha256(packet(@v7))
    end

    test "a persona arm sees exactly v7's packet, guidance and schema (#307)" do
      [v7_system, v7_user] = Packet.messages(packet(@v7))

      for instruction <- Map.values(@personas) do
        [system, user] = Packet.messages(packet(instruction))
        assert system.content == Packet.instruction!(instruction)
        refute system.content == v7_system.content
        assert user.content == v7_user.content
        assert Contract.schema(packet(instruction)) == Contract.schema(packet(@v7))

        assert Packet.evidence_fingerprint(packet(instruction)) ==
                 Packet.evidence_fingerprint(packet(@v7))

        refute Packet.prompt_sha256(packet(instruction)) == Packet.prompt_sha256(packet(@v7))
      end
    end

    test "the cap and nudge arms see exactly the fixed-lead variant's packet (#305 D7)" do
      [fixed_system, fixed_user] = Packet.messages(packet(@fixed, %{"fixed_lead" => "n0"}))

      for instruction <- [@cap200, @nudge] do
        p = packet(instruction, %{"fixed_lead" => "n0"})
        [system, user] = Packet.messages(p)
        assert system.content == Packet.instruction!(instruction)
        refute system.content == fixed_system.content
        assert user.content == fixed_user.content

        assert Packet.evidence_fingerprint(p) ==
                 Packet.evidence_fingerprint(packet(@fixed, %{"fixed_lead" => "n0"}))

        refute Packet.prompt_sha256(p) ==
                 Packet.prompt_sha256(packet(@fixed, %{"fixed_lead" => "n0"}))
      end
    end

    test "v7's synthetic prompt is unchanged by the policy list" do
      v7 = %{
        "instruction_version" => @v7,
        "packet_version" => "runtime-packet-v4",
        "candidates" =>
          packet(@v7)["candidates"] |> Enum.map(&Map.delete(&1, "required_meaning")),
        "priority_candidates" => ["n0"],
        "meanings" => [%{"meaning_id" => "m0", "label" => "a supplied meaning"}]
      }

      assert Packet.prompt_sha256(v7) ==
               "083663d5b76b89d300f4582e6bbe2e91c10f9df08bafeb2492c782bf62e7bbed"
    end
  end

  describe "the rule-fixed lead" do
    test "the schema asks for a null lead and a selection, and guidance says so" do
      schema = Contract.schema(packet(@fixed, %{"fixed_lead" => "n0"}))
      assert schema["properties"]["lead"] == %{"type" => "null"}
      assert schema["properties"]["decision"]["enum"] == ["select"]
      assert schema["properties"]["abstain_reason"] == %{"type" => "null"}
      assert schema["properties"]["decision"]["description"] =~ "fixed by rule"

      # Without a priority candidate the lead stays the model's, as in v7.
      open = packet(@fixed, %{"fixed_lead" => nil, "priority_candidates" => []})
      v7 = packet(@v7, %{"priority_candidates" => []})
      assert Contract.schema(open) == Contract.schema(v7)
    end

    test "the rule's lead is put in, marked, under its candidate's meaning" do
      p = packet(@fixed, %{"fixed_lead" => "n0"})

      wire = %{
        "decision" => "select",
        "lead" => nil,
        "selections" =>
          Map.put(empty_sections(), "quotes", [
            %{
              "candidate_id" => "n2",
              "meaning_id" => "m0",
              "reason" => "Its words show the meaning.",
              "quote" => nil
            }
          ]),
        "abstain_reason" => nil
      }

      assert {:ok, %{outcome: :accepted, result: result}} = validate(wire, p)
      assert result["lead"]["candidate_id"] == "n0"
      assert result["lead"]["meaning_id"] == "m0"
      assert result["lead"]["reason"] == Contract.fixed_lead_reason()
      assert result["lead"]["reason_origin"] == "rule"
      assert [%{"candidate_id" => "n2"} = highlight] = result["highlights"]
      refute Map.has_key?(highlight, "reason_origin")

      # Lead only: a selection with every section empty is still accepted.
      assert {:ok, %{outcome: :accepted, result: %{"highlights" => []}}} =
               validate(%{wire | "selections" => empty_sections()}, p)
    end

    test "a model lead, an abstention or a repeated lead is refused, never repaired" do
      p = packet(@fixed, %{"fixed_lead" => "n0"})

      lead = %{"candidate_id" => "n0", "meaning_id" => "m0", "reason" => "It defines it."}

      base = %{
        "decision" => "select",
        "lead" => nil,
        "selections" => empty_sections(),
        "abstain_reason" => nil
      }

      assert {:refused, [["lead", "fixed_lead_not_null"]], _} =
               validate(%{base | "lead" => lead}, p)

      assert {:refused, [["decision", "fixed_lead_requires_select"]], _} =
               validate(%{base | "decision" => "abstain", "abstain_reason" => "No."}, p)

      repeated =
        Map.put(base, "selections", %{
          empty_sections()
          | "definitions" => Map.put(lead, "quote", nil)
        })

      assert {:refused, reasons, _} = validate(repeated, p)
      assert ["definitions", "lead_candidate_repeated"] in reasons
    end
  end

  describe "the reason cap (#305 D7)" do
    test "every instruction keeps 100 characters except the two cap arms" do
      for instruction <- Packet.instruction_versions() do
        cap = WholeEntry.reason_cap(instruction)
        assert cap == if(instruction in [@cap200, @nudge], do: 200, else: 100)
        # `Contract` bounds every reason at 280 characters.
        assert cap <= 280
      end
    end

    test "each grounded instruction's text states its own cap" do
      for instruction <- [@v7 | WholeEntry.comparison_instructions()] do
        text = Packet.instruction!(instruction)
        cap = WholeEntry.reason_cap(instruction)
        assert text =~ "Keep each original reason under #{cap} characters."
        assert length(String.split(text, "Keep each original reason under")) == 2
      end
    end

    test "the cap arms' schema is the fixed-lead schema with every reason cap at 200" do
      for extra <- [%{"fixed_lead" => "n0"}, %{"fixed_lead" => nil, "priority_candidates" => []}],
          instruction <- [@cap200, @nudge] do
        schema = Contract.schema(packet(instruction, extra))
        assert schema == raised(Contract.schema(packet(@fixed, extra)))
        refute schema == Contract.schema(packet(@fixed, extra))
      end

      open = Contract.schema(packet(@cap200, %{"fixed_lead" => nil, "priority_candidates" => []}))

      assert open["properties"]["abstain_reason"] ==
               %{"anyOf" => [%{"type" => "null"}, %{"type" => "string", "maxLength" => 200}]}

      # v7 and the fixed-lead variant keep 100.
      for instruction <- [@v7, @fixed] do
        v4 = Contract.schema(packet(instruction, %{"fixed_lead" => nil}))
        assert raised(v4) != v4

        assert get_in(v4, ["properties", "abstain_reason", "anyOf"]) |> List.last() ==
                 %{"type" => "string", "maxLength" => 100}
      end
    end

    test "validation admits a reason up to the arm's cap and refuses one over it" do
      wire = fn length ->
        %{
          "decision" => "select",
          "lead" => nil,
          "selections" =>
            Map.put(empty_sections(), "quotes", [
              %{
                "candidate_id" => "n2",
                "meaning_id" => "m0",
                "reason" => String.duplicate("x", length),
                "quote" => nil
              }
            ]),
          "abstain_reason" => nil
        }
      end

      fixed = packet(@fixed, %{"fixed_lead" => "n0"})

      for instruction <- [@cap200, @nudge] do
        p = packet(instruction, %{"fixed_lead" => "n0"})
        assert {:ok, %{outcome: :accepted}} = validate(wire.(150), p)
        assert {:ok, %{outcome: :accepted}} = validate(wire.(200), p)
        assert {:refused, reasons, _} = validate(wire.(201), p)
        assert ["highlight_1", "reason_too_long"] in reasons
      end

      assert {:ok, %{outcome: :accepted}} = validate(wire.(100), fixed)
      assert {:refused, reasons, _} = validate(wire.(150), fixed)
      assert ["highlight_1", "reason_too_long"] in reasons

      # Without a fixed lead the abstention reason follows the same cap.
      abstain = %{
        "decision" => "abstain",
        "lead" => nil,
        "selections" => empty_sections(),
        "abstain_reason" => String.duplicate("x", 150)
      }

      open = %{"fixed_lead" => nil, "priority_candidates" => []}
      assert {:ok, _} = validate(abstain, packet(@cap200, open))
      assert {:refused, reasons, _} = validate(abstain, packet(@fixed, open))
      assert ["abstain_reason", "reason_too_long"] in reasons
    end
  end
end
