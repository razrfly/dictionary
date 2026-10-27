defmodule DevilsDictionary.Curation.Proposals.UnitsRaceTest do
  @moduledoc """
  #264 §8 test 12 (R5.2): two runs reserving the last review unit at once,
  on committed connections. A sandbox wraps a test in one transaction on one
  connection, where an advisory lock never contends; this test is
  `:unboxed`, so the lock that serializes reservations is the one under
  test. Tasks wait at a gate the test opens; the order is fixed by
  messages, never by sleeping.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{Compositions, Proposals, Refresh}
  alias DevilsDictionary.{Repo, WordFixtures}

  @moduletag :unboxed

  setup do
    previous = Application.get_env(:devils_dictionary, :curation_review_units)
    Application.put_env(:devils_dictionary, :curation_review_units, 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:devils_dictionary, :curation_review_units, previous),
        else: Application.delete_env(:devils_dictionary, :curation_review_units)
    end)

    world = love_world!()
    love = provision!(world)

    hope = WordFixtures.word!(world, "hope", ~w(wiktionary), scope: nil)

    {:ok, other} =
      Compositions.provision(world.author, world.configuration.id, %{
        scope_kind: :lexical_page,
        lexeme_ids: [hope.object_id],
        language_tag: "en",
        reason: "#264 race"
      })

    claims =
      for {composition, slug} <- [{love, "love"}, {other, "hope"}] do
        {:ok, :admitted} = Refresh.admit(composition.id, slug: slug)
        row = row!(composition)
        {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
        claim
      end

    %{claims: claims}
  end

  defp gated(gate, fun) do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})
      receive do: ({:go, ^gate} -> fun.())
    end)
  end

  test "12: two rows reserving the last unit at once: one wins", %{claims: claims} do
    tasks = for claim <- claims, do: gated(:reserve, fn -> Refresh.reserve(claim) end)
    for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, {:go, :reserve})
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &match?({:ok, _row}, &1)) == 1
    assert [{:deferred, deferred}] = Enum.filter(results, &match?({:deferred, _row}, &1))
    assert deferred.last_error == "review_capacity"
    assert Proposals.units_in_use() == 1
  end
end
