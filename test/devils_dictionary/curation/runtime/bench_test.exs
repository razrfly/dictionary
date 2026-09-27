defmodule DevilsDictionary.Curation.Runtime.BenchTest do
  @moduledoc """
  The benchmark harness's own rules: fixtures go only into a `*_bench`
  database, the plan's counts are predeclared, and summaries report
  quantiles by nearest rank, leaving missing measurements missing.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Curation.Runtime.{Bench, Gateway}

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
