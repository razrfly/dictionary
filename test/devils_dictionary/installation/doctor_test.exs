defmodule DevilsDictionary.Installation.DoctorTest do
  @moduledoc """
  The doctor answers "is this installation ready?" without changing it:
  core checks decide usability, optional ones only degrade it, a pinned
  cluster it is not on fails, and it runs unchanged against a database
  whose every transaction is read-only. Its report encodes as JSON.
  """
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Installation.{Database, Doctor}
  alias DevilsDictionary.Snapshot

  @moduletag :unboxed
  @moduletag :capture_log

  setup do
    name = "#{Repo.config()[:database]}_doc#{System.unique_integer([:positive])}"
    config = Keyword.put(Repo.config(), :database, name)
    :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)
    %{name: name, config: config}
  end

  defp by_id(report), do: Map.new(report.checks, &{&1.id, &1})

  test "the configured test database is usable, and the report is JSON" do
    report = Doctor.run(env: :test)
    checks = by_id(report)

    assert report.usable, inspect(Enum.filter(report.checks, &(&1.status == :fail)))
    assert checks["server"].status == :ok
    assert checks["db_settings"].status == :ok
    assert checks["extensions"].status == :ok
    assert checks["schema"].status == :ok
    assert checks["jobs"].status == :ok
    assert checks["build"].status == :ok

    # Optional things are only ever optional.
    for id <- ~w(env runtime), do: assert(checks[id].category == :optional)

    assert {:ok, json} = Jason.encode(report)
    assert json =~ ~s("usable":true)
  end

  test "a database on another cluster than the pinned one is not usable" do
    report = Doctor.run(env: :test, expect_cluster: "1")
    assert by_id(report)["server"].status == :fail
    refute report.usable
  end

  test "a database without migrations, settings or extensions fails those checks, read-only",
       %{name: name, config: config} do
    # Every transaction in it is read-only: a doctor that wrote would fail here.
    {:ok, _} =
      Snapshot.probe(Snapshot.maintenance(config), fn conn ->
        Postgrex.query!(
          conn,
          ~s|ALTER DATABASE "#{name}" SET default_transaction_read_only = on|,
          []
        )

        Postgrex.query!(conn, ~s|ALTER DATABASE "#{name}" RESET timezone|, [])
      end)

    {:ok, before} = Database.write_counters(config)
    report = Doctor.run(env: :test, target: name)
    checks = by_id(report)

    refute report.usable
    assert checks["schema"].status == :fail
    assert checks["db_settings"].status == :fail
    assert checks["extensions"].status == :fail
    assert checks["database"].status == :ok

    assert {:ok, ^before} = Database.write_counters(config)
  end

  test "a missing database is reported, not created", %{config: config, name: name} do
    Ecto.Adapters.Postgres.storage_down(config)
    report = Doctor.run(env: :test, target: name)

    assert by_id(report)["database"].status == :fail
    assert {:ok, %{database: nil}} = Database.facts(config)
  end
end
