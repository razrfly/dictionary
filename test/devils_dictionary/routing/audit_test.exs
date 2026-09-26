defmodule DevilsDictionary.Routing.AuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    directory =
      Path.join(System.tmp_dir!(), "routing-audit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "same-name local works are held for collision review, never merged", %{directory: dir} do
    summary = run(dir, [work(1, "Love"), work(2, "Love"), work(3, "Different")])
    assert summary["entities"] == 3
    assert summary["collision_groups"] == 1
    assert summary["colliding_entities"] == 2
    assert summary["address_status"] == %{"candidate" => 1, "collision_review" => 2}
    assert summary["publication_approved"] == 0
    assert summary["allocated_paths"] == 0
  end

  test "shuffled input and repeat runs preserve the complete manifest", %{directory: dir} do
    rows = [work(1, "Love"), work(2, "Love"), work(3, "C++")]
    run(dir, rows)
    first = File.read!(Path.join(dir, "output/assignments.jsonl"))
    run(dir, Enum.reverse(rows))
    assert File.read!(Path.join(dir, "output/assignments.jsonl")) == first
    run(dir, rows)
    assert File.read!(Path.join(dir, "output/assignments.jsonl")) == first
  end

  test "duplicate object identities reject the snapshot", %{directory: dir} do
    assert_raise Mix.Error, ~r/duplicate entity identity/, fn ->
      run(dir, [work(1, "First"), work(1, "Second")])
    end
  end

  test "missing snapshot attestation rejects rather than reporting success", %{directory: dir} do
    input = Path.join(dir, "input.jsonl")
    File.write!(input, Jason.encode!(work(1, "Love")) <> "\n")

    assert_raise Mix.Error, ~r/incomplete or non-read-only/, fn ->
      Mix.Tasks.Dd.Routing.Audit.run(["--input", input, "--output", Path.join(dir, "output")])
    end
  end

  test "duplicate population or snapshot records cannot become order-dependent evidence", %{
    directory: dir
  } do
    for row <- [
          %{"record_type" => "snapshot", "read_only" => "on"},
          %{"record_type" => "lexical_population", "count" => 10}
        ] do
      assert_raise Mix.Error, ~r/duplicate/, fn -> run(dir, [work(1, "Love"), row]) end
    end
  end

  defp run(dir, entities) do
    rows =
      [
        %{"record_type" => "snapshot", "read_only" => "on"},
        %{"record_type" => "lexical_population", "count" => 1}
      ] ++ entities

    input = Path.join(dir, "input.jsonl")
    output = Path.join(dir, "output")
    File.write!(input, Enum.map(rows, &[Jason.encode!(&1), "\n"]))
    capture_io(fn -> Mix.Tasks.Dd.Routing.Audit.run(["--input", input, "--output", output]) end)
    output |> Path.join("summary.json") |> File.read!() |> Jason.decode!()
  end

  defp work(id, label) do
    %{
      "record_type" => "entity",
      "object_id" => id,
      "label" => label,
      "entity_kind" => "work",
      "work_kind" => "poem",
      "lifecycle" => "active",
      "qids" => [],
      "instance_of" => [],
      "subclass_of" => []
    }
  end
end
