defmodule DevilsDictionary.Installation.BundleBootstrapTest do
  @moduledoc """
  The installation move's interface, end to end on disposable databases
  (#211 §2, §5):

    * a bundle's dump and state come from one snapshot, its manifest binds
      both by size and SHA-256, and a busy source is refused;
    * a corrupted or missing part, an unapproved manifest, the source
      itself, another cluster than the pinned one, and a target holding
      anything else are each refused **before anything changes**;
    * an init restores exactly — rows, sequences, schema, owners and the
      database-level settings `pg_dump` leaves out — and a second run
      changes nothing;
    * an interrupted restore leaves only its marked staging database, which
      the next run replaces; a staging database without the marker is
      someone else's and is refused;
    * `--mode restore` creates nothing over its source's cluster, and onto a
      dedicated cluster made by `Cluster.init/1` it restores the same name
      exactly, roles included.

  Every database, directory and the second cluster are created and removed
  here.
  """
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Installation.{Bootstrap, Bundle, Cluster, Database, Manifest, State}
  alias DevilsDictionary.Routing.Recovery

  @moduletag :unboxed
  @moduletag :capture_log
  @moduletag timeout: 300_000

  setup do
    unique = System.unique_integer([:positive])
    base = Repo.config()[:database]
    names = Map.new(~w(src dst other), &{&1, "#{base}_bs#{unique}_#{&1}"})
    dir = Path.join(System.tmp_dir!(), "dd-bundle-#{unique}")
    File.mkdir_p!(dir)

    for {_tag, name} <- names, do: up!(name)

    on_exit(fn ->
      for {_tag, name} <- names,
          db <- [name, Bootstrap.staging_name(name)],
          do: Ecto.Adapters.Postgres.storage_down(config(db))

      File.rm_rf(dir)
    end)

    corpus!(names["src"])
    Ecto.Adapters.Postgres.storage_down(config(names["dst"]))

    %{names: names, dir: dir, probe: fn _ -> {:ok, external()} end}
  end

  defp external, do: %{mounted: true, external: true, device: "/dev/test", uuid: "TEST-UUID"}

  defp config(name), do: Keyword.put(Repo.config(), :database, name)

  defp up!(name) do
    case Ecto.Adapters.Postgres.storage_up(config(name)) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end
  end

  # A small installation: migration history, a table with a sequence and
  # text, a table without a primary key, and a database-level setting that
  # `pg_dump` does not carry (storage_up adds TimeZone=Etc/UTC itself).
  defp corpus!(name) do
    Recovery.with_database(name, fn ->
      Repo.query!(
        "CREATE TABLE schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0))"
      )

      Repo.query!("INSERT INTO schema_migrations VALUES (20260924222346, '2026-09-24 22:23:46')")
      Repo.query!("CREATE TABLE marks (id bigserial PRIMARY KEY, note text NOT NULL, body jsonb)")

      Repo.query!(
        ~s|INSERT INTO marks (note, body) VALUES ('a', '{"x": 1}'), ('b', NULL), ('ç', '[]')|
      )

      Repo.query!("CREATE TABLE loose (n int, label text)")
      Repo.query!("INSERT INTO loose VALUES (2, 'two'), (1, 'one')")

      # Routing recovery leaves Oban's tables out; an installation keeps them.
      Repo.query!("CREATE TABLE oban_jobs (id bigserial PRIMARY KEY, state text NOT NULL)")
      Repo.query!("INSERT INTO oban_jobs (state) VALUES ('completed'), ('available')")
    end)

    {:ok, _} =
      DevilsDictionary.Snapshot.probe(
        DevilsDictionary.Snapshot.maintenance(config(name)),
        fn conn ->
          Postgrex.query!(conn, ~s|ALTER DATABASE "#{name}" SET statement_timeout TO '123s'|, [])
        end
      )
  end

  defp bundle!(names, dir, probe, opts \\ []) do
    out = Path.join(dir, "bundle")

    {:ok, result} =
      Bundle.create(
        Keyword.merge(
          [source: names["src"], out: out, volume: dir, inputs: false, probe: probe],
          opts
        )
      )

    result
  end

  defp init(names, bundle, digest, opts \\ []) do
    Bootstrap.run(
      :init,
      Keyword.merge(
        [bundle: bundle, target: names["dst"], expect_manifest_sha256: digest],
        opts
      )
    )
  end

  defp exists?(name) do
    {:ok, facts} = Database.facts(config(name))
    facts.database
  end

  test "a bundle binds its dump and its state, and an init restores it exactly, once",
       %{names: names, dir: dir, probe: probe} do
    %{manifest: manifest, digest: digest, path: bundle} = bundle!(names, dir, probe)

    assert manifest["format"] == "dd.bundle/1"
    assert manifest["tool"]["revision"] =~ ~r/\A[0-9a-f]{40}\z/
    assert manifest["code"]["revision"] == manifest["tool"]["revision"]
    assert manifest["quiescence"]["quiet"]
    assert manifest["source"]["database"] == names["src"]
    assert manifest["schema"]["versions"] == [20_260_924_222_346]
    assert Enum.map(manifest["files"], & &1["role"]) == ["dump", "state"]
    assert digest == Manifest.digest(bundle)

    # The database-level settings are recorded, TimeZone included.
    assert [%{"role" => nil, "config" => config}] = manifest["database"]["settings"]
    assert "statement_timeout=123s" in config
    assert "TimeZone=Etc/UTC" in config

    assert {:ok, _report} = Bundle.verify(bundle)

    # Initialise another installation from it.
    assert {:ok, report} = init(names, bundle, digest)
    assert report.outcome == :restored
    refute exists?(Bootstrap.staging_name(names["dst"]))

    expected = Jason.decode!(File.read!(Path.join(bundle, "db/#{names["src"]}.state.json")))
    assert expected["sections"]["oban_jobs"]["count"] == 2
    assert State.diff(expected, State.capture(names["dst"]), ignore: [:name]) == []
    assert exists?(names["dst"])["settings"] == manifest["database"]["settings"]

    # And again: the same state is recognised and left alone.
    assert {:ok, again} = init(names, bundle, digest)
    assert again.outcome == :already_restored
    assert again.database_oid == report.database_oid
  end

  test "a manifest reads only under a well-formed exported snapshot id", %{names: names} do
    assert_raise ArgumentError, ~r/not an exported snapshot id/, fn ->
      Recovery.with_database(names["src"], fn ->
        Recovery.manifest(snapshot: "1'; DROP TABLE marks; --")
      end)
    end
  end

  test "the comparison sees a changed row, sequence or setting", %{
    names: names,
    dir: dir,
    probe: probe
  } do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)
    {:ok, _} = init(names, bundle, digest)
    expected = Jason.decode!(File.read!(Path.join(bundle, "db/#{names["src"]}.state.json")))

    Recovery.with_database(names["dst"], fn ->
      Repo.query!("SELECT setval('marks_id_seq', 50)")
    end)

    assert [%{section: "sequences"}] =
             State.diff(expected, State.capture(names["dst"]), ignore: [:name])

    Recovery.with_database(names["dst"], fn ->
      Repo.query!("SELECT setval('marks_id_seq', 3)")
      Repo.query!("UPDATE loose SET label = 'TWO' WHERE n = 2")
    end)

    assert [%{section: "table loose"}] =
             State.diff(expected, State.capture(names["dst"]), ignore: [:name])

    {:ok, _} =
      DevilsDictionary.Snapshot.probe(
        DevilsDictionary.Snapshot.maintenance(config(names["dst"])),
        fn conn ->
          Postgrex.query!(conn, ~s|ALTER DATABASE "#{names["dst"]}" RESET statement_timeout|, [])
        end
      )

    sections =
      State.diff(expected, State.capture(names["dst"]), ignore: [:name]) |> Enum.map(& &1.section)

    assert "database settings" in sections
  end

  test "refusals come before anything changes", %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)

    # Not the approved manifest.
    assert {:error, message} = init(names, bundle, String.duplicate("0", 64))
    assert message =~ "not the approved bundle"

    # The source itself, by name.
    assert {:error, message} =
             Bootstrap.run(:init,
               bundle: bundle,
               target: names["src"],
               expect_manifest_sha256: digest
             )

    assert message =~ "the bundle's source database"

    # Another cluster than the pinned one.
    assert {:error, message} = init(names, bundle, digest, target_cluster: "1")
    assert message =~ "not the pinned 1"

    # A target holding something else is left exactly as it was.
    up!(names["other"])
    Recovery.with_database(names["other"], fn -> Repo.query!("CREATE TABLE keep (x int)") end)

    assert {:error, message} =
             Bootstrap.run(:init,
               bundle: bundle,
               target: names["other"],
               expect_manifest_sha256: digest
             )

    assert message =~ "already exists with other contents"
    assert Database.populated?(config(names["other"])) == {:ok, true}

    # An empty database that this tooling did not create is refused too.
    Ecto.Adapters.Postgres.storage_down(config(names["other"]))
    up!(names["other"])

    assert {:error, message} =
             Bootstrap.run(:init,
               bundle: bundle,
               target: names["other"],
               expect_manifest_sha256: digest
             )

    assert message =~ "exists and is empty"

    # Restore mode refuses the source's own cluster.
    {:ok, %{server: server}} = Database.facts(config(names["src"]))

    assert {:error, message} =
             Bootstrap.run(:restore,
               bundle: bundle,
               target: names["src"] <> "x",
               expect_manifest_sha256: digest,
               target_cluster: server.system_identifier,
               volume: dir,
               probe: probe
             )

    assert message =~ "keeps the database's name" or message =~ "source's own cluster"

    # A corrupted dump: verification fails and nothing is created.
    dump = Path.join(bundle, "db/#{names["src"]}.dump")
    bytes = File.read!(dump)
    middle = div(byte_size(bytes), 2)
    <<head::binary-size(middle), byte, tail::binary>> = bytes
    File.write!(dump, head <> <<Bitwise.bxor(byte, 0xFF)>> <> tail)

    assert {:error, message} = init(names, bundle, digest)
    assert message =~ "does not verify"
    refute exists?(names["dst"])
    refute exists?(Bootstrap.staging_name(names["dst"]))

    # A missing part.
    File.rm!(dump)
    assert {:error, message} = init(names, bundle, digest)
    assert message =~ "missing"
  end

  test "an interrupted restore is started again; someone else's staging database is refused",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle, manifest: manifest} = bundle!(names, dir, probe)
    staging = Bootstrap.staging_name(names["dst"])
    marker = "dd.bootstrap staging #{String.slice(digest, 0, 16)} for #{names["dst"]}"

    # What an interrupted run leaves: the marked staging database, half built.
    Database.create!(config(names["dst"]), staging, manifest["database"], marker)
    Recovery.with_database(staging, fn -> Repo.query!("CREATE TABLE half (x int)") end)

    assert {:ok, %{outcome: :restored}} = init(names, bundle, digest)
    refute exists?(staging)

    # A staging database without the marker belongs to someone else.
    other_target = names["other"]
    Ecto.Adapters.Postgres.storage_down(config(other_target))
    other_staging = Bootstrap.staging_name(other_target)
    up!(other_staging)

    assert {:error, message} =
             Bootstrap.run(:init,
               bundle: bundle,
               target: other_target,
               expect_manifest_sha256: digest
             )

    assert message =~ "not this bootstrap's staging database"
    assert exists?(other_staging)
    Ecto.Adapters.Postgres.storage_down(config(other_staging))
  end

  test "a capture refuses a source with other sessions connected", %{
    names: names,
    dir: dir,
    probe: probe
  } do
    {:ok, conn} =
      config(names["src"])
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    try do
      assert {:error, message} =
               Bundle.create(
                 source: names["src"],
                 out: Path.join(dir, "b"),
                 volume: dir,
                 inputs: false,
                 probe: probe
               )

      assert message =~ "other sessions are connected"
      refute File.exists?(Path.join(dir, "b/MANIFEST.json"))
    after
      GenServer.stop(conn)
    end
  end

  test "a finished bundle is never overwritten, and a transfer resumes and verifies",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)

    assert {:error, message} =
             Bundle.create(
               source: names["src"],
               out: bundle,
               volume: dir,
               inputs: false,
               probe: probe
             )

    assert message =~ "never overwritten"

    copy = Path.join(dir, "copy")
    dump = "db/#{names["src"]}.dump"
    File.mkdir_p!(Path.join(copy, "db"))

    File.write!(
      Path.join(copy, dump <> ".partial"),
      binary_part(File.read!(Path.join(bundle, dump)), 0, 100)
    )

    assert {:ok, report} =
             Bundle.transfer(bundle, copy,
               volume: dir,
               probe: probe,
               expect_manifest_sha256: digest
             )

    assert report.digest == digest
  end

  test "the second copy goes to an internal volume only when asked, and never beside the bundle",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)
    internal = fn _ -> {:ok, external() |> Map.merge(%{external: false, internal: true})} end
    copy = Path.join(dir, "second-copy")
    # The bundle on an external drive; no reserve to meet on the suite's disk.
    second = [internal: true, probe: internal, source_probe: probe, reserve_bytes: 0]

    # Without `internal: true`, an internal destination is refused as ever.
    assert {:error, message} = Bundle.transfer(bundle, copy, volume: dir, probe: internal)
    assert message =~ "internal volume"

    # Asked for, but on the bundle's own device: it would survive nothing.
    assert {:error, message} = Bundle.transfer(bundle, copy, second)
    assert message =~ "same device"

    # Nor is a copy of a bundle that is not itself on the external drive.
    assert {:error, message} =
             Bundle.transfer(bundle, copy, Keyword.put(second, :source_probe, internal))

    assert message =~ "not on an external volume"
    refute File.exists?(copy)

    # On another device (the suite has one disk, so the bundle's is
    # reported as another), it is copied and verified, manifest last.
    apart = fn path ->
      with {:ok, stat} <- File.stat(path) do
        if path == bundle,
          do: {:ok, %{stat | major_device: stat.major_device + 1}},
          else: {:ok, stat}
      end
    end

    assert {:ok, report} =
             Bundle.transfer(
               bundle,
               copy,
               second ++ [stat: apart, expect_manifest_sha256: digest]
             )

    assert report.digest == digest
    assert {:ok, _} = Bundle.verify(copy)
  end

  test "inputs are bundled by their pins, and a damaged input is refused", %{
    dir: dir,
    probe: probe,
    names: names
  } do
    root = Path.join(dir, "checkout")
    File.mkdir_p!(Path.join(root, "data"))
    File.mkdir_p!(Path.join(root, "priv/sources"))
    File.mkdir_p!(Path.join(root, "priv/replay"))
    File.write!(Path.join(root, "data/input.gz"), "pinned input bytes")
    File.write!(Path.join(root, "priv/replay/a.jsonl.gz"), "replay bytes")

    pin = fn path ->
      %{
        "byte_count" => File.stat!(path).size,
        "sha256" => DevilsDictionary.Installation.Files.sha256(path)
      }
    end

    input = pin.(Path.join(root, "data/input.gz"))
    replay = pin.(Path.join(root, "priv/replay/a.jsonl.gz"))

    File.write!(
      Path.join(root, "priv/sources/MANIFEST.json"),
      Jason.encode!(%{
        "inputs" => [
          Map.merge(input, %{
            "source" => "x",
            "archive_locator" => "data/input.gz",
            "committed" => false
          }),
          %{
            "source" => "y",
            "archive_locator" => "priv/sources/in-git.txt",
            "committed" => true,
            "sha256" => "00"
          }
        ]
      })
    )

    File.write!(
      Path.join(root, "priv/replay/MANIFEST.json"),
      Jason.encode!(%{"files" => [Map.merge(replay, %{"file" => "a.jsonl.gz", "source" => "a"})]})
    )

    %{manifest: manifest, path: bundle} =
      bundle!(names, dir, probe, inputs: true, root: root, out: Path.join(dir, "with-inputs"))

    assert Enum.map(manifest["files"], &{&1["role"], &1["path"]}) == [
             {"dump", "db/#{names["src"]}.dump"},
             {"state", "db/#{names["src"]}.state.json"},
             {"input", "inputs/data/input.gz"},
             {"replay", "inputs/priv/replay/a.jsonl.gz"},
             {"replay-manifest", "inputs/priv/replay/MANIFEST.json"}
           ]

    assert {:ok, _} = Bundle.verify(bundle)

    File.write!(Path.join(root, "data/input.gz"), "damaged input bytes")

    assert {:error, message} =
             Bundle.create(
               source: names["src"],
               out: Path.join(dir, "damaged"),
               volume: dir,
               root: root,
               probe: probe
             )

    assert message =~ "is not the input priv/sources/MANIFEST.json pins"
  end

  test "a capture recorded unquiet is not reused when quiet is required", %{
    names: names,
    dir: dir,
    probe: probe
  } do
    out = Path.join(dir, "resumed")
    root = Path.join(dir, "no-inputs-here")
    File.mkdir_p!(Path.join(root, "priv/sources"))
    File.mkdir_p!(Path.join(root, "priv/replay"))

    File.write!(
      Path.join(root, "priv/sources/MANIFEST.json"),
      ~s({"inputs": [{"source": "x", "archive_locator": "data/gone.gz", "committed": false, "byte_count": 1, "sha256": "00"}]})
    )

    File.write!(Path.join(root, "priv/replay/MANIFEST.json"), ~s({"files": []}))

    # A rehearsal capture, allowed to be unquiet, interrupted at the inputs.
    assert {:error, _} =
             Bundle.create(
               source: names["src"],
               out: out,
               volume: dir,
               root: root,
               probe: probe,
               require_quiet: false
             )

    capture = Path.join(out, "db/capture.json")
    recorded = capture |> File.read!() |> Jason.decode!()
    File.write!(capture, Jason.encode!(put_in(recorded, ["quiescence", "quiet"], false)))

    # The real baseline: the unquiet capture must be taken again, not reused.
    assert {:ok, %{manifest: manifest}} =
             Bundle.create(
               source: names["src"],
               out: out,
               volume: dir,
               inputs: false,
               probe: probe
             )

    assert manifest["quiescence"]["quiet"]
    refute manifest["snapshot"] == recorded["snapshot"]
  end

  test "the window fingerprint sees a nextval that writes no row", %{names: names} do
    {:ok, before} = Database.window_fingerprint(config(names["src"]))
    {:ok, counters} = Database.write_counters(config(names["src"]))

    Recovery.with_database(names["src"], fn -> Repo.query!("SELECT nextval('marks_id_seq')") end)

    {:ok, later} = Database.window_fingerprint(config(names["src"]))
    refute later["sequences"] == before["sequences"]
    assert later["catalog"] == before["catalog"]
    assert {:ok, ^counters} = Database.write_counters(config(names["src"]))
  end

  test "a restored target still carrying the marker is finished, not refused",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)
    {:ok, %{database_oid: oid}} = init(names, bundle, digest)

    # What a run interrupted between its rename and its comment leaves.
    marker = "dd.bootstrap staging #{String.slice(digest, 0, 16)} for #{names["dst"]}"
    Database.set_comment!(config(names["dst"]), names["dst"], marker)

    assert {:ok, %{outcome: :restored, database_oid: ^oid}} = init(names, bundle, digest)
    assert exists?(names["dst"])["comment"] == nil
  end

  test "an input that cannot be placed is refused before any database is created",
       %{names: names, dir: dir, probe: probe} do
    root = Path.join(dir, "checkout")
    File.mkdir_p!(Path.join(root, "data"))
    File.mkdir_p!(Path.join(root, "priv/sources"))
    File.mkdir_p!(Path.join(root, "priv/replay"))
    File.write!(Path.join(root, "data/input.gz"), "pinned input bytes")
    input = Path.join(root, "data/input.gz")

    File.write!(
      Path.join(root, "priv/sources/MANIFEST.json"),
      Jason.encode!(%{
        "inputs" => [
          %{
            "source" => "x",
            "archive_locator" => "data/input.gz",
            "committed" => false,
            "byte_count" => File.stat!(input).size,
            "sha256" => DevilsDictionary.Installation.Files.sha256(input)
          }
        ]
      })
    )

    File.write!(Path.join(root, "priv/replay/MANIFEST.json"), ~s({"files": []}))

    %{digest: digest, path: bundle} =
      bundle!(names, dir, probe, inputs: true, root: root, out: Path.join(dir, "placing"))

    destination = Path.join(dir, "new-checkout")
    File.mkdir_p!(Path.join(destination, "data"))
    File.write!(Path.join(destination, "data/input.gz"), "something else")

    assert {:error, message} = init(names, bundle, digest, place_inputs: destination)
    assert message =~ "exists with other contents"
    refute exists?(names["dst"])
    refute exists?(Bootstrap.staging_name(names["dst"]))
  end

  test "a second bootstrap of the same target is refused while one runs",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle} = bundle!(names, dir, probe)
    lock = :erlang.phash2({:dd_bootstrap, names["dst"]}, 2_147_483_647)

    {:ok, conn} =
      config("postgres")
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    try do
      %{rows: [[true]]} = Postgrex.query!(conn, "SELECT pg_try_advisory_lock($1)", [lock])
      assert {:error, message} = init(names, bundle, digest)
      assert message =~ "another bootstrap"
      refute exists?(names["dst"])
    after
      GenServer.stop(conn)
    end
  end

  test "a manifest path outside the bundle is refused" do
    assert {:error, message} = Manifest.confined(%{"files" => [%{"path" => "../escape"}]})
    assert message =~ "outside the bundle"
    assert :ok = Manifest.confined(%{"files" => [%{"path" => "db/x.dump"}]})
  end

  test "list settings come back element by element, as pg_dump writes them",
       %{names: names, dir: dir, probe: probe} do
    {:ok, _} =
      DevilsDictionary.Snapshot.probe(
        DevilsDictionary.Snapshot.maintenance(config(names["src"])),
        fn conn ->
          # A list of quoted names, one of them needing the quotes, and a
          # list setting that is not one (DateStyle reads its own string).
          Postgrex.query!(
            conn,
            ~s|ALTER DATABASE "#{names["src"]}" SET search_path TO '$user', public, 'Odd "Schema"'|,
            []
          )

          Postgrex.query!(
            conn,
            ~s|ALTER DATABASE "#{names["src"]}" SET DateStyle TO 'ISO, MDY'|,
            []
          )
        end
      )

    %{digest: digest, path: bundle, manifest: manifest} = bundle!(names, dir, probe)
    [%{"config" => recorded}] = manifest["database"]["settings"]
    assert ~s|search_path="$user", public, "Odd ""Schema"""| in recorded

    assert {:ok, %{outcome: :restored}} = init(names, bundle, digest)
    assert exists?(names["dst"])["settings"] == manifest["database"]["settings"]

    expected = Jason.decode!(File.read!(Path.join(bundle, "db/#{names["src"]}.state.json")))
    assert State.diff(expected, State.capture(names["dst"]), ignore: [:name]) == []
  end

  test "a cluster whose role setup fails after it started is stopped again",
       %{names: names, dir: dir, probe: probe} do
    %{path: bundle} = bundle!(names, dir, probe)

    # A recorded role the new cluster refuses: an expiry that is no time.
    manifest_path = Manifest.path(bundle)
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    bad = %{
      "name" => "dd_bad_expiry",
      "superuser" => false,
      "inherit" => true,
      "createrole" => false,
      "createdb" => false,
      "login" => true,
      "replication" => false,
      "bypassrls" => false,
      "connection_limit" => -1,
      "valid_until" => "not a time",
      "member_of" => []
    }

    File.write!(
      manifest_path,
      Jason.encode!(Map.update!(manifest, "cluster_roles", &(&1 ++ [bad])))
    )

    data = Path.join(dir, "failing/data")
    port = free_port()
    stop_on_exit(data)

    try do
      assert {:error, message} =
               Cluster.init(bundle: bundle, data_dir: data, port: port, volume: dir, probe: probe)

      assert message =~ "completing the cluster's setup failed"
      assert message =~ "has been stopped"
      assert Cluster.port_free?(port)
      assert {_out, 3} = System.cmd("pg_ctl", ["-D", data, "status"], stderr_to_stdout: true)
    after
      System.cmd("pg_ctl", ["-D", data, "-m", "immediate", "-w", "stop"], stderr_to_stdout: true)
    end
  end

  test "settings that cannot be checked or would fight the task are refused before initdb",
       %{names: names, dir: dir, probe: probe} do
    %{path: bundle} = bundle!(names, dir, probe)
    data = Path.join(dir, "refused/data")

    for {settings, pattern} <- [
          {[{"work_mem", "8MB"}, {"WORK_MEM", "16MB"}], "given more than once"},
          {[{"port", "6000"}], "this task sets them itself"},
          {[{"auto_explain.log_min_duration", "1s"}], "plain parameter name"},
          {[{"work mem", "8MB"}], "plain parameter name"}
        ] do
      assert {:error, message} =
               Cluster.init(
                 bundle: bundle,
                 data_dir: data,
                 port: free_port(),
                 volume: dir,
                 probe: probe,
                 settings: settings
               )

      assert message =~ pattern
      refute File.exists?(data)
    end
  end

  test "a restart the server cannot come back from is reported as such, and an unknown setting stops it",
       %{names: names, dir: dir, probe: probe} do
    %{path: bundle} = bundle!(names, dir, probe)

    # Accepted by ALTER SYSTEM (no check), refused by the postmaster at start.
    data = Path.join(dir, "no-library/data")
    port = free_port()
    stop_on_exit(data)

    assert {:error, message} =
             Cluster.init(
               bundle: bundle,
               data_dir: data,
               port: port,
               volume: dir,
               probe: probe,
               settings: [{"shared_preload_libraries", "dd_no_such_library"}]
             )

    assert message =~ "pg_ctl restart exited"
    assert message =~ "is not running"
    assert message =~ "remove it and run again"
    assert Cluster.port_free?(port)

    other = Path.join(dir, "unknown/data")
    other_port = free_port()
    stop_on_exit(other)

    assert {:error, message} =
             Cluster.init(
               bundle: bundle,
               data_dir: other,
               port: other_port,
               volume: dir,
               probe: probe,
               settings: [{"no_such_setting", "1"}]
             )

    assert message =~ "knows no setting no_such_setting"
    assert message =~ "has been stopped"
    assert Cluster.port_free?(other_port)
  end

  test "restore mode builds onto a dedicated cluster: same name, roles, exact state",
       %{names: names, dir: dir, probe: probe} do
    %{digest: digest, path: bundle, manifest: manifest} = bundle!(names, dir, probe)
    data = Path.join(dir, "cluster/data")
    port = free_port()
    stop_on_exit(data)

    try do
      # A list of quoted names (two libraries), a mixed-case name given in
      # lower case, a restart-only setting and two reload ones.
      settings = [
        {"wal_sync_method", "fsync_writethrough"},
        {"shared_buffers", "64MB"},
        {"work_mem", "8MB"},
        {"shared_preload_libraries", "pg_stat_statements,auto_explain"},
        {"timezone", "Etc/UTC"}
      ]

      assert {:ok, cluster} =
               Cluster.init(
                 bundle: bundle,
                 data_dir: data,
                 port: port,
                 volume: dir,
                 probe: probe,
                 settings: settings
               )

      assert cluster.outcome == :created

      # Each setting running, under the server's own name: shared_buffers
      # and the libraries needed the restart, and the libraries are two.
      assert cluster.settings == %{
               "wal_sync_method" => "fsync_writethrough",
               "shared_buffers" => "64MB",
               "work_mem" => "8MB",
               "shared_preload_libraries" => "pg_stat_statements, auto_explain",
               "TimeZone" => "Etc/UTC"
             }

      refute cluster.system_identifier == manifest["source"]["system_identifier"]

      # Its roles are the source cluster's, attributes and all.
      {:ok, roles} = Database.roles(target_config(port, "postgres"))
      assert roles == manifest["cluster_roles"]

      target = "ecto://postgres@localhost:#{port}/#{names["src"]}"

      # A different name is refused in restore mode.
      assert {:error, message} =
               Bootstrap.run(:restore,
                 bundle: bundle,
                 target: "ecto://postgres@localhost:#{port}/#{names["dst"]}",
                 expect_manifest_sha256: digest,
                 target_cluster: cluster.system_identifier,
                 volume: dir,
                 probe: probe
               )

      assert message =~ "keeps the database's name"

      assert {:ok, report} =
               Bootstrap.run(:restore,
                 bundle: bundle,
                 target: target,
                 expect_manifest_sha256: digest,
                 target_cluster: cluster.system_identifier,
                 volume: dir,
                 probe: probe
               )

      assert report.outcome == :restored
      expected = Jason.decode!(File.read!(Path.join(bundle, "db/#{names["src"]}.state.json")))
      assert State.diff(expected, State.capture(target)) == []

      # Running the cluster setup again reports the running cluster, and
      # checks its settings without changing them.
      assert {:ok, %{outcome: :present, system_identifier: id}} =
               Cluster.init(
                 bundle: bundle,
                 data_dir: data,
                 port: port,
                 volume: dir,
                 probe: probe,
                 settings: settings
               )

      assert id == cluster.system_identifier

      assert {:error, message} =
               Cluster.init(
                 bundle: bundle,
                 data_dir: data,
                 port: port,
                 volume: dir,
                 probe: probe,
                 settings: [{"work_mem", "16MB"}]
               )

      assert message =~ "not in effect as requested"

      # Written by hand and not reloaded: in the file, not running, refused.
      {:ok, _} =
        DevilsDictionary.Snapshot.probe(
          DevilsDictionary.Snapshot.maintenance(target_config(port, "postgres")),
          &Postgrex.query!(&1, "ALTER SYSTEM SET work_mem = '32MB'", [])
        )

      assert {:error, message} =
               Cluster.init(
                 bundle: bundle,
                 data_dir: data,
                 port: port,
                 volume: dir,
                 probe: probe,
                 settings: [{"work_mem", "32MB"}]
               )

      assert message =~ "written but not running"
      assert message =~ "checked, never changed"
    after
      System.cmd("pg_ctl", ["-D", data, "-m", "immediate", "-w", "stop"], stderr_to_stdout: true)
    end
  end

  # `after` does not run when a test times out; on_exit does, so a
  # throwaway cluster never outlives its test. It runs before the setup's
  # own on_exit removes the directory.
  defp stop_on_exit(data) do
    on_exit(fn ->
      System.cmd("pg_ctl", ["-D", data, "-m", "immediate", "-w", "stop"], stderr_to_stdout: true)
    end)
  end

  defp target_config(port, database),
    do: [
      hostname: "localhost",
      port: port,
      username: "postgres",
      password: "",
      database: database
    ]

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
