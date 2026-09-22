defmodule DevilsDictionary.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DevilsDictionary.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias DevilsDictionary.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DevilsDictionary.DataCase
    end
  end

  setup tags do
    DevilsDictionary.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  `@moduletag :unboxed` opts out. The sandbox wraps a whole test in one
  transaction, which is what makes tests fast and independent — and which also
  hides an entire class of defect: a **deferred** constraint is checked at the
  outermost COMMIT, so a bulk writer that mints an object in one autocommit
  statement and its subtype row in the next passes happily inside the sandbox
  and fails on the first real flush. The Wiktionary index pass did exactly that.

  An unboxed test runs for real and truncates after itself. It must be `async:
  false`; ExUnit runs sync tests after every async one, so the empty database it
  leaves behind is the state the sandbox expects anyway. That rule is enforced
  here: an unboxed test in an `async: true` module raises at setup, because run
  beside sandboxed tests its committed rows appear in their assertions and its
  truncation empties the database under them.

  It also truncates *before* it runs, not only after. The database a run
  starts on is whatever the last run left, and a run killed under load — or
  whose own truncate was cancelled — leaves the rows its unboxed tests had
  committed: `word_page_test.exs` then finds a `quoll` it never made, and
  `ScopeBuilderTest` fails in `setup` on `sources_slug_index`. `claim_database!/0`
  clears that at suite start; this clears it between unboxed tests within one.
  """
  def setup_sandbox(%{unboxed: true, async: true} = tags) do
    raise ArgumentError, """
    #{inspect(tags[:module])} runs "#{tags[:test]}" unboxed inside an `async: true` module.

    An unboxed test commits real rows and truncates every table when it ends. Run
    concurrently with sandboxed tests, its rows show up in their assertions and
    its truncation empties the database under them — the suite then fails one run
    in four with tests that pass alone. Make the module `async: false`, or move
    this test into a module that is (see the moduledoc of DevilsDictionary.DataCase).
    """
  end

  def setup_sandbox(%{unboxed: true}) do
    Ecto.Adapters.SQL.Sandbox.checkout(DevilsDictionary.Repo, sandbox: false)
    DevilsDictionary.DataCase.truncate_all!()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkout(DevilsDictionary.Repo, sandbox: false)
      DevilsDictionary.DataCase.truncate_all!()
    end)
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DevilsDictionary.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Claims the test database for this run, from `test_helper.exs`.

  Two things, on one connection this process holds for the life of the run:

    * **An advisory lock on the database's name.** A second `mix test` on the
      same database — the default partition shared by two sessions, which is
      how the suite came to fail one run in four — would truncate under the
      first one's sandboxed tests and show them its committed rows. It now
      refuses to start, and says which variable to set.
    * **A truncate,** so the run starts on the empty database every sandboxed
      test assumes, whatever the run before it left behind. Measured at
      58–82 ms.

  The lock is session-level and the connection is checked out from the
  sandbox pool without a sandbox; both go away when this VM does, so a run
  killed under load never leaves a lock behind.
  """
  def claim_database! do
    # `:infinity`, because the sandbox's ownership timeout is 120 s by default
    # and closes the owned connection when it expires — which would drop the
    # advisory lock a run under load is still relying on (CodeRabbit on #160).
    Ecto.Adapters.SQL.Sandbox.checkout(DevilsDictionary.Repo,
      sandbox: false,
      ownership_timeout: :infinity
    )

    database = DevilsDictionary.Repo.config()[:database]

    %{rows: [[locked?]]} =
      DevilsDictionary.Repo.query!("select pg_try_advisory_lock(hashtext($1))", [database])

    unless locked? do
      raise """
      Another `mix test` is running against #{database}.

      Two suites on one database truncate under each other's sandboxed tests and
      see each other's committed rows. Give this run its own database:

          MIX_TEST_PARTITION=_yourname mix precommit
      """
    end

    truncate_all!()
  end

  @doc """
  Empties every table an unboxed test could have written to.

  `RESTART IDENTITY CASCADE` so the next test sees the same empty database a
  rolled-back sandbox transaction leaves. Its own long timeout: a truncate that
  the default 15 s cancels under load is exactly the run that leaves rows
  behind for the next one.
  """
  def truncate_all! do
    %{rows: rows} =
      DevilsDictionary.Repo.query!("""
      select tablename from pg_tables
       where schemaname = 'public' and tablename <> 'schema_migrations'
      """)

    tables = rows |> List.flatten() |> Enum.map_join(", ", &~s("#{&1}"))

    DevilsDictionary.Repo.query!("truncate #{tables} restart identity cascade", [],
      timeout: 120_000
    )
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
