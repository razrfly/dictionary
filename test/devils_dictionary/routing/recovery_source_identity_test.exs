defmodule DevilsDictionary.Routing.RecoverySourceIdentityTest do
  @moduledoc """
  A restore drops its target first, so it must never land on the database a
  snapshot was taken from — and a pre-routing source has no routing state for
  the routing guard to protect. These tests hold `Snapshot.restore!/3` (and
  `mix dd.snapshot --restore`) to the identity the server reports:

    * the same database reached another way — `127.0.0.1` for `localhost`,
      the Unix socket for TCP, or after a rename — is refused;
    * another database on the same server, or a database of the same name
      on a genuinely different cluster, is allowed;
    * a missing, malformed or legacy sidecar, a dump that is not the one its
      sidecar describes, and a target whose server cannot be read are all
      refused;
    * every refusal comes before anything is dropped.

  Every database, and the second cluster, is created and removed here.
  """
  use DevilsDictionary.DataCase, async: false

  import ExUnit.CaptureIO

  alias DevilsDictionary.Routing.Recovery
  alias DevilsDictionary.Snapshot

  @moduletag :unboxed
  @moduletag :capture_log
  @moduletag timeout: 300_000

  setup do
    unique = System.unique_integer([:positive])
    base = Repo.config()[:database]
    db = Map.new(~w(source target other), &{&1, "#{base}_identity_#{unique}_#{&1}"})
    dump = Path.join(System.tmp_dir!(), "identity-#{unique}.dump")

    for {_tag, name} <- db, do: up!(config(name))

    on_exit(fn ->
      for {_tag, name} <- db, do: Ecto.Adapters.Postgres.storage_down(config(name))
      for file <- [dump, dump <> ".routing.json", dump <> ".other"], do: File.rm(file)
    end)

    corpus!(db["source"], "source")
    corpus!(db["target"], "keep me")
    Recovery.snapshot!(config(db["source"]), dump)

    %{db: db, dump: dump}
  end

  defp config(name), do: Keyword.put(Repo.config(), :database, name)

  defp up!(config) do
    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end

  defp corpus!(name, marker) do
    Recovery.with_database(name, fn ->
      Repo.query!(
        "CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0))"
      )

      Repo.query!("INSERT INTO schema_migrations VALUES (20260924222346, '2026-09-24 22:23:46')")
      Repo.query!("CREATE TABLE marks (id bigserial PRIMARY KEY, note text NOT NULL)")
      Repo.query!("INSERT INTO marks (note) VALUES ($1)", [marker])
    end)
  end

  # What a database holds, read over its own connection: the proof nothing
  # was dropped.
  defp marks(config) do
    {:ok, rows} =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
      |> then(&Postgrex.start_link(&1 ++ [backoff_type: :stop, sync_connect: true]))
      |> then(fn {:ok, conn} ->
        try do
          {:ok, Postgrex.query!(conn, "SELECT note FROM marks ORDER BY id", []).rows}
        after
          GenServer.stop(conn)
        end
      end)

    rows
  end

  defp refused(config, dump, pattern) do
    before = marks(config)
    assert {:error, message} = Snapshot.check_restore(config, dump)
    assert message =~ pattern

    error = assert_raise ArgumentError, fn -> Snapshot.restore!(config, dump) end
    assert error.message =~ pattern

    # Refused before anything was dropped.
    assert marks(config) == before
    message
  end

  defp socket? do
    port = Repo.config()[:port] || 5432
    File.exists?("/tmp/.s.PGSQL.#{port}")
  end

  test "a snapshot records its source as the server reports it", %{db: db, dump: dump} do
    assert {:ok, identity} = Snapshot.database_identity(config(db["source"]))
    assert is_integer(identity.database_oid)
    assert {:ok, ^identity} = Snapshot.source(dump)
    assert Snapshot.archive_database(dump) == db["source"]

    {:ok, recorded} = Snapshot.sidecar(dump)
    assert recorded["format"] == 2
    assert recorded["dump"] == Snapshot.fingerprint(dump)
  end

  test "the source is refused however it is reached, before anything is dropped",
       %{db: db, dump: dump} do
    source = config(db["source"])
    pattern = "database this snapshot was taken from"

    refused(source, dump, pattern)
    refused(Keyword.put(source, :hostname, "127.0.0.1"), dump, pattern)

    if socket?() do
      socket = source |> Keyword.delete(:hostname) |> Keyword.put(:socket_dir, "/tmp")
      refused(socket, dump, pattern)
    end

    # The operator's command stops at the same place.
    original = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    try do
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, source)

      assert_raise Mix.Error, ~r/database this snapshot was taken from/, fn ->
        Mix.Tasks.Dd.Snapshot.run(["--restore", dump, "--database", db["source"], "--quiet"])
      end
    after
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, original)
    end

    assert marks(source) == [["source"]]
  end

  test "a renamed source is still the source: the oid decides", %{db: db, dump: dump} do
    renamed = db["source"] <> "_renamed"

    rename = fn from, to ->
      Recovery.with_database("postgres", fn ->
        Repo.query!(~s|ALTER DATABASE "#{from}" RENAME TO "#{to}"|)
      end)
    end

    rename.(db["source"], renamed)

    try do
      refused(config(renamed), dump, "database this snapshot was taken from")
    after
      rename.(renamed, db["source"])
    end
  end

  test "another database on the same server may be restored over", %{db: db, dump: dump} do
    assert Snapshot.check_restore(config(db["target"]), dump) == :ok
    Snapshot.restore!(config(db["target"]), dump)
    assert marks(config(db["target"])) == [["source"]]

    assert {:ok, %{routing: :not_applicable}} =
             Recovery.with_database(db["target"], fn -> Recovery.verify(db["source"]) end)
  end

  test "a sidecar that cannot establish the source refuses every restore", %{db: db, dump: dump} do
    target = config(db["target"])
    sidecar = dump <> ".routing.json"
    {:ok, recorded} = Snapshot.sidecar(dump)

    # Missing.
    File.rm!(sidecar)
    assert Snapshot.source(dump) == {:error, :missing}
    refused(target, dump, "sidecar is missing")

    # Not JSON, and JSON of the wrong shape.
    File.write!(sidecar, "not json")
    assert Snapshot.source(dump) == {:error, :malformed}
    refused(target, dump, "sidecar is malformed")

    File.write!(sidecar, Jason.encode!(Map.put(recorded, "source", %{"database" => "x"})))
    assert Snapshot.source(dump) == {:error, :malformed}
    refused(target, dump, "sidecar is malformed")

    # Legacy: a name, host and port, but no identity from the server.
    File.write!(sidecar, Jason.encode!(Map.drop(recorded, ["source", "format"])))
    assert Snapshot.source(dump) == {:error, :legacy}
    refused(target, dump, "sidecar is legacy")
  end

  test "a dump and a sidecar that do not belong together are refused", %{db: db, dump: dump} do
    target = config(db["target"])
    sidecar = dump <> ".routing.json"
    {:ok, recorded} = Snapshot.sidecar(dump)

    # Another database's dump under this sidecar.
    Recovery.snapshot!(config(db["other"]), dump <> ".other")
    File.cp!(dump <> ".other", dump)
    File.write!(sidecar, Jason.encode!(recorded))
    refused(target, dump, "not the dump its sidecar describes")

    # The right bytes, but a sidecar naming a source the dump's header does not.
    Recovery.snapshot!(config(db["source"]), dump)
    {:ok, recorded} = Snapshot.sidecar(dump)

    File.write!(
      sidecar,
      Jason.encode!(put_in(recorded, ["source", "database"], db["other"]))
    )

    refused(target, dump, "its header names")
  end

  test "a target whose server cannot be read is refused, and nothing crashes",
       %{db: db, dump: dump} do
    unreachable = Keyword.put(config(db["target"]), :port, 1)
    assert {:error, message} = Snapshot.check_restore(unreachable, dump)
    assert message =~ "identity cannot be read"
    assert marks(config(db["target"])) == [["keep me"]]
  end

  test "verification refuses to compare a database with itself, however it is reached",
       %{db: db} do
    source = config(db["source"])

    alias_url =
      "ecto://#{source[:username]}:#{source[:password]}@127.0.0.1:#{source[:port] || 5432}/#{db["source"]}"

    original = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    try do
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, source)

      assert_raise Mix.Error, ~r/are the same database/, fn ->
        capture_io(fn -> Mix.Tasks.Dd.Routing.Verify.run(["--baseline", alias_url]) end)
      end
    after
      Application.put_env(:devils_dictionary, DevilsDictionary.Repo, original)
    end

    refute Recovery.same_database?(source, db["target"])
    assert Recovery.same_database?(source, alias_url)
  end

  @tag :second_cluster
  test "a database of the same name on a genuinely different cluster may be restored over",
       %{db: db, dump: dump} do
    with_second_cluster(fn port ->
      elsewhere = Keyword.merge(config(db["source"]), hostname: "localhost", port: port)
      up!(elsewhere)

      assert {:ok, there} = Snapshot.database_identity(elsewhere)
      assert {:ok, here} = Snapshot.source(dump)
      refute there.system_identifier == here.system_identifier
      assert there.database == here.database

      assert Snapshot.check_restore(elsewhere, dump) == :ok
      Snapshot.restore!(elsewhere, dump)
      assert marks(elsewhere) == [["source"]]

      # And it verifies against the source across the two clusters.
      url = "ecto://postgres@localhost:#{port}/#{db["source"]}"

      assert {:ok, %{routing: :not_applicable}} =
               Recovery.with_database(url, fn -> Recovery.verify(db["source"]) end)
    end)
  end

  # A throwaway cluster of the same PostgreSQL build, on a free port, with its
  # socket in its own directory; stopped and removed afterwards.
  defp with_second_cluster(fun) do
    initdb = System.find_executable("initdb")
    pg_ctl = System.find_executable("pg_ctl")
    assert initdb && pg_ctl, "initdb and pg_ctl must be on PATH for this test"

    dir = Path.join(System.tmp_dir!(), "dd-second-cluster-#{System.unique_integer([:positive])}")
    data = Path.join(dir, "data")
    File.mkdir_p!(dir)
    port = free_port()

    {_, 0} =
      System.cmd(initdb, ["-D", data, "-U", "postgres", "--auth=trust", "--encoding=UTF8"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        pg_ctl,
        [
          "-D",
          data,
          "-l",
          Path.join(dir, "log"),
          "-w",
          "-o",
          "-p #{port} -k #{dir} -c listen_addresses=localhost",
          "start"
        ],
        stderr_to_stdout: true
      )

    try do
      fun.(port)
    after
      System.cmd(pg_ctl, ["-D", data, "-m", "immediate", "-w", "stop"], stderr_to_stdout: true)
      File.rm_rf(dir)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
