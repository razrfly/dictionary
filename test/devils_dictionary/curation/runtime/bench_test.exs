defmodule DevilsDictionary.Curation.Runtime.BenchTest do
  @moduledoc """
  The benchmark harness's own rules: fixtures go only into a `*_bench`
  database, the plan's counts are predeclared, and summaries report
  quantiles by nearest rank, leaving missing measurements missing.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Curation.Runtime.{Bench, Gateway, Packet}
  alias DevilsDictionary.RuntimeFixtures

  @plan "priv/curation/runtime_bench/plan.json"

  test "the plan predeclares its samples and covers the four required cases" do
    plan = Bench.plan!(@plan)

    assert Enum.map(plan["cases"], & &1["id"]) == ~w(ordinary ambiguous sparse adverse)

    assert plan["samples"]["calls_per_model"] ==
             1 + plan["samples"]["cold_samples_per_model"] +
               4 * plan["samples"]["warm_samples_per_case"]

    assert plan["samples"]["calls_total"] ==
             plan["samples"]["calls_per_model"] * length(plan["models"])
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

  @packets "priv/curation/runtime_bench/packets"

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

  describe "cold samples" do
    @describetag :tmp_dir

    setup ctx do
      world = DevilsDictionary.CurationFixtures.world!()
      config = RuntimeFixtures.model_config!() |> RuntimeFixtures.ready!()
      actor = DevilsDictionary.CurationFixtures.actor!(world.reviewer)
      key = "bench-#{System.unique_integer([:positive])}"

      {:ok, packet} = Packet.build([world.love.object_id], "en")
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
