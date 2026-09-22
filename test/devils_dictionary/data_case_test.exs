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
      assert %{rows: [[false]]} =
               Repo.query!("select pg_try_advisory_lock(hashtext($1))", [database])
    end

    test "an unboxed test starts on an empty database, whatever ran before it" do
      # `setup_sandbox/1` truncated before this test began, so nothing another
      # test committed — or a killed run left — is here to be found.
      assert Repo.aggregate("lexemes", :count) == 0
      assert Repo.aggregate("sources", :count) == 0
    end
  end
end
