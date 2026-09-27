defmodule DevilsDictionary.DataCaseTest do
  @moduledoc """
  The two rules `DataCase` enforces so the suite is green under concurrency for
  the same reasons it is green alone: an unboxed test never runs beside
  sandboxed ones, and one run has the database to itself.

  Unboxed and `async: false`, because the second rule is checked from the
  database's side — the lock the run holds is visible only to another
  session's connection, and a sandboxed test's connection is inside a
  transaction on the pool the helper claimed one connection of.
  """

  use DevilsDictionary.DataCase, async: false

  @moduletag :unboxed

  alias DevilsDictionary.{DataCase, Repo}

  describe "setup_sandbox/1" do
    test "refuses an unboxed test in an async module, and says what to do" do
      tags = %{unboxed: true, async: true, module: __MODULE__, test: :"a test"}

      assert_raise ArgumentError, ~r/unboxed inside an `async: true` module/, fn ->
        DataCase.setup_sandbox(tags)
      end

      assert_raise ArgumentError, ~r/Make the module `async: false`/, fn ->
        DataCase.setup_sandbox(tags)
      end
    end
  end

  describe "claim_database!/0" do
    test "holds the database for the run: a second claimant cannot take the lock" do
      database = Repo.config()[:database]

      # This test's own connection is a second session as far as Postgres is
      # concerned; the session-level lock `test_helper.exs` took is not
      # available to it, which is exactly what a second `mix test` would see.
      %{rows: [[taken?]]} = Repo.query!("select pg_try_advisory_lock(hashtext($1))", [database])

      # A lost claim is a finding, not a flake: the message says whose session
      # held it and whether that session is still there (#194, PR #205).
      if taken?, do: Repo.query!("select pg_advisory_unlock(hashtext($1))", [database])
      refute taken?, DataCase.claim_diagnostics()
    end

    # The failure this guards against was found in PR #205 (#194): a sandbox
    # mode change checked the claim's pooled connection back in, lock and all,
    # and the lock later vanished with whichever test disconnected it.
    test "the claim stays off the pool through a sandbox mode change" do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      # The switch checked in every other owner's connection — this test's too.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      claimant = :persistent_term.get({DataCase, :claimant_backend})
      parent = self()

      # Every connection the pool can hand out, held at once.
      tasks =
        for _ <- 1..(Repo.config()[:pool_size] - 1) do
          Task.async(fn ->
            :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
            %{rows: [[backend]]} = Repo.query!("select pg_backend_pid()")
            send(parent, :held)
            receive do: (:release -> backend)
          end)
        end

      for _ <- tasks, do: assert_receive(:held, 10_000)
      Enum.each(tasks, &send(&1.pid, :release))
      backends = Enum.map(tasks, &Task.await/1)

      refute claimant in backends, DataCase.claim_diagnostics()

      assert %{rows: [[1]]} =
               Repo.query!(
                 "select count(*) from pg_locks where pid = $1 and locktype = 'advisory' and granted",
                 [claimant]
               )
    end

    test "an unboxed test starts on an empty database, whatever ran before it" do
      # `setup_sandbox/1` truncated before this test began, so nothing another
      # test committed — or a killed run left — is here to be found.
      assert Repo.aggregate("lexemes", :count) == 0
      assert Repo.aggregate("sources", :count) == 0
    end
  end
end
