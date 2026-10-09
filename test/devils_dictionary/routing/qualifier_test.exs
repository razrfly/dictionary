defmodule DevilsDictionary.Routing.QualifierTest do
  @moduledoc """
  `Routing.Qualifier` is `docs/routing/stage-2/candidates.py`'s qualifier
  proposal in Elixir. Held here to every proposal in #224's population —
  the 55 qualified paths the owner reviewed — from the export the population
  was derived from, and to each family's rule.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{AuditSnapshot, Qualifier}

  @dir Path.expand("../../fixtures/routing/cp4-224", __DIR__)
  @population Path.expand("../../../docs/routing/stage-2/candidates.json", __DIR__)

  test "every proposal in #224's population, generated from the export" do
    population = @population |> File.read!() |> Jason.decode!()
    {:ok, snapshot} = AuditSnapshot.read(Path.join(@dir, "export-subset.jsonl"))
    entities = Map.new(snapshot.entities, &{&1["object_id"], &1})
    records = Map.new(population["records"], &{&1["object_id"], &1})

    generated =
      for {_path, ids} <- population["groups"],
          members =
            for(
              id <- ids,
              r = records[id],
              r["status"] == "mapped",
              do: %{
                object_id: id,
                label: r["label"],
                family: r["family"],
                description: entities[id]["description"],
                work_kind: entities[id]["work_kind"]
              }
            ),
          {id, path} <- Qualifier.proposals(members),
          into: %{},
          do: {id, path}

    proposed = for r <- population["records"], r["proposed_path"], do: r

    assert length(proposed) == 55

    for r <- proposed do
      assert generated[r["object_id"]] == r["proposed_path"],
             "object #{r["object_id"]} #{r["label"]}: generated #{inspect(generated[r["object_id"]])}, proposed #{r["proposed_path"]}"
    end
  end

  test "each family's rule" do
    assert Qualifier.qualifier("works", "2024 film directed by Jo Smith", nil) ==
             {"2024 film", "Jo Smith"}

    assert Qualifier.qualifier("works", "studio album", nil) == {"album", nil}
    assert Qualifier.qualifier("works", "a thing", "poem") == {"poem", nil}
    assert Qualifier.qualifier("works", "a thing", nil) == {nil, nil}

    assert Qualifier.qualifier("people", "Irish jockey (1915–2001)", nil) ==
             {"Irish jockey", "1915"}

    assert Qualifier.qualifier("people", "English footballer and manager", nil) ==
             {"footballer manager", "English"}

    assert Qualifier.qualifier("places", "human settlement in Afghanistan", nil) ==
             {"Afghanistan", nil}

    assert Qualifier.qualifier("places", "village in the Vestnes Municipality, Norway", nil) ==
             {"Vestnes Municipality", nil}

    assert Qualifier.qualifier("places", "a mountain", nil) == {nil, nil}
    assert Qualifier.qualifier("places", "in , here", nil) == {nil, nil}

    assert Qualifier.qualifier("organizations", "Australian rock band", nil) ==
             {"Australian band", nil}

    assert Qualifier.qualifier("concepts", "the language", nil) == {"language", nil}
    assert Qualifier.qualifier("nature", "", nil) == {nil, nil}
    assert Qualifier.qualifier("nature", "   ", nil) == {nil, nil}
    assert Qualifier.qualifier("nature", nil, nil) == {nil, nil}
  end

  test "a group: the base qualifier where it is unique, the extra only where it is not" do
    member = fn id, desc ->
      %{object_id: id, label: "Billy Lee", family: "people", description: desc, work_kind: nil}
    end

    assert Qualifier.proposals([
             member.(1, "Irish jockey"),
             member.(2, "American actor (1929–1989)"),
             member.(3, "American actor (1950–2020)"),
             member.(4, "British actor")
           ]) == %{
             1 => "/people/billy-lee-irish-jockey",
             2 => "/people/billy-lee-american-actor-1929",
             3 => "/people/billy-lee-american-actor-1950",
             4 => "/people/billy-lee-british-actor"
           }

    # No evidence, no proposal: nothing is invented.
    assert Qualifier.proposals([member.(1, ""), member.(2, "Irish jockey")]) ==
             %{1 => nil, 2 => "/people/billy-lee-irish-jockey"}
  end
end
