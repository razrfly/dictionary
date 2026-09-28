defmodule DevilsDictionary.Routing.PolicyDependenciesPropertyTest do
  @moduledoc """
  `Policy.classify/3`'s `dependencies` are the whole of what its result
  depends on (#219 A1; the property A6 of #219 used to probe it): mutate,
  add or remove every graph record that is **not** a dependency, and the
  result — outcome, evidence and fingerprint — is exactly the same. Pure and
  seeded, so a failure reproduces.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{Classifications, Policy}

  @iterations 3_000

  setup_all do
    policy = Policy.load()
    rules = policy.rules

    anchors =
      Enum.flat_map(rules["instance_rules"], & &1["instance_anchors"]) ++
        Map.keys(rules["class_anchors"]) ++
        Map.keys(rules["self_rules"]) ++ rules["source_page_anchors"]

    synthetic = for n <- 1..30, do: "Q98#{String.pad_leading(Integer.to_string(n), 4, "0")}"
    %{policy: policy, pool: Enum.uniq(anchors ++ synthetic)}
  end

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp chance(p), do: :rand.uniform() < p

  defp claim(pool) do
    rank = pick(["normal", "normal", "normal", "preferred", "deprecated"])
    base = %{"rank" => rank, "mainsnak" => %{"datavalue" => %{"value" => %{"id" => pick(pool)}}}}
    if chance(0.08), do: Map.put(base, "qualifiers", %{"P580" => [%{}]}), else: base
  end

  defp claims(pool, max), do: for(_ <- 1..:rand.uniform(max + 1), chance(0.7), do: claim(pool))

  defp record(qid, pool) do
    %{
      "qid" => qid,
      "revision_id" => :rand.uniform(1_000_000),
      "checksum" => if(chance(0.05), do: nil, else: Integer.to_string(:rand.uniform(1_000_000))),
      "claims" => %{"P31" => claims(pool, 2), "P279" => claims(pool, 3)}
    }
  end

  defp graph(pool, extra),
    do: for(qid <- pool ++ extra, chance(0.65), into: %{}, do: {qid, record(qid, pool)})

  defp entity(pool) do
    qids =
      cond do
        chance(0.15) -> []
        chance(0.1) -> Enum.sort(Enum.uniq([pick(pool), pick(pool)]))
        true -> [pick(pool)]
      end

    %{
      "object_id" => :rand.uniform(1000),
      "label" => "x",
      "entity_kind" => pick(~w(person place concept work edition organization)),
      "lifecycle" => if(chance(0.05), do: "merged", else: "active"),
      "disambiguation" => chance(0.05),
      "instance_of" => for(_ <- 1..3, chance(0.4), do: pick(pool)) |> Enum.uniq() |> Enum.sort(),
      "subclass_of" => for(_ <- 1..2, chance(0.2), do: pick(pool)) |> Enum.uniq() |> Enum.sort(),
      "work_kind" => pick([nil, "album", "novel"]),
      "edition_work_id" => pick([nil, 7]),
      "qids" => qids
    }
  end

  defp mutate(graph, deps, pool, extra) do
    Enum.reduce(pool ++ extra, graph, fn qid, acc ->
      cond do
        MapSet.member?(deps, qid) -> acc
        chance(0.3) -> Map.delete(acc, qid)
        chance(0.5) -> Map.put(acc, qid, record(qid, pool))
        true -> acc
      end
    end)
  end

  test "nothing outside the dependencies changes the result or its fingerprint", ctx do
    :rand.seed(:exsss, {219, 6, 1})
    extra = for n <- 1..10, do: "Q97#{n}"

    failures =
      for i <- 1..@iterations,
          g0 = graph(ctx.pool, extra),
          e = entity(ctx.pool),
          r0 = Policy.classify(e, g0, ctx.policy),
          deps = MapSet.new(r0.dependencies, & &1["qid"]),
          r1 = Policy.classify(e, mutate(g0, deps, ctx.pool, extra), ctx.policy),
          r0 != r1 or Classifications.fingerprint(r0) != Classifications.fingerprint(r1),
          do: {i, e}

    assert failures == []
  end
end
