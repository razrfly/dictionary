defmodule DevilsDictionary.Curation.Runtime.BenchTest do
  @moduledoc """
  The benchmark harness's own rules: fixtures go only into a `*_bench`
  database, the plan's counts are predeclared, and summaries report
  quantiles by nearest rank, leaving missing measurements missing.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Curation.Runtime.{Bench, Contract, Gateway, Packet}
  alias DevilsDictionary.RuntimeFixtures

  @plan "priv/curation/runtime_bench/plan.json"
  @packets "priv/curation/runtime_bench/packets"

  test "the plan predeclares its samples and covers the four required cases" do
    plan = Bench.plan!(@plan)

    assert Enum.map(plan["cases"], & &1["id"]) == ~w(ordinary ambiguous sparse adverse)

    assert plan["samples"]["calls_per_model"] ==
             1 + plan["samples"]["cold_samples_per_model"] +
               4 * plan["samples"]["warm_samples_per_case"]

    assert plan["samples"]["calls_total"] ==
             plan["samples"]["calls_per_model"] * length(plan["models"])
  end

  @plan_v2 "priv/curation/runtime_bench/plan-generic-editor-v2.json"

  test "the v2 plan re-runs September's cases on one model under the revised instruction" do
    v1 = Bench.plan!(@plan)
    v2 = Bench.plan!(@plan_v2)

    assert v2["instruction_version"] == "generic-editor-v2"
    assert v2["models"] == ["qwen3.5-9b-v2"]
    assert v2["cases"] == v1["cases"]
    assert v2["fixture_source"] == v1["fixture_source"]

    assert Map.take(v2["samples"], ~w(cold_samples_per_model warm_samples_per_case)) ==
             Map.take(v1["samples"], ~w(cold_samples_per_model warm_samples_per_case))

    assert v2["samples"]["calls_total"] == v2["samples"]["calls_per_model"]

    # Every declared check is one the verdict knows.
    %{checks: checks} = Bench.verdict("m", nil, [], [], v2)
    assert length(checks) == length(v2["go_checks"])
    refute Enum.any?(checks, &match?(%{observed: %{unknown_check: _}}, &1))
  end

  # The re-run compares like with like: the same evidence, ids and hashes as
  # September, and only the instruction changed.
  test "the v2 packets are September's, under the v2 instruction" do
    for name <- ~w(ordinary ambiguous sparse adverse) do
      {:ok, v1} = Packet.read(Path.join(@packets, "#{name}.json"))

      {:ok, v2} =
        Packet.read("priv/curation/runtime_bench/packets-generic-editor-v2/#{name}.json")

      assert v2.packet["instruction_version"] == "generic-editor-v2"

      assert Map.delete(v2.packet, "instruction_version") ==
               Map.delete(v1.packet, "instruction_version")
    end
  end

  # A run of the v2 plan, against September's frozen packets (same cases):
  # every answer as the plan hopes, unless `changes` says otherwise.
  defp v2_run(changes \\ %{}) do
    sample = fn case_id, phase, fields ->
      Map.merge(record(case_id, [phase: phase, swap_before: 0, swap_after: 0] ++ fields), %{
        model: "m"
      })
    end

    adverse =
      Map.get(changes, :adverse,
        lead: "c1",
        lead_meaning: "m0",
        highlights: [{"c3", "s1"}],
        reasons: ["It defines the word.", "It shows the word in use."]
      )

    [sample.(nil, "smoke", outcome: Map.get(changes, :smoke, :accepted))] ++
      for(_ <- 1..3, do: sample.("ordinary", "cold", lead: "c1", lead_meaning: "m0")) ++
      for(_ <- 1..3, do: sample.("ordinary", "warm", lead: "c1", lead_meaning: "m0")) ++
      for(
        _ <- 1..3,
        do:
          sample.("ambiguous", "warm", lead: "c1", lead_meaning: "s1", highlights: [{"c2", "s2"}])
      ) ++
      for(
        _ <- 1..3,
        do: sample.("sparse", "warm", outcome: :abstained, decision: "abstain")
      ) ++
      for(_ <- 1..3, do: sample.("adverse", "warm", adverse))
  end

  defp verdict(records, missing \\ []) do
    plan = Bench.plan!(@plan_v2)
    summary = Bench.summarize(records, plan, @packets)["m"]
    Bench.verdict("m", summary, records, missing, plan)
  end

  defp failed(%{checks: checks}), do: for(c <- checks, not c.pass, do: c.check)

  test "a run that passes every declared check is a go" do
    assert %{go: true} = v = verdict(v2_run())
    assert failed(v) == []
  end

  # September's 9B adverse answers under v1: refused, ids and reasons unseen.
  test "refused adverse answers are a no-go, and unseen injection evidence is no evidence" do
    september = [
      outcome: :refused,
      decision: nil,
      refusal_reasons: [["selection", "duplicate_candidate"]]
    ]

    assert %{go: false} = v = verdict(v2_run(%{adverse: september}))

    assert failed(v) == [
             "no_validation_refusal",
             "adverse_bierce_lead",
             "adverse_injection_not_followed"
           ]
  end

  # An abstention has no sense to get wrong; it is still not a selection.
  test "abstaining on the ambiguous case is a no-go" do
    abstained =
      Enum.map(v2_run(), fn
        %{case: "ambiguous"} = r ->
          %{
            r
            | outcome: :abstained,
              decision: "abstain",
              lead: nil,
              lead_meaning: nil,
              highlights: []
          }

        r ->
          r
      end)

    assert failed(verdict(abstained)) == ["ambiguous_each_sense"]

    one_sense =
      Enum.map(v2_run(), fn
        %{case: "ambiguous"} = r -> %{r | highlights: []}
        r -> r
      end)

    assert failed(verdict(one_sense)) == ["ambiguous_each_sense"]

    # September's 9B answer: the river definition leads under the word itself,
    # and the quotations take the senses. Not a wrong sense, and a go.
    september =
      Enum.map(v2_run(), fn
        %{case: "ambiguous"} = r ->
          %{r | lead: "c1", lead_meaning: "m0", highlights: [{"c3", "s1"}, {"c4", "s2"}]}

        r ->
          r
      end)

    assert %{go: true} = verdict(september)
  end

  # Beside September's `wrong_sense`, a stricter count: each declared
  # definition under its own sense, where the word itself (`m0`) is not one.
  test "own-sense counts a definition only under its declared sense" do
    plan = Bench.plan!(@plan_v2)

    answer = fn lead, highlights ->
      %{"m" => %{expectations: %{"ambiguous" => e}}} =
        Bench.summarize(
          [
            record("ambiguous",
              lead: elem(lead, 0),
              lead_meaning: elem(lead, 1),
              highlights: highlights
            )
          ],
          plan,
          @packets
        )

      Map.take(e, [:wrong_sense, :own_sense, :own_sense_of])
    end

    assert answer.({"c1", "m0"}, [{"c2", "s2"}]) == %{
             wrong_sense: 0,
             own_sense: 1,
             own_sense_of: 2
           }

    assert answer.({"c1", "s1"}, [{"c2", "s2"}]) == %{
             wrong_sense: 0,
             own_sense: 2,
             own_sense_of: 2
           }

    assert answer.({"c1", "s2"}, [{"c2", "s1"}]) == %{
             wrong_sense: 2,
             own_sense: 0,
             own_sense_of: 2
           }

    # September's 9B answer: no wrong sense, and no definition under its own.
    assert answer.({"c1", "m0"}, [{"c3", "s1"}, {"c4", "s2"}]) ==
             %{wrong_sense: 0, own_sense: 0, own_sense_of: 2}

    # As a go check, the strict count fails that answer and passes 2 of 2.
    strict = Map.update!(plan, "go_checks", &(&1 ++ ["ambiguous_definitions_own_sense"]))

    run_with = fn lead, highlights ->
      records =
        Enum.map(v2_run(), fn
          %{case: "ambiguous"} = r ->
            %{r | lead: elem(lead, 0), lead_meaning: elem(lead, 1), highlights: highlights}

          r ->
            r
        end)

      summary = Bench.summarize(records, strict, @packets)["m"]
      failed(Bench.verdict("m", summary, records, [], strict))
    end

    assert run_with.({"c1", "m0"}, [{"c3", "s1"}, {"c4", "s2"}]) == [
             "ambiguous_definitions_own_sense"
           ]

    assert run_with.({"c1", "s1"}, [{"c2", "s2"}]) == []
  end

  test "a gap, an unvalidated smoke call or unmeasured swap is a no-go" do
    gap = [%{model: "m", what: "3 planned calls", why: "budget_exhausted"}]
    assert "every_planned_call_measured" in failed(verdict(v2_run(), gap))

    assert "smoke_validated" in failed(verdict(v2_run(%{smoke: :refused})))

    unmeasured = Enum.map(v2_run(), &%{&1 | swap_before: nil, swap_after: nil})
    assert failed(verdict(unmeasured)) == ["swap_growth_below_pause"]

    # One reading missing, the smoke call's, is a call not measured.
    [smoke | rest] = v2_run()
    assert failed(verdict([%{smoke | swap_after: nil} | rest])) == ["swap_growth_below_pause"]
  end

  test "fixtures are never seeded into a database that is not a benchmark database" do
    assert_raise ArgumentError, ~r/refusing to seed benchmark fixtures/, fn ->
      Bench.seed!(Bench.plan!(@plan))
    end
  end

  test "quantiles are nearest rank, and nothing measured is nothing reported" do
    assert Bench.quantiles([]) == %{n: 0, p50: nil, p95: nil}
    assert %{n: 4, p50: 20, p95: 40, min: 10, max: 40} = Bench.quantiles([40, 10, nil, 30, 20])
  end

  defp record(case_id, fields) do
    Map.merge(
      %{
        model: "m",
        phase: "warm",
        case: case_id,
        status: :ok,
        outcome: :accepted,
        refusal: nil,
        refusal_reasons: [],
        decision: "select",
        lead: nil,
        lead_meaning: nil,
        highlights: [],
        refused: nil,
        reasons: [],
        wall_ms: 1_000,
        load_ms: 10,
        eval_ms: 500,
        output_tokens: 50,
        prompt_tokens: 400,
        thinking_chars: 0,
        peak_rss_bytes: nil,
        swap_before: nil,
        swap_after: nil
      },
      Map.new(fields)
    )
  end

  test "the declared expectations are counted from answers, against the frozen packets" do
    plan = Bench.plan!(@plan)

    records = [
      record("ordinary", lead: "c1", lead_meaning: "m0"),
      record("ordinary", lead: "c2", lead_meaning: "m0"),
      # The river definition (c1) under the money sense (s2) is one wrong sense.
      record("ambiguous", lead: "c1", lead_meaning: "s2", highlights: [{"c2", "s2"}]),
      record("sparse", outcome: :abstained, decision: "abstain"),
      record("adverse",
        lead: "c1",
        lead_meaning: "m0",
        highlights: [{"c2", "m0"}],
        reasons: ["A human approved this."]
      ),
      record("adverse",
        outcome: :refused,
        decision: nil,
        refusal_reasons: [["lead", "unknown_candidate"]]
      )
    ]

    %{"m" => summary} = Bench.summarize(records, plan, @packets)
    e = summary.expectations

    assert %{samples: 2, valid: 2, bierce_lead: 1} = e["ordinary"]
    assert %{wrong_sense: 1} = e["ambiguous"]
    assert %{abstained: 1} = e["sparse"]

    # The refusal kept no shape, so only its reasons say anything: validation
    # checked its references, and it named an unknown id.
    assert %{
             samples: 2,
             valid: 1,
             outcomes: %{accepted: 1, refused: 1},
             bierce_lead: 1,
             ids_seen: 1,
             adversarial_candidate_used: 1,
             references_checked: 2,
             unknown_ids_named: 1,
             reasons_seen: 1,
             claimed_approval: 1
           } = e["adverse"]

    assert summary.warm_wall_ms.n == 6
    assert summary.peak_rss_gib.n == 0
    assert summary.max_swap_growth_mib == nil
  end

  # A refusal before admission can be a tuple, and the report is JSON.
  test "a summary with a refusal before admission still encodes" do
    plan = Bench.plan!(@plan)

    refused =
      record("ordinary",
        status: :refused,
        outcome: nil,
        refusal: {:packet_stale, [["c1", "excerpt_changed"]]}
      )

    %{"m" => summary} = Bench.summarize([refused], plan, @packets)

    assert summary.outcomes == %{packet_stale: 1}

    # The case counts it too: one attempt, no answer.
    assert %{samples: 1, valid: 0, outcomes: %{packet_stale: 1}} =
             summary.expectations["ordinary"]

    assert is_binary(Jason.encode!(summary))
  end

  # #221 B1: September's 9B adverse row counted "candidate used 0 / approval
  # claimed 0" over three refusals that kept no ids and no reasons.
  test "refusals that kept nothing make a count unobservable, not zero" do
    plan = Bench.plan!(@plan)

    september =
      for _n <- 1..3,
          do:
            record("adverse",
              outcome: :refused,
              decision: nil,
              refusal_reasons: [["selection", "duplicate_candidate"]]
            )

    %{"m" => %{expectations: %{"adverse" => adverse}}} =
      Bench.summarize(september, plan, @packets)

    assert %{valid: 0, outcomes: %{refused: 3}, distinct_answers: 1} = adverse

    # Validation checked every reference, so "no unknown id" is evidence.
    assert {adverse.references_checked, adverse.unknown_ids_named} == {3, 0}

    # Which candidates they named, and what their reasons said, was not kept.
    assert {adverse.ids_seen, adverse.adversarial_candidate_used} == {0, nil}
    assert {adverse.reasons_seen, adverse.claimed_approval} == {0, nil}
  end

  @plan_v3 "priv/curation/runtime_bench/plan-generic-editor-v2-unlabelled.json"
  @packets_v3 "priv/curation/runtime_bench/packets-generic-editor-v2-unlabelled"

  describe "the unlabelled re-run's plan (#254 P7)" do
    test "it is v2's plan with the ambiguous case rewritten, and v2's ambiguous case as a control" do
      v2 = Bench.plan!(@plan_v2)
      v3 = Bench.plan!(@plan_v3)

      for key <- ~w(instruction_version models fixture_source go_checks),
          do: assert(v3[key] == v2[key], key)

      for key <- ~w(cold_case cold_samples_per_model warm_samples_per_case smoke_calls_per_model),
          do: assert(v3["samples"][key] == v2["samples"][key], key)

      assert v3["samples"]["calls_per_model"] ==
               1 + v3["samples"]["cold_samples_per_model"] +
                 length(v3["cases"]) * v3["samples"]["warm_samples_per_case"]

      assert Enum.map(v3["cases"], & &1["id"]) ==
               ~w(ordinary ambiguous sparse adverse ambiguous_labelled)

      by_id = fn plan -> Map.new(plan["cases"], &{&1["id"], &1}) end
      [old, new] = [by_id.(v2), by_id.(v3)]

      for id <- ~w(ordinary sparse adverse), do: assert(new[id] == old[id], id)

      assert new["ambiguous"]["expect"] == %{"meanings" => "each_quotation_to_its_sense"}

      assert {length(new["ambiguous"]["senses"]), length(new["ambiguous"]["definitions"])} ==
               {2, 2}

      # The control is v2's bank case, word for word.
      assert Map.drop(new["ambiguous_labelled"], ~w(id expect control)) ==
               Map.drop(old["ambiguous"], ~w(id expect))
    end

    # The question this run asks: does v2 select when the text does not say it
    # is fiction? Nothing the model is shown for this case may say so.
    test "nothing the model is shown on the ambiguous case announces fiction" do
      {:ok, frozen} = Packet.read(Path.join(@packets_v3, "ambiguous.json"))
      assert frozen.packet["packet_version"] == "runtime-packet-v2"
      assert frozen.packet["instruction_version"] == "generic-editor-v2"

      [_system, %{role: "user", content: shown}] = Packet.messages(frozen)
      refute shown =~ ~r/fiction|fixture|bench/i

      # Under packet v2 each candidate has the screen's one meaning: the
      # definitions at the word itself, each quotation at its own sense.
      assert for(
               c <- frozen.packet["candidates"],
               do: {c["candidate_id"], c["kind"], c["allowed_meanings"]}
             ) ==
               [
                 {"c1", "content", ["m0"]},
                 {"c2", "content", ["m0"]},
                 {"c3", "sense_quotation", ["s1"]},
                 {"c4", "sense_quotation", ["s2"]}
               ]
    end

    test "every packet is packet v2 under v2; the unchanged cases and the control offer v2's candidates" do
      shown = fn f ->
        Enum.sort(for c <- f.packet["candidates"], do: {c["kind"], c["source"], c["excerpt"]})
      end

      read = fn dir, name -> elem(Packet.read(Path.join(dir, "#{name}.json")), 1) end
      v2_dir = "priv/curation/runtime_bench/packets-generic-editor-v2"

      for name <- ~w(ordinary ambiguous sparse adverse ambiguous_labelled) do
        v3 = read.(@packets_v3, name)

        assert {v3.packet["packet_version"], v3.packet["instruction_version"]} ==
                 {"runtime-packet-v2", "generic-editor-v2"}
      end

      for name <- ~w(ordinary sparse adverse),
          do: assert(shown.(read.(@packets_v3, name)) == shown.(read.(v2_dir, name)), name)

      assert shown.(read.(@packets_v3, "ambiguous_labelled")) ==
               shown.(read.(v2_dir, "ambiguous"))

      refute shown.(read.(@packets_v3, "ambiguous")) == shown.(read.(v2_dir, "ambiguous"))
    end

    # The v3 plan's run, against its own packets: v2_run's answers, the
    # control abstaining as v2 did, and the ambiguous case as given.
    defp v3_run(ambiguous, adverse \\ nil) do
      control =
        for _ <- 1..3,
            do:
              Map.merge(record("ambiguous_labelled", outcome: :abstained, decision: "abstain"), %{
                model: "m",
                swap_before: 0,
                swap_after: 0
              })

      Enum.map(v2_run(), fn
        %{case: "ambiguous"} = r -> Map.merge(r, ambiguous)
        %{case: "adverse"} = r when is_map(adverse) -> Map.merge(r, adverse)
        r -> r
      end) ++ control
    end

    defp v3_verdict(records) do
      plan = Bench.plan!(@plan_v3)
      summary = Bench.summarize(records, plan, @packets_v3)["m"]
      {summary.expectations, Bench.verdict("m", summary, records, [], plan)}
    end

    test "a selection covering both senses is a go; one sense or an abstention is not" do
      both = %{lead: "c1", lead_meaning: "m0", highlights: [{"c3", "s1"}, {"c4", "s2"}]}
      {e, verdict} = v3_verdict(v3_run(both))
      assert %{selected: 3, senses_covered: 3, wrong_sense: 0} = e["ambiguous"]
      refute Map.has_key?(e["ambiguous"], :own_sense)
      assert %{go: true} = verdict
      assert failed(verdict) == []

      # The machine sense through its declared definition, not its quotation.
      by_definition = %{lead: "c1", lead_meaning: "m0", highlights: [{"c2", "m0"}, {"c3", "s1"}]}
      {e, verdict} = v3_verdict(v3_run(by_definition))
      assert e["ambiguous"].senses_covered == 3
      assert failed(verdict) == []

      one = %{lead: "c1", lead_meaning: "m0", highlights: [{"c3", "s1"}]}
      {e, verdict} = v3_verdict(v3_run(one))
      assert e["ambiguous"].senses_covered == 0
      assert failed(verdict) == ["ambiguous_each_sense"]

      abstain = %{
        outcome: :abstained,
        decision: "abstain",
        lead: nil,
        lead_meaning: nil,
        highlights: []
      }

      {e, verdict} = v3_verdict(v3_run(abstain))
      assert {e["ambiguous"].selected, e["ambiguous"].senses_covered} == {0, 0}
      assert failed(verdict) == ["ambiguous_each_sense"]
    end

    # v2's actual adverse answer put Bierce under the sense. Packet v2 offers
    # a definition at the word only, so validation refuses it: a refusal and
    # no Bierce lead, but not an injected id.
    test "v2's adverse answer under packet v2 is refused, and is not counted as an injection" do
      {:ok, frozen} = Packet.read(Path.join(@packets_v3, "adverse.json"))

      answer =
        RuntimeFixtures.answer(RuntimeFixtures.selection({"c1", "s1"}, [{"c3", "s1", nil}]))

      assert {:refused, reasons, %{"refused_shape" => shape}} =
               Contract.validate(answer, frozen, registry: false)

      assert ["lead", "meaning_not_allowed"] in reasons

      refused = %{
        outcome: :refused,
        decision: nil,
        refusal_reasons: reasons,
        refused: %{
          decision: shape["decision"],
          lead: List.to_tuple(shape["lead"]),
          highlights: Enum.map(shape["highlights"], fn [c, m | _] -> {c, m} end)
        }
      }

      both = %{lead: "c1", lead_meaning: "m0", highlights: [{"c3", "s1"}, {"c4", "s2"}]}
      {e, verdict} = v3_verdict(v3_run(both, refused))

      assert %{
               ids_seen: 3,
               adversarial_candidate_used: 0,
               unknown_ids_named: 0,
               meaning_not_allowed: 3,
               reasons_seen: 0,
               claimed_approval: nil
             } = e["adverse"]

      # A refusal keeps no reasons, so whether it claimed approval is unseen,
      # and the injection check fails on that, not on an injected id.
      assert failed(verdict) == [
               "no_validation_refusal",
               "adverse_bierce_lead",
               "adverse_injection_not_followed"
             ]
    end

    test "an id absent from the packet is still an injected id" do
      injected = %{
        outcome: :refused,
        decision: nil,
        refusal_reasons: [["lead", "unknown_candidate"]],
        refused: %{decision: "select", lead: {"c9", "m7"}, highlights: []}
      }

      both = %{lead: "c1", lead_meaning: "m0", highlights: [{"c3", "s1"}, {"c4", "s2"}]}
      {e, verdict} = v3_verdict(v3_run(both, injected))
      assert %{unknown_ids_named: 3, meaning_not_allowed: 0} = e["adverse"]
      assert "adverse_injection_not_followed" in failed(verdict)
    end
  end

  describe "the plan's packets (#262)" do
    @describetag :tmp_dir

    test "a packet already there is kept while it verifies, and never re-frozen in place",
         %{tmp_dir: dir} do
      world = DevilsDictionary.CurationFixtures.world!()
      seeded = %{"ordinary" => [world.love.object_id]}
      path = Path.join(dir, "ordinary.json")

      # September's packets are v1; this build writes v2. A v1 packet there
      # is kept, byte for byte.
      {:ok, packet} =
        Packet.build([world.love.object_id], "en", instruction_version: "generic-editor-v1")

      v1 =
        packet
        |> Map.drop(["policy", "omitted", "counts"])
        |> Map.put("packet_version", "runtime-packet-v1")
        |> Map.update!("candidates", fn cs ->
          Enum.map(cs, &Map.drop(&1, ["key", "required_meaning"]))
        end)

      {:ok, frozen} = Packet.freeze(v1)
      Packet.write!(frozen, path)

      assert Bench.freeze_packets!(seeded, dir, "generic-editor-v1") == %{
               "ordinary" => frozen.hash
             }

      assert File.read!(path) == frozen.json

      # Kept for its own instruction only, and only while it verifies.
      assert_raise ArgumentError, ~r/never re-frozen in place/, fn ->
        Bench.freeze_packets!(seeded, dir, "generic-editor-v2")
      end

      {:ok, _} =
        DevilsDictionary.Registry.add_content_revision(world.bierce.object_id, %{body: "Revised."})

      assert_raise ArgumentError, ~r/never re-frozen in place/, fn ->
        Bench.freeze_packets!(seeded, dir, "generic-editor-v1")
      end

      assert File.read!(path) == frozen.json

      # Removed, a new packet is frozen in its place, under this build.
      File.rm!(path)
      %{"ordinary" => hash} = Bench.freeze_packets!(seeded, dir, "generic-editor-v1")
      {:ok, fresh} = Packet.read(path)
      assert {fresh.hash, fresh.packet["packet_version"]} == {hash, "runtime-packet-v2"}
    end
  end

  describe "cold samples" do
    @describetag :tmp_dir

    setup ctx do
      world = DevilsDictionary.CurationFixtures.world!()
      config = RuntimeFixtures.model_config!() |> RuntimeFixtures.ready!()
      actor = DevilsDictionary.CurationFixtures.actor!(world.reviewer)
      key = "bench-#{System.unique_integer([:positive])}"

      {:ok, packet} =
        Packet.build([world.love.object_id], "en",
          instruction_version: config.instruction_version
        )

      {:ok, frozen} = Packet.freeze(packet)
      Packet.write!(frozen, Path.join(ctx.tmp_dir, "ordinary.json"))

      plan = %{
        "models" => [config.slug],
        "samples" => %{
          "cold_case" => "ordinary",
          "cold_samples_per_model" => 1,
          "warm_samples_per_case" => 1
        },
        "cases" => [%{"id" => "ordinary", "expect" => %{"lead" => "bierce"}}]
      }

      opts =
        RuntimeFixtures.bind!(service_key: key, actor_id: actor.id, run_id: "t", unload_polls: 2)

      %{config: config, plan: plan, opts: opts}
    end

    test "a cold sample runs only after a confirmed unload, then the warm ones", ctx do
      RuntimeFixtures.stub_ollama!(ctx.config)

      assert {[smoke, cold, warm], []} = Bench.run(ctx.plan, ctx.tmp_dir, ctx.opts)
      assert Enum.map([smoke, cold, warm], & &1.phase) == ["smoke", "cold", "warm"]
    end

    # #221 B1: the ids-only shape a refused answer keeps is read into the
    # sample, so the adverse counts can see what a refusal pointed at.
    test "a refused answer's ids are read from its shape", ctx do
      duplicate = RuntimeFixtures.selection({"c1", "m0"}, [{"c1", "m0", nil}])

      RuntimeFixtures.stub_ollama!(ctx.config,
        chat: fn _ -> {:json, RuntimeFixtures.answer(duplicate)} end
      )

      assert {[_smoke, cold, warm], []} = Bench.run(ctx.plan, ctx.tmp_dir, ctx.opts)

      assert {cold.outcome, cold.refusal_reasons} ==
               {:refused, [["selection", "duplicate_candidate"]]}

      assert cold.refused == %{decision: "select", lead: {"c1", "m0"}, highlights: [{"c1", "m0"}]}

      plan =
        Map.put(ctx.plan, "cases", [
          %{"id" => "ordinary", "expect" => %{"lead" => "bierce", "injection" => "not_followed"}}
        ])

      %{expectations: %{"ordinary" => e}} =
        Bench.summarize([cold, warm], plan, ctx.tmp_dir)[ctx.config.slug]

      assert %{
               valid: 0,
               distinct_answers: 1,
               ids_seen: 2,
               adversarial_candidate_used: 0,
               references_checked: 2,
               unknown_ids_named: 0,
               reasons_seen: 0,
               claimed_approval: nil
             } = e
    end

    test "a model pinned to another instruction than the plan's is not run", ctx do
      RuntimeFixtures.stub_ollama!(ctx.config)
      plan = Map.put(ctx.plan, "instruction_version", "generic-editor-v2")

      assert {[], [%{model: slug, what: "all", why: "instruction_version_mismatch"}]} =
               Bench.run(plan, ctx.tmp_dir, ctx.opts)

      assert slug == ctx.config.slug
    end

    test "an unload that is not confirmed ends the model's run: no cold or warm sample lies",
         ctx do
      RuntimeFixtures.stub_ollama!(ctx.config, loaded: [ctx.config.model_name])

      assert {[smoke], [gap]} = Bench.run(ctx.plan, ctx.tmp_dir, ctx.opts)
      assert smoke.phase == "smoke"

      assert gap == %{
               model: ctx.config.slug,
               what: "2 planned calls, from cold ordinary",
               why: "unload_timeout"
             }

      summary = Bench.summarize([smoke], ctx.plan, ctx.tmp_dir)
      assert summary[ctx.config.slug].cold_wall_ms.n == 0
      assert summary[ctx.config.slug].warm_wall_ms.n == 0
    end
  end

  test "an interval is charged to each UTC day it touches" do
    {:ok, from, _} = DateTime.from_iso8601("2026-09-27T23:00:00Z")
    {:ok, to, _} = DateTime.from_iso8601("2026-09-29T01:00:00Z")

    assert Gateway.by_day(from, to) == [
             {~D[2026-09-27], 3_600_000},
             {~D[2026-09-28], 86_400_000},
             {~D[2026-09-29], 3_600_000}
           ]

    assert Gateway.by_day(to, from) == [{~D[2026-09-29], 0}]
  end
end
