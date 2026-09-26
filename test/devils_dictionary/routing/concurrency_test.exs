defmodule DevilsDictionary.Routing.ConcurrencyTest do
  @moduledoc """
  Races on independent database connections, not sequential calls dressed as
  concurrency (ADR 0004 §5). Every contender checks out its own connection,
  proves it with a distinct Postgres backend pid, and waits at a barrier until
  all are ready. These tests commit for real, so the deferred consistency
  checks run at an actual COMMIT.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Routing.{Ledger, Page, Pages, PublicPath, RouteChange}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :unboxed
  @contenders 6

  # Runs every function at once, each on its own connection. Returns the
  # results in order and the backend pid each ran on.
  defp race(funs) do
    parent = self()
    gate = make_ref()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, gate, backend_pid()})
          receive do: ({:go, ^gate} -> fun.())
        end)
      end

    backends =
      for _task <- tasks do
        assert_receive {:ready, ^gate, backend}, 10_000
        backend
      end

    Enum.each(tasks, &send(&1.pid, {:go, gate}))
    {Enum.map(tasks, &Task.await(&1, 30_000)), backends}
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp allocate(page, path, actor),
    do: fn -> Ledger.allocate(page.id, path, actor_id: actor.id, reason: "race") end

  test "racing for one address: one page wins, and every other is told who holds it" do
    importer = importer!()
    pages = for n <- 1..@contenders, do: subject_page!("people", "Voltaire #{n}", :person)

    {results, backends} = race(Enum.map(pages, &allocate(&1, "/people/voltaire", importer)))

    assert length(Enum.uniq(backends)) == @contenders

    assert [{:ok, %PublicPath{destination_page_id: winner}}] =
             Enum.filter(results, &match?({:ok, _}, &1))

    taken =
      {:error, {:path_taken, %{path: "/people/voltaire", kind: :canonical, page_id: winner}}}

    assert Enum.reject(results, &match?({:ok, _}, &1)) == List.duplicate(taken, @contenders - 1)

    assert [%PublicPath{id: path_id, original_page_id: ^winner}] = Repo.all(PublicPath)

    assert Repo.all(
             from p in Page,
               where: not is_nil(p.canonical_path_id),
               select: {p.id, p.canonical_path_id}
           ) ==
             [{winner, path_id}]

    assert [%{operation_id: op, path_id: ^path_id}, %{operation_id: op, page_id: ^winner}] =
             Repo.all(from c in RouteChange, order_by: c.sequence)
  end

  test "racing addresses for one page: the page gets exactly one canonical" do
    importer = importer!()
    page = subject_page!("people", "Voltaire", :person)
    paths = for n <- 1..@contenders, do: "/people/voltaire-#{n}"

    {results, backends} = race(Enum.map(paths, &allocate(page, &1, importer)))

    assert length(Enum.uniq(backends)) == @contenders
    assert [{:ok, %PublicPath{id: id, path: won}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert Enum.reject(results, &match?({:ok, _}, &1)) ==
             List.duplicate({:error, {:page_has_canonical, won}}, @contenders - 1)

    assert Repo.all(from p in PublicPath, select: p.path) == [won]
    assert Repo.get!(Page, page.id).canonical_path_id == id
  end

  test "racing to create one target's page yields one page" do
    entity = entity!(:person, "Voltaire")

    {results, backends} =
      race(for _n <- 1..@contenders, do: fn -> Pages.ensure(:subject, entity.object_id) end)

    assert length(Enum.uniq(backends)) == @contenders
    assert [id] = results |> Enum.map(fn {:ok, page} -> page.id end) |> Enum.uniq()
    assert Repo.all(from p in Page, select: p.id) == [id]
  end

  test "merges racing in opposite directions neither deadlock nor both win" do
    human = human!()

    pairs =
      for n <- 1..div(@contenders, 2) do
        a = overview_page!() |> allocated!("/on/pair-#{n}-a", human) |> published!()
        b = overview_page!() |> allocated!("/on/pair-#{n}-b", human) |> published!()
        {a, b}
      end

    merge = fn from, into ->
      fn -> Ledger.merge(from.id, into.id, actor_id: human.id, reason: "race") end
    end

    {results, _backends} =
      race(Enum.flat_map(pairs, fn {a, b} -> [merge.(a, b), merge.(b, a)] end))

    for {{a, b}, [forward, backward]} <- Enum.zip(pairs, Enum.chunk_every(results, 2)) do
      assert Enum.sort([elem(forward, 0), elem(backward, 0)]) == [:error, :ok]
      assert {:error, :page_not_active} in [forward, backward]

      survivor = if match?({:ok, _}, forward), do: b, else: a

      assert Repo.all(
               from p in PublicPath,
                 where: p.id in ^[a.canonical_path_id, b.canonical_path_id],
                 select: p.destination_page_id
             ) ==
               [survivor.id, survivor.id]
    end
  end

  test "the unique index decides a race the locks never saw, and the loser leaves nothing" do
    importer = importer!()
    ours = subject_page!("people", "Voltaire", :person)
    theirs = subject_page!("people", "Voltaire (musician)", :person)
    parent = self()
    handler = "routing-retry-#{inspect(self())}"

    :telemetry.attach(
      handler,
      [:devils_dictionary, :routing, :retry],
      fn _event, measurements, metadata, _config ->
        send(parent, {:retried, measurements.attempt, metadata.error})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # A writer that skips the ledger's advisory lock and holds its row
    # uncommitted: the allocator cannot see it, and only the index can.
    intruder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          lock_free_allocation!(theirs, "/people/voltaire", importer)
          send(parent, {:holding, self()})
          receive do: (:commit -> :committed)
        end)
      end)

    assert_receive {:holding, intruder_pid}, 10_000

    allocator =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:backend, backend_pid()})
        Ledger.allocate(ours.id, "/people/voltaire", actor_id: importer.id, reason: "race")
      end)

    assert_receive {:backend, backend}, 10_000
    blocked_on_a_transaction!(backend)
    send(intruder_pid, :commit)

    assert Task.await(intruder, 30_000) == {:ok, :committed}

    assert Task.await(allocator, 30_000) ==
             {:error,
              {:path_taken, %{path: "/people/voltaire", kind: :canonical, page_id: theirs.id}}}

    assert_received {:retried, 1, Ecto.ConstraintError}

    # The attempt that lost had already written its ledger row; it went with it.
    assert Repo.all(
             from c in RouteChange,
               where: c.page_id == ^ours.id or c.after_destination_id == ^ours.id
           ) == []

    assert Repo.get!(Page, ours.id).canonical_path_id == nil
  end

  test "a lost race is retried at most three times, then reported, never raised" do
    attempts = :counters.new(1, [])

    lost = fn ->
      :counters.add(attempts, 1, 1)
      raise postgres_error(:serialization_failure, "40001")
    end

    assert Ledger.transact(lost) == {:error, :allocation_conflict}
    assert :counters.get(attempts, 1) == 3

    # Anything that is not a lost race is a defect, and is not retried away.
    broken = fn -> raise postgres_error(:check_violation, "23514") end
    assert_raise Postgrex.Error, fn -> Ledger.transact(broken) end
  end

  defp postgres_error(code, pg_code) do
    %Postgrex.Error{
      postgres: %{code: code, pg_code: pg_code, severity: "ERROR", message: "synthetic #{code}"}
    }
  end

  # What a hand-written backfill that bypassed `Routing.Ledger` would do: every
  # row the database requires, and none of the ledger's locks.
  defp lock_free_allocation!(page, path, actor) do
    operation = Ecto.UUID.generate()
    %{rows: [[id]]} = Repo.query!("SELECT nextval('public_paths_id_seq')")

    created =
      Repo.insert!(%RouteChange{
        operation_id: operation,
        sequence: 1,
        operation: :allocate,
        path_id: id,
        after_kind: :canonical,
        after_destination_id: page.id,
        actor_id: actor.id,
        reason: "lock-free writer"
      })

    Repo.insert!(%PublicPath{
      id: id,
      path: path,
      kind: :canonical,
      original_page_id: page.id,
      destination_page_id: page.id,
      last_route_change_id: created.id
    })

    pointed =
      Repo.insert!(%RouteChange{
        operation_id: operation,
        sequence: 2,
        operation: :allocate,
        page_id: page.id,
        before_lifecycle: :active,
        after_lifecycle: :active,
        after_canonical_path_id: id,
        actor_id: actor.id,
        reason: "lock-free writer"
      })

    page
    |> Ecto.Changeset.change(canonical_path_id: id, last_route_change_id: pointed.id)
    |> Repo.update!()
  end

  # Waits, in Postgres, until `backend` is blocked behind another transaction
  # — which no message can announce, because the blocked process is inside a
  # query. Bounded at five seconds.
  defp blocked_on_a_transaction!(backend, tries \\ 500) do
    %{rows: [[blocked?]]} =
      Repo.query!(
        "SELECT count(*) = 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event = 'transactionid'",
        [backend]
      )

    cond do
      blocked? ->
        :ok

      tries == 0 ->
        flunk("the allocator never waited on the uncommitted row")

      true ->
        Repo.query!("SELECT pg_sleep(0.01)") && blocked_on_a_transaction!(backend, tries - 1)
    end
  end
end
