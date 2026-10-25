defmodule DevilsDictionary.Curation.RefreshConcurrencyTest do
  @moduledoc """
  Admission under real concurrency (#259 §6, tests 7 and 19), on committed
  connections. A sandbox wraps a test in one transaction on one connection,
  so two admissions there never contend for a lock. These tests are
  `:unboxed`: each task checks out its own connection, rows really commit,
  and the advisory lock, the row lock and the partial unique index are the
  ones under test. Tasks wait at a gate the test opens; the order is fixed
  by messages, never by sleeping.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{Refresh, RefreshState}
  alias DevilsDictionary.Repo

  @moduletag :unboxed

  setup ctx do
    world = love_world!(ctx)
    composition = provision!(world)
    published = publish!(world, composition)
    Map.merge(world, %{composition: composition, published: published})
  end

  # A task on its own connection that runs `fun` when sent `{:go, gate}`.
  defp gated(gate, fun) do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})
      receive do: ({:go, ^gate} -> fun.())
    end)
  end

  defp open_gate(tasks, gate) do
    for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, {:go, gate})
  end

  defp admit(composition), do: Refresh.admit(composition.id, slug: "love")

  test "19: an absent row is initialised under the composition lock: a visit that cannot take it writes nothing",
       ctx do
    parent = self()
    id = ctx.composition.id

    # Another admission holds the composition's lock.
    holder =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [259, id])
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held
    assert {:ok, :busy} = admit(ctx.composition)
    assert Repo.aggregate(RefreshState, :count) == 0
    assert curation_jobs() == []

    send(holder.pid, :release)
    Task.await(holder)

    assert {:ok, :admitted} = admit(ctx.composition)
    assert Repo.aggregate(RefreshState, :count) == 1
    assert length(curation_jobs()) == 1
  end

  test "19: two first admissions racing on an absent row make one row, one job, one generation",
       ctx do
    tasks = for _ <- 1..2, do: gated(:first, fn -> admit(ctx.composition) end)
    open_gate(tasks, :first)
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == {:ok, :admitted})) == 1
    assert Enum.all?(results, &(&1 in [{:ok, :admitted}, {:ok, :busy}, {:ok, :in_flight}]))

    assert [%RefreshState{state: :queued, refresh_generation: 1}] = Repo.all(RefreshState)
    assert length(curation_jobs()) == 1
  end

  test "7: two admissions racing on an idle, due row queue one run", ctx do
    {:ok, :admitted} = admit(ctx.composition)
    drain!()
    ctx.composition |> row!() |> set!(refresh_after: ago(1))

    tasks = for _ <- 1..4, do: gated(:due, fn -> admit(ctx.composition) end)
    open_gate(tasks, :due)
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == {:ok, :admitted})) == 1
    assert Enum.all?(results, &(&1 in [{:ok, :admitted}, {:ok, :busy}, {:ok, :in_flight}]))
    assert %RefreshState{state: :queued, refresh_generation: 2} = row!(ctx.composition)
    assert length(curation_jobs()) == 2
  end
end
