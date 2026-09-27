defmodule DevilsDictionary.Routing.RecoveryPreRoutingTest do
  @moduledoc """
  Recovery of a database that predates the routing migration — the state of
  the development corpus when the Stage 2A rehearsal began — and the
  comparisons around it:

    * a pre-routing copy is compared exactly, section by section, and routing
      is reported **not applicable**, never as recovered;
    * routing tables on one side only, or only some of them on either side,
      always fail;
    * a baseline may be on another server, named by URL, and "the same
      database" means the same server, port and name;
    * migration history decides as well: the routing migration recorded
      without its tables, or the tables without the migration, is
      inconsistent and fails. Restores over a snapshot's own source are
      covered by `RecoverySourceIdentityTest`.

  Every database here is created and dropped by the test.
  """
  use DevilsDictionary.DataCase, async: false

  import ExUnit.CaptureIO

  alias DevilsDictionary.Routing.Recovery
  alias DevilsDictionary.Snapshot

  @moduletag :unboxed
  @moduletag :capture_log
  @moduletag timeout: 300_000

  setup do
    source = Repo.config()[:database]
    unique = System.unique_integer([:positive])
    names = Map.new(~w(a b c d), &{&1, "#{source}_prerouting_#{unique}_#{&1}"})
    dump = Path.join(System.tmp_dir!(), "prerouting-#{unique}.dump")

    for {_tag, db} <- names do
      case Ecto.Adapters.Postgres.storage_up(config(db)) do
        :ok -> :ok
        {:error, :already_up} -> :ok
      end
    end

    on_exit(fn ->
      for {_tag, db} <- names, do: Ecto.Adapters.Postgres.storage_down(config(db))
      File.rm(dump)
      File.rm(dump <> ".routing.json")
    end)

    %{source: source, db: names, dump: dump}
  end

  defp config(db), do: Keyword.put(Repo.config(), :database, db)

  # A small corpus without routing tables: a migration row, registry rows
  # that reference each other, and one sequence used and one not.
  defp corpus!(db, extra \\ fn -> :ok end) do
    Recovery.with_database(db, fn ->
      for sql <- [
            "CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0))",
            "INSERT INTO schema_migrations VALUES (20260924222346, '2026-09-24 22:23:46')",
            "CREATE TABLE objects (id bigserial PRIMARY KEY, kind text NOT NULL)",
            """
            CREATE TABLE lexemes (object_id bigint PRIMARY KEY REFERENCES objects (id),
              lemma text NOT NULL, canonical_lexeme_id bigint REFERENCES lexemes (object_id))
            """,
            "CREATE TABLE unused (id bigserial PRIMARY KEY)",
            "INSERT INTO objects (kind) VALUES ('lexeme'), ('lexeme')",
            "INSERT INTO lexemes VALUES (1, 'oyster', NULL), (2, 'oistre', 1)"
          ],
          do: Repo.query!(sql)

      extra.()
    end)
  end

  defp url(db) do
    config = config(db)
    password = if config[:password], do: ":" <> URI.encode_www_form(config[:password]), else: ""

    "ecto://#{config[:username]}#{password}@127.0.0.1:#{config[:port] || 5432}/#{db}"
  end

  defp configured_as(database, fun) do
    original = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    Application.put_env(
      :devils_dictionary,
      DevilsDictionary.Repo,
      Keyword.put(original, :database, database)
    )

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, original)
    end
  end

  test "a pre-routing copy is compared exactly, and routing is not applicable, never recovered",
       %{db: db, dump: dump} do
    corpus!(db["a"])
    Recovery.snapshot!(config(db["a"]), dump)
    Snapshot.restore!(config(db["b"]), dump)

    assert {:ok, report} = Recovery.with_database(db["b"], fn -> Recovery.verify(db["a"]) end)
    assert report.routing == :not_applicable
    assert report.resolutions_match == :not_applicable

    assert Enum.sort(Map.keys(report.sections)) ==
             ~w(lexemes objects schema schema_migrations sequences unused)

    output =
      configured_as(db["b"], fn ->
        capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", db["a"]]) end)
      end)

    assert output =~ "routing                    not applicable"
    assert output =~ "matches #{db["a"]} on localhost"
    assert output =~ "Routing: not applicable, so routing recovery is not shown."
    refute output =~ "resolves the same"

    # Not vacuous: a changed reference, or a moved unused sequence, fails.
    Recovery.with_database(db["b"], fn ->
      Repo.query!("UPDATE lexemes SET canonical_lexeme_id = NULL WHERE object_id = 2")
      assert {:error, %{differences: changed}} = Recovery.verify(db["a"])
      assert Map.keys(changed) == ["lexemes"]
      Repo.query!("UPDATE lexemes SET canonical_lexeme_id = 1 WHERE object_id = 2")

      Repo.query!("SELECT setval('unused_id_seq', 5, false)")
      assert {:error, %{differences: moved}} = Recovery.verify(db["a"])
      assert Map.keys(moved) == ["sequences"]
      Repo.query!("SELECT setval('unused_id_seq', 1, false)")

      assert {:ok, _report} = Recovery.verify(db["a"])
    end)
  end

  test "routing tables on one side only, or only some of them, always fail",
       %{source: source, db: db} do
    partial = fn -> Repo.query!("CREATE TABLE pages (id bigserial PRIMARY KEY)") end
    corpus!(db["a"])
    corpus!(db["c"], partial)
    corpus!(db["d"], partial)

    assert Recovery.with_database(db["a"], &Recovery.routing_schema/0) == :absent
    assert Recovery.with_database(db["c"], &Recovery.routing_schema/0) == {:partial, ["pages"]}
    assert Recovery.routing_schema() == :present

    # Partly migrated against pre-routing.
    assert {:error, %{routing: {:mismatch, :absent, {:partial, ["pages"]}}}} =
             Recovery.with_database(db["c"], fn -> Recovery.verify(db["a"]) end)

    # Partly migrated on both sides, identically: every section matches, and
    # the comparison still fails, on routing alone.
    assert {:error, report} = Recovery.with_database(db["d"], fn -> Recovery.verify(db["c"]) end)
    assert report.differences == %{}
    assert report.routing == {:mismatch, {:partial, ["pages"]}, {:partial, ["pages"]}}

    # Routing on one side only, either way round.
    assert {:error, %{routing: {:mismatch, :absent, :present}}} = Recovery.verify(db["a"])

    assert {:error, %{routing: {:mismatch, :present, :absent}}} =
             Recovery.with_database(db["a"], fn -> Recovery.verify(source) end)

    configured_as(db["c"], fn ->
      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", db["a"]]) end)
        end

      assert error.message =~ "does not match"
    end)
  end

  test "a baseline can be named by URL on any server, and identity is server, port and name",
       %{db: db, dump: dump} do
    corpus!(db["a"])
    Recovery.snapshot!(config(db["a"]), dump)
    Snapshot.restore!(config(db["b"]), dump)
    port = Repo.config()[:port] || 5432

    assert Recovery.identity(config(db["a"])) == {"localhost", port, db["a"]}
    assert Recovery.identity(url(db["a"])) == {"localhost", port, db["a"]}
    assert Recovery.identity(db["a"]) == {"localhost", port, db["a"]}

    refute Recovery.identity(String.replace(url(db["a"]), ":#{port}/", ":5999/")) ==
             Recovery.identity(db["a"])

    assert Recovery.with_database(url(db["a"]), fn ->
             Repo.query!("SELECT current_database()").rows
           end) == [[db["a"]]]

    assert {:ok, %{routing: :not_applicable}} =
             Recovery.with_database(db["b"], fn -> Recovery.verify(url(db["a"])) end)

    configured_as(db["a"], fn ->
      assert_raise Mix.Error, ~r/the baseline must be a different database/, fn ->
        Mix.Tasks.Dd.Routing.Verify.run(["--baseline", url(db["a"])])
      end
    end)
  end

  test "routing is judged by migration history too: a recorded migration without its tables fails",
       %{db: db} do
    marker = fn ->
      Repo.query!("INSERT INTO schema_migrations VALUES (20260926193256, '2026-09-26 19:32:56')")
    end

    # The routing migration recorded, every routing table gone — on both
    # sides, identically. They match each other, and still fail.
    corpus!(db["a"], marker)
    corpus!(db["b"], marker)

    assert Recovery.with_database(db["a"], &Recovery.routing_schema/0) ==
             {:inconsistent, :migration_without_tables}

    assert {:error, report} = Recovery.with_database(db["b"], fn -> Recovery.verify(db["a"]) end)
    assert report.differences == %{}

    assert report.routing ==
             {:mismatch, {:inconsistent, :migration_without_tables},
              {:inconsistent, :migration_without_tables}}

    # Against a genuinely pre-routing database, too.
    corpus!(db["c"])

    assert {:error, %{routing: {:mismatch, :absent, {:inconsistent, :migration_without_tables}}}} =
             Recovery.with_database(db["b"], fn -> Recovery.verify(db["c"]) end)

    configured_as(db["b"], fn ->
      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", db["a"]]) end)
        end

      assert error.message =~ "does not match"
    end)
  end

  test "all six tables without the recorded migration, or no migration history, fail",
       %{db: db} do
    tables = fn ->
      for table <- Recovery.routing_tables(),
          do: Repo.query!(~s|CREATE TABLE "#{table}" (id bigserial PRIMARY KEY)|)
    end

    corpus!(db["a"], tables)
    corpus!(db["b"], tables)

    assert Recovery.with_database(db["a"], &Recovery.routing_schema/0) ==
             {:inconsistent, :tables_without_migration}

    assert {:error, %{routing: {:mismatch, same, same}}} =
             Recovery.with_database(db["b"], fn -> Recovery.verify(db["a"]) end)

    assert same == {:inconsistent, :tables_without_migration}

    Recovery.with_database(db["c"], fn ->
      Repo.query!("CREATE TABLE marks (id bigserial PRIMARY KEY)")
    end)

    Recovery.with_database(db["d"], fn ->
      Repo.query!("CREATE TABLE marks (id bigserial PRIMARY KEY)")
    end)

    assert Recovery.with_database(db["c"], &Recovery.routing_schema/0) ==
             {:inconsistent, :no_migration_history}

    assert {:error, %{routing: {:mismatch, _, _}}} =
             Recovery.with_database(db["d"], fn -> Recovery.verify(db["c"]) end)
  end
end
