defmodule DevilsDictionary.Installation.Bundle do
  @moduledoc """
  A bundle: one directory that carries a working installation to another
  place (#130, #211 §2).

      MANIFEST.json                 written last (Installation.Manifest)
      db/<database>.dump            pg_dump custom format, owners and grants kept
      db/<database>.state.json      the state the dump holds (Installation.State)
      inputs/data/…                 archived inputs git does not carry, pinned
                                    by priv/sources/MANIFEST.json
      inputs/priv/replay/…          the replay archive and its manifest

  ## One snapshot, two descriptions

  The dump and the state are taken under **one exported snapshot**: a
  repeatable-read transaction on the source calls `pg_export_snapshot()`,
  then `pg_dump --snapshot` and `State.capture(snapshot: …)` run at the same
  time inside it. Whatever else happens on the source, the state describes
  exactly the rows the dump contains. The manifest records the dump's size
  and SHA-256 and the state file's, so the binding survives the copy.

  ## Quiet, and proven quiet

  An installation capture is the baseline a move is compared against, so
  it refuses a source with other sessions connected, and records before and
  after it the source's write counters (`Database.write_counters/1`) and its
  sequence and catalog fingerprint (`Database.window_fingerprint/1`):
  sequence values and catalog definitions are not read under a snapshot,
  and a `nextval` that writes no row moves no counter. The manifest says
  whether the window was quiet; `require_quiet: true` (the default) refuses
  to finish a bundle whose window was not, and never reuses an earlier
  capture that was not.

  ## What it never does

  It never writes to the source: every source session is read-only. It
  never reads `.env`. It never overwrites a finished bundle, and never
  creates its directory anywhere but on the volume it was told to use
  (`Installation.Volume`).

  ## Resuming

  An interrupted capture leaves no `MANIFEST.json`. Running again reuses a
  completed database capture only while the source is provably unchanged
  since (same server, same write counters, nobody connected), and resumes
  each input copy from its partial file (`Installation.Files.copy/3`).
  """

  alias DevilsDictionary.Installation.{Database, Files, Manifest, State, Volume}
  alias DevilsDictionary.Snapshot

  @capture "db/capture.json"

  @doc """
  Creates a bundle of `opts[:source]` (a database name on the configured
  server, or an `ecto://` URL) in `opts[:out]`.

  Options:

    * `:source`, `:out`, `:volume` (mount point) — required;
    * `:uuid` — the volume's expected UUID;
    * `:root` — the checkout whose inputs are bundled (default `"."`);
    * `:inputs` — bundle the archived inputs and the replay archive
      (default `true`);
    * `:models_root` — inventory the pinned model artifacts there;
    * `:require_quiet` — default `true`;
    * `:log` — `fun(line)` for progress.

  Returns `{:ok, %{manifest, digest, path}}` or `{:error, message}`.
  """
  def create(opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    out = Path.expand(Keyword.fetch!(opts, :out))
    source = Keyword.fetch!(opts, :source)
    root = Path.expand(Keyword.get(opts, :root, "."))

    with {:ok, config} <- Database.resolve(source),
         :ok <- not_finished(out),
         {:ok, facts} <- source_facts(config),
         {:ok, roles} <- Database.roles(config),
         facts = Map.put(facts, :roles, roles),
         {:ok, tools} <- tools(facts.server),
         estimate = estimate(facts, root, opts),
         {:ok, volume} <-
           Volume.check(out, Keyword.fetch!(opts, :volume),
             uuid: opts[:uuid],
             need_bytes: estimate,
             probe: Keyword.get(opts, :probe, &Volume.probe/1)
           ),
         :ok <- mkdir(Path.join(out, "db")),
         {:ok, capture} <- capture(config, source, out, facts, opts, log),
         {:ok, inputs} <- inputs(root, out, opts, log),
         {:ok, models} <- models(opts[:models_root]) do
      manifest =
        build(capture, inputs, models, facts, tools, root, volume)

      log.("writing #{Manifest.path(out)}")
      digest = Manifest.write!(out, manifest)
      File.rm(Path.join(out, @capture))
      {:ok, %{manifest: manifest, digest: digest, path: out}}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp not_finished(out) do
    if File.exists?(Manifest.path(out)),
      do:
        {:error,
         "#{out} already holds a finished bundle; a bundle is never overwritten. Choose a new directory"},
      else: :ok
  end

  defp source_facts(config) do
    case Database.facts(config) do
      {:ok, %{database: nil}} ->
        {:error, "#{Database.describe(config)} does not exist"}

      {:ok, facts} ->
        {:ok, facts}

      {:error, reason} ->
        {:error, "#{Database.describe(config)}: #{reason}"}
    end
  end

  @doc """
  The PostgreSQL client tools on PATH and their versions:
  `{:ok, %{"pg_dump" => "18.2", "pg_restore" => "18.2"}}`, refused when
  either is missing or older than the server's major version.
  """
  def tools(server) do
    found =
      for tool <- ~w(pg_dump pg_restore), into: %{} do
        {tool, tool_version(tool)}
      end

    cond do
      Enum.any?(found, fn {_tool, v} -> is_nil(v) end) ->
        missing = for {tool, nil} <- found, do: tool
        {:error, "#{Enum.join(missing, " and ")} not found on PATH"}

      Enum.any?(found, fn {_tool, v} -> major(v) < server.major end) ->
        {:error,
         "pg_dump/pg_restore #{inspect(found)} are older than the server (major #{server.major})"}

      true ->
        {:ok, found}
    end
  end

  @doc "A PostgreSQL tool's version (`\"18.2\"`), or nil if it is not on PATH."
  def tool_version(tool) do
    with path when is_binary(path) <- System.find_executable(tool),
         {out, 0} <- System.cmd(path, ["--version"], stderr_to_stdout: true),
         [_, version] <- Regex.run(~r/\(PostgreSQL\)\s+(\d+(?:\.\d+)?)/, out) do
      version
    else
      _ -> nil
    end
  end

  @doc "The major version of `\"18.2\"`."
  def major(version) do
    {major, _} = Integer.parse(version)
    major
  end

  # A custom-format dump is about a tenth of the database; inputs are
  # copied whole. Twice the dump for headroom.
  defp estimate(facts, root, opts) do
    dump = div(database_bytes(facts), 5)

    inputs =
      if Keyword.get(opts, :inputs, true),
        do: Enum.sum(for entry <- input_entries(root), do: entry["bytes"]),
        else: 0

    dump + inputs + 1_073_741_824
  end

  defp database_bytes(%{database_bytes: bytes}) when is_integer(bytes), do: bytes
  defp database_bytes(_facts), do: 0

  # ── the database capture ─────────────────────────────────────────────────

  defp capture(config, source, out, facts, opts, log) do
    database = facts.database["name"]
    dump = Path.join(out, "db/#{database}.dump")
    state = Path.join(out, "db/#{database}.state.json")
    require_quiet? = Keyword.get(opts, :require_quiet, true)

    case reusable(out, facts, config, require_quiet?) do
      {:ok, recorded} ->
        log.("reusing the completed database capture: the source is unchanged since")
        {:ok, recorded}

      :none ->
        fresh_capture(config, source, dump, state, facts, require_quiet?, log)
    end
  end

  # A completed capture from an interrupted run, still describing the source:
  # the same server and database, a window that meets this run's quiet
  # requirement, nobody connected now, the write counters, sequences and
  # catalog unchanged since, and both files still the ones recorded.
  defp reusable(out, facts, config, require_quiet?) do
    with {:ok, json} <- File.read(Path.join(out, @capture)),
         {:ok, recorded} <- Jason.decode(json),
         true <- recorded["source"]["system_identifier"] == facts.server.system_identifier,
         true <- recorded["source"]["database_oid"] == facts.database["oid"],
         true <- recorded["quiescence"]["quiet"] == true or not require_quiet?,
         {:ok, []} <- Database.connections(config),
         {:ok, window} <- window(config),
         true <- window == recorded["quiescence"]["after"],
         true <-
           Enum.all?(recorded["files"], &(Files.check(Path.join(out, &1["path"]), &1) == :ok)) do
      {:ok, recorded}
    else
      _ -> :none
    end
  end

  # What a quiet window leaves unchanged: the row counters, and the sequences
  # and catalog, which no snapshot covers.
  defp window(config) do
    with {:ok, counters} <- Database.write_counters(config),
         {:ok, fingerprint} <- Database.window_fingerprint(config) do
      {:ok, %{"counters" => counters, "fingerprint" => fingerprint}}
    end
  end

  defp fresh_capture(config, source, dump, state_path, facts, require_quiet?, log) do
    with {:ok, before_connections} <- Database.connections(config),
         :ok <- quiet_start(before_connections, require_quiet?, config),
         {:ok, before} <- window(config) do
      log.("capturing #{Database.describe(config)} under one exported snapshot")
      started = System.monotonic_time(:millisecond)
      File.rm(dump <> ".partial")

      case dump_and_state(config, source, dump <> ".partial") do
        {:ok, {state, snapshot_id}} ->
          File.rename!(dump <> ".partial", dump)

          finish_capture(config, dump, state_path, facts, state, snapshot_id, started, %{
            before_connections: before_connections,
            before: before,
            require_quiet?: require_quiet?,
            log: log
          })

        {:error, message} ->
          File.rm(dump <> ".partial")
          {:error, "the capture of #{Database.describe(config)} failed: #{message}"}
      end
    end
  end

  defp finish_capture(config, dump, state_path, facts, state, snapshot_id, started, context) do
    %{
      before_connections: before_connections,
      before: before,
      require_quiet?: require_quiet?,
      log: log
    } =
      context

    Files.write_atomic!(state_path, Jason.encode_to_iodata!(state, pretty: true))

    with {:ok, after_connections} <- settled_connections(config),
         {:ok, after_window} <- window(config) do
      quiet? = before == after_window and after_connections == []
      elapsed = System.monotonic_time(:millisecond) - started
      log.("captured in #{div(elapsed, 1000)} s; window quiet: #{quiet?}")

      out = Path.dirname(Path.dirname(dump))

      recorded = %{
        "source" => %{
          "system_identifier" => facts.server.system_identifier,
          "database" => facts.database["name"],
          "database_oid" => facts.database["oid"],
          "endpoint" => Database.describe(config),
          "server_version" => facts.server.version,
          "server_version_num" => facts.server.version_num,
          "data_directory" => facts.server.data_directory,
          "database_bytes" => database_bytes(facts)
        },
        "snapshot" => snapshot_id,
        "elapsed_ms" => elapsed,
        "quiescence" => %{
          "connections_at_start" => before_connections,
          "connections_at_end" => after_connections,
          "before" => before,
          "after" => after_window,
          "counters_before" => before["counters"],
          "counters_after" => after_window["counters"],
          "quiet" => quiet?
        },
        "state" => %{"migrations" => state["migrations"], "database" => state["database"]},
        "files" => [
          entry(out, dump, "dump", %{"database" => facts.database["name"]}),
          entry(out, state_path, "state", %{"database" => facts.database["name"]})
        ]
      }

      if not quiet? and require_quiet? do
        {:error,
         "the source was written, altered or connected to during the capture " <>
           "(counters #{inspect(before["counters"])} → #{inspect(after_window["counters"])}, " <>
           "sequences or catalog #{if before["fingerprint"] == after_window["fingerprint"], do: "unchanged", else: "CHANGED"}, " <>
           "#{length(after_connections)} sessions at the end). The files are left in " <>
           "#{out}/db, but no manifest vouches for them. Quiesce the writers and run again"}
      else
        Files.write_atomic!(Path.join(out, @capture), Jason.encode_to_iodata!(recorded))
        {:ok, recorded}
      end
    else
      {:error, reason} -> {:error, "after the capture, the source cannot be read: #{reason}"}
    end
  end

  # The capture's own sessions have just disconnected, and a backend can
  # outlive its client by a few milliseconds. Anything still there after a
  # second is someone else's.
  defp settled_connections(config, tries \\ 10) do
    case Database.connections(config) do
      {:ok, [_ | _]} when tries > 1 ->
        Process.sleep(100)
        settled_connections(config, tries - 1)

      result ->
        result
    end
  end

  defp quiet_start([], _require_quiet?, _config), do: :ok
  defp quiet_start(_connections, false, _config), do: :ok

  defp quiet_start(connections, true, config) do
    sessions =
      Enum.map_join(connections, "\n", fn c ->
        "  pid #{c["pid"]} #{c["application"]} from #{c["client"]} (#{c["state"]}, since #{c["backend_start"]})"
      end)

    {:error,
     "refusing to capture #{Database.describe(config)}: other sessions are connected.\n" <>
       sessions <>
       "\nStop them through their owners (docs/operations/installation.md, quiescence) and run again."}
  end

  # The exporting transaction stays open until both readers are done; they
  # import its snapshot, so neither sees anything the other does not.
  defp dump_and_state(config, source, partial) do
    connection =
      config
      |> Snapshot.maintenance()
      |> Keyword.put(:database, config[:database])

    Snapshot.probe(
      connection,
      fn conn ->
        {:ok, result} =
          Postgrex.transaction(
            conn,
            fn conn ->
              Postgrex.query!(
                conn,
                "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
                []
              )

              %{rows: [[id]]} = Postgrex.query!(conn, "SELECT pg_export_snapshot()", [])
              dump = Task.async(fn -> pg_dump!(config, id, partial) end)
              state = State.capture(source, snapshot: id)
              :ok = Task.await(dump, :infinity)
              {state, id}
            end,
            timeout: :infinity
          )

        result
      end,
      :timer.hours(12)
    )
  end

  # Owners and privileges are kept: an installation restore recreates them
  # as recorded, as a superuser, rather than handing every object to the
  # restoring role.
  defp pg_dump!(config, snapshot, path) do
    binary = System.find_executable("pg_dump") || raise "pg_dump is not on PATH"

    args =
      Snapshot.connection_args(config) ++
        [
          "--format=custom",
          "--compress=6",
          "--snapshot=#{snapshot}",
          "--file=#{path}",
          config[:database]
        ]

    env = [{"PGPASSWORD", to_string(config[:password] || "")}]

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "pg_dump exited with #{status}: #{out}"
    end
  end

  defp entry(out, path, role, extra) do
    Map.merge(
      %{"path" => Path.relative_to(path, out), "role" => role},
      Map.merge(Files.fingerprint(path), extra)
    )
  end

  # ── inputs ───────────────────────────────────────────────────────────────

  # The archived inputs git does not carry (`committed: false` in
  # priv/sources/MANIFEST.json), and the replay archive, each by its pin.
  @doc false
  def input_entries(root) do
    sources =
      for input <- read_json!(Path.join(root, "priv/sources/MANIFEST.json"))["inputs"],
          input["committed"] == false,
          is_binary(input["sha256"]) do
        %{
          "locator" => input["archive_locator"],
          "role" => "input",
          "bytes" => input["byte_count"],
          "sha256" => input["sha256"],
          "pinned_by" => "priv/sources/MANIFEST.json"
        }
      end

    replay_manifest = Path.join(root, "priv/replay/MANIFEST.json")

    replay =
      for file <- read_json!(replay_manifest)["files"] do
        %{
          "locator" => Path.join("priv/replay", file["file"]),
          "role" => "replay",
          "bytes" => file["byte_count"],
          "sha256" => file["sha256"],
          "pinned_by" => "priv/replay/MANIFEST.json"
        }
      end

    sources ++
      replay ++
      [
        Map.merge(
          %{
            "locator" => "priv/replay/MANIFEST.json",
            "role" => "replay-manifest",
            "pinned_by" => "git"
          },
          Files.fingerprint(replay_manifest)
        )
      ]
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp inputs(root, out, opts, log) do
    if Keyword.get(opts, :inputs, true) do
      root |> input_entries() |> copy_inputs(root, out, log)
    else
      {:ok, []}
    end
  end

  defp copy_inputs(entries, root, out, log) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      source = Path.join(root, entry["locator"])
      relative = Path.join("inputs", entry["locator"])
      expected = Map.take(entry, ~w(bytes sha256))

      # The source is checked against its pin before it is copied: a
      # damaged input is reported here, not discovered after a restore.
      with :ok <- pinned(source, expected, entry),
           {:ok, how} <- Files.copy(source, Path.join(out, relative), expected) do
        log.("#{entry["locator"]}: #{how}")

        listed =
          entry
          |> Map.drop(["locator"])
          |> Map.merge(%{"path" => relative, "locator" => entry["locator"]})

        {:cont, {:ok, [listed | acc]}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp pinned(source, expected, entry) do
    case Files.check(source, expected) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "#{entry["locator"]} is not the input #{entry["pinned_by"]} pins " <>
           "(#{Files.describe(reason)}); nothing more was copied"}
    end
  end

  # ── models ───────────────────────────────────────────────────────────────

  # An inventory, not a copy: the weights are already on the external
  # volume, and a blob's file name is its digest (`sha256-<hex>`).
  defp models(nil), do: {:ok, nil}

  defp models(root) do
    root = Path.expand(root)

    if File.dir?(root) do
      files =
        root
        |> Path.join("{manifests,blobs}/**")
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()
        |> Enum.map(fn path ->
          relative = Path.relative_to(path, root)
          size = File.stat!(path).size

          digest =
            case Regex.run(~r/sha256-([0-9a-f]{64})$/, path) do
              [_, hex] -> %{"sha256" => hex, "digest_from" => "file name"}
              nil -> %{"sha256" => Files.sha256(path), "digest_from" => "content"}
            end

          Map.merge(%{"path" => relative, "bytes" => size}, digest)
        end)

      {:ok, %{"root" => root, "copied" => false, "files" => files}}
    else
      {:error, "models root #{root} is not a directory"}
    end
  end

  # ── the manifest ─────────────────────────────────────────────────────────

  defp build(capture, inputs, models, facts, tools, root, volume) do
    %{
      "format" => Manifest.format(),
      "kind" => "installation",
      "privacy" =>
        "PRIVATE. A full working database: never publish or share it. " <>
          "Credentials (.env) are not in it.",
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "code" => code(root),
      "tool" => code(File.cwd!()),
      "toolchain" =>
        Map.merge(tools, %{
          "elixir" => System.version(),
          "otp" => System.otp_release()
        }),
      "source" => capture["source"],
      "snapshot" => capture["snapshot"],
      "database" => capture["state"]["database"],
      "schema" => %{
        "head" => List.last(capture["state"]["migrations"]),
        "versions" => capture["state"]["migrations"]
      },
      "cluster_roles" => cluster_roles(facts),
      "quiescence" => capture["quiescence"],
      "destination_volume" => Map.take(stringify(volume), ~w(mount_point uuid device)),
      "files" => capture["files"] ++ inputs,
      "models" => models
    }
  end

  defp cluster_roles(%{roles: roles}), do: roles
  defp cluster_roles(_facts), do: []

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp code(root) do
    revision = git(root, ~w(rev-parse HEAD))
    branch = git(root, ~w(rev-parse --abbrev-ref HEAD))
    dirty = git(root, ~w(status --porcelain --untracked-files=no))

    # Unknown, not clean, when git cannot read the root.
    %{
      "revision" => revision,
      "branch" => branch,
      "dirty" => if(revision, do: dirty not in [nil, ""], else: nil)
    }
  end

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # ── verify and transfer ──────────────────────────────────────────────────

  @doc """
  Verifies a finished bundle in place, read-only: the manifest's format,
  every file's size and (with `deep: true`) SHA-256, and that the dump is
  the source database's and holds every table the state describes.

  `{:ok, report}` or `{:error, report}`; `report.rows` per file,
  `report.problems` for everything else.
  """
  def verify(bundle, opts \\ []) do
    bundle = Path.expand(bundle)

    with {:ok, manifest} <- Manifest.read(bundle) do
      {files_ok, rows} = Manifest.verify_files(bundle, manifest, opts)
      problems = if files_ok == :ok, do: dump_problems(bundle, manifest), else: []

      report = %{
        manifest: manifest,
        digest: Manifest.digest(bundle),
        rows: rows,
        problems: problems
      }

      if files_ok == :ok and problems == [], do: {:ok, report}, else: {:error, report}
    else
      {:error, message} -> {:error, %{manifest: nil, digest: nil, rows: [], problems: [message]}}
    end
  end

  defp dump_problems(bundle, manifest) do
    dump = Manifest.file(manifest, "dump")
    state_file = Manifest.file(manifest, "state")

    cond do
      is_nil(dump) or is_nil(state_file) ->
        ["the manifest lists no dump or no state"]

      true ->
        dump_problems(bundle, manifest, dump, state_file)
    end
  end

  # Sizes alone (`deep: false`) can pass a same-size corrupted file, which
  # then fails to parse here: a problem to report, not a crash.
  defp dump_problems(bundle, manifest, dump, state_file) do
    try do
      dump_path = Path.join(bundle, dump["path"])
      state = read_json!(Path.join(bundle, state_file["path"]))
      header = Snapshot.archive_database(dump_path)
      tables = Snapshot.tables(dump_path)
      expected = state["sections"] |> Map.keys() |> Enum.reject(&(&1 in ~w(schema sequences)))

      # A table with rows must have its data in the dump.
      missing =
        for table <- expected,
            state["sections"][table]["count"] > 0,
            not MapSet.member?(tables, table),
            do: table

      [] ++
        if(header == manifest["source"]["database"],
          do: [],
          else: [
            "the dump's header names #{inspect(header)}, the manifest #{manifest["source"]["database"]}"
          ]
        ) ++
        if(missing == [],
          do: [],
          else: ["the dump holds no data for #{Enum.join(Enum.sort(missing), ", ")}"]
        )
    rescue
      error -> ["the dump or the state cannot be read: #{Exception.message(error)}"]
    end
  end

  @doc """
  Copies a finished bundle to `out`, resuming any partial file, and writes
  the manifest there last, so the copy is a bundle only once every file is
  verified. `out` must be on the external volume `volume:` names, or, with
  `internal: true`, on an internal volume apart from the bundle and outside
  every checkout (`Volume.check_internal/2`): the second copy that outlives
  the external drive (#211 D14).
  """
  def transfer(from, out, opts) do
    from = Path.expand(from)
    out = Path.expand(out)
    log = Keyword.get(opts, :log, fn _ -> :ok end)

    with {:ok, manifest} <- Manifest.read(from),
         :ok <- digest_pinned(from, opts[:expect_manifest_sha256]),
         :ok <- Manifest.confined(manifest),
         :ok <- not_finished(out),
         {:ok, _volume} <- destination(from, out, manifest, opts),
         :ok <- copy_all(manifest, from, out, log),
         {:ok, _rows} <- copied(out, manifest) do
      # Last, and only once every file it lists is in place and verified.
      Files.write_atomic!(Manifest.path(out), File.read!(Manifest.path(from)))

      case verify(out) do
        {:ok, report} ->
          {:ok, report}

        {:error, report} ->
          {:error,
           "the copy at #{out} does not verify: #{inspect(report.problems ++ failed(report.rows))}"}
      end
    end
  end

  defp destination(from, out, manifest, opts) do
    need = remaining(manifest, out)
    probe = Keyword.get(opts, :probe, &Volume.probe/1)

    if opts[:internal] do
      Volume.check_internal(out,
        apart_from: from,
        need_bytes: need,
        probe: probe,
        stat: Keyword.get(opts, :stat, &File.stat/1)
      )
    else
      Volume.check(out, Keyword.fetch!(opts, :volume),
        uuid: opts[:uuid],
        need_bytes: need,
        probe: probe
      )
    end
  end

  defp failed(rows), do: for(%{status: :failed} = row <- rows, do: "#{row.path}: #{row.detail}")

  defp copied(out, manifest) do
    case Manifest.verify_files(out, manifest) do
      {:ok, rows} -> {:ok, rows}
      {:error, rows} -> {:error, "the copy at #{out} does not verify: #{inspect(failed(rows))}"}
    end
  end

  # What a resumed transfer still has to write: files already in place, and
  # the part of a file already copied, need no more room.
  defp remaining(manifest, out) do
    manifest["files"]
    |> Enum.map(fn entry ->
      dest = Path.join(out, entry["path"])

      have =
        case {File.stat(dest), File.stat(dest <> ".partial")} do
          {{:ok, %{size: size}}, _} -> size
          {_, {:ok, %{size: size}}} -> size
          _ -> 0
        end

      max(entry["bytes"] - have, 0)
    end)
    |> Enum.sum()
  end

  defp copy_all(manifest, from, out, log) do
    Enum.reduce_while(manifest["files"], :ok, fn entry, :ok ->
      expected = Map.take(entry, ~w(bytes sha256))

      case Files.copy(Path.join(from, entry["path"]), Path.join(out, entry["path"]), expected) do
        {:ok, how} ->
          log.("#{entry["path"]}: #{how}")
          {:cont, :ok}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  @doc "`:ok` when no digest is pinned or the manifest has it."
  def digest_pinned(_bundle, nil), do: :ok

  def digest_pinned(bundle, expected) do
    actual = Manifest.digest(bundle)

    if String.downcase(expected) == actual,
      do: :ok,
      else:
        {:error,
         "#{Manifest.path(bundle)} has SHA-256 #{actual}, not the approved #{expected}: " <>
           "this is not the approved bundle"}
  end
end
