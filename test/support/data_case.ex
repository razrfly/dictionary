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
  leaves behind is the state the sandbox expects anyway.
  """
  def setup_sandbox(%{unboxed: true}) do
    Ecto.Adapters.SQL.Sandbox.checkout(DevilsDictionary.Repo, sandbox: false)

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
  Empties every table an unboxed test could have written to.

  `RESTART IDENTITY CASCADE` so the next test sees the same empty database a
  rolled-back sandbox transaction leaves.
  """
  def truncate_all! do
    %{rows: rows} =
      DevilsDictionary.Repo.query!("""
      select tablename from pg_tables
       where schemaname = 'public' and tablename <> 'schema_migrations'
      """)

    tables = rows |> List.flatten() |> Enum.map_join(", ", &~s("#{&1}"))

    DevilsDictionary.Repo.query!("truncate #{tables} restart identity cascade")
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
