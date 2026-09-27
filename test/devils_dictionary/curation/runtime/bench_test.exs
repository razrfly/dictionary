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

    assert %{
             samples: 2,
             valid: 1,
             bierce_lead: 1,
             adversarial_candidate_used: 1,
             unknown_ids_named: 1,
             claimed_approval: 1
           } = e["adverse"]

    assert summary.warm_wall_ms.n == 6
    assert summary.peak_rss_gib.n == 0
    assert summary.max_swap_growth_mib == nil
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
        "cases" => []
      }

      opts =
        RuntimeFixtures.bind!(service_key: key, actor_id: actor.id, run_id: "t", unload_polls: 2)

      %{config: config, plan: plan, opts: opts}
    end

    test "a cold sample runs only after a confirmed unload", ctx do
      RuntimeFixtures.stub_ollama!(ctx.config)

      assert {[smoke, cold], []} = Bench.run(ctx.plan, ctx.tmp_dir, ctx.opts)
      assert {smoke.phase, cold.phase, cold.status} == {"smoke", "cold", :ok}
    end

    test "an unload that is not confirmed skips the sample: a warm call is never cold", ctx do
      RuntimeFixtures.stub_ollama!(ctx.config, loaded: [ctx.config.model_name])

      assert {[smoke], [gap]} = Bench.run(ctx.plan, ctx.tmp_dir, ctx.opts)
      assert smoke.phase == "smoke"
      assert gap == %{model: ctx.config.slug, what: "cold ordinary call 2", why: "unload_timeout"}

      summary = Bench.summarize([smoke], ctx.plan, ctx.tmp_dir)
      assert summary[ctx.config.slug].cold_wall_ms.n == 0
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
