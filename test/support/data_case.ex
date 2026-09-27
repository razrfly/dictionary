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

  Two things:

    * **An advisory lock on the database's name,** held on a connection of its
      own. A second `mix test` on the same database — the default partition
      shared by two sessions, which is how the suite came to fail one run in
      four — would truncate under the first one's sandboxed tests and show them
      its committed rows. It now refuses to start, and says which variable to
      set.
    * **A truncate,** so the run starts on the empty database every sandboxed
      test assumes, whatever the run before it left behind. Measured at
      58–82 ms.

  The lock used to live on a connection this process checked out of the
  sandbox pool. That does not last: whenever a synchronous test puts the
  sandbox into shared mode, the ownership manager checks in every other
  owner's connection, so the claim's connection went back to the pool still
  holding the lock. From then on it was a lock on a random pooled connection,
  lost when that connection disconnected — a refused COMMIT always does — and
  invisible to the claim test when that test happened to run on it (session
  locks are re-entrant). Found by watching the proxy during PR #205 (#194).

  So the lock now has a connection outside the pool, which no sandbox mode
  change can touch, and which stops rather than silently reconnecting without
  the lock: losing the claim ends the run instead of leaving it unprotected.
  Both go away when this VM does, so a run killed under load never leaves a
  lock behind.
  """
  def claim_database! do
    config = DevilsDictionary.Repo.config()
    database = config[:database]

    {:ok, claim} =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
      # Idle pings are the one thing this connection does after the claim, and
      # a ping that times out disconnects it — and so drops the lock. Under
      # the load of a full suite a 15 s ping timeout is reachable; these are
      # not, and a connection that is really gone still fails its ping.
      |> Keyword.merge(
        backoff_type: :stop,
        sync_connect: true,
        idle_interval: 30_000,
        timeout: :timer.minutes(10)
      )
      |> Postgrex.start_link()

    %{rows: [[locked?, backend]]} =
      Postgrex.query!(claim, "select pg_try_advisory_lock(hashtext($1)), pg_backend_pid()", [
        database
      ])

    # Remembered so that a lost claim can be explained rather than re-run.
    :persistent_term.put({__MODULE__, :claimant_backend}, backend)

    unless locked? do
      raise """
      Another `mix test` is running against #{database}.

      Two suites on one database truncate under each other's sandboxed tests and
      see each other's committed rows. Give this run its own database:

          MIX_TEST_PARTITION=_yourname mix precommit
      """
    end

    # `:infinity`, because the sandbox's ownership timeout is 120 s by default
    # and closes the owned connection when it expires (CodeRabbit on #160).
    Ecto.Adapters.SQL.Sandbox.checkout(DevilsDictionary.Repo,
      sandbox: false,
      ownership_timeout: :infinity
    )

    truncate_all!()
  end

  @doc """
  Why the run's claim might not hold: whether the session that took it is
  still connected, and which sessions hold advisory locks now. For a failure
  message, so a recurrence is diagnosed on the spot.
  """
  def claim_diagnostics do
    backend = :persistent_term.get({__MODULE__, :claimant_backend}, nil)

    %{rows: activity} =
      DevilsDictionary.Repo.query!(
        "select pid, state, backend_start::text, query_start::text from pg_stat_activity where pid = $1",
        [backend]
      )

    %{rows: locks} =
      DevilsDictionary.Repo.query!(
        "select pid, classid, objid, granted from pg_locks where locktype = 'advisory' order by pid"
      )

    """
    claimant backend #{inspect(backend)}: #{if activity == [], do: "GONE — its session ended, so its lock went with it", else: inspect(activity)}
    advisory locks now held: #{inspect(locks)}
    this session: #{inspect(DevilsDictionary.Repo.query!("select pg_backend_pid()").rows)}
    """
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

    # The routing tables refuse TRUNCATE — their history is permanent — unless
    # the transaction opts in. A test reset is the one caller that may.
    {:ok, _} =
      DevilsDictionary.Repo.transaction(
        fn ->
          DevilsDictionary.Repo.query!("SET LOCAL dictionary.allow_routing_truncate = 'on'")

          DevilsDictionary.Repo.query!("truncate #{tables} restart identity cascade", [],
            timeout: 120_000
          )
        end,
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
