defmodule DevilsDictionary.Installation.Bootstrap do
  @moduledoc """
  Sets up a database from a bundle, in one of three explicit modes (#211 §2):

    * `:restore` — **restore this exact installation**: the migration path.
      The target is a database of the same name on **another cluster**,
      named by its `system_identifier` (`target_cluster:`), and the result
      must equal the captured state in every section, roles included.
    * `:init` — **initialise a new development installation** from an
      approved bundle: any `devils_dictionary*` name on any server, the
      source excepted. The same exact comparison, the name aside.
    * `:rebuild` — **rebuild from pinned inputs**: checks and places the
      archived inputs and prints the `mix dd.rebuild` commands for an empty
      target. It restores nothing; a rebuild renumbers every registry
      object, so it never stands in for a restore (ADR 0004 §8).

  ## Everything is checked before anything is written

  Before the first statement that changes anything, a restore or init has:

    * read the manifest and, when `expect_manifest_sha256:` is given (always
      for `:restore` and `:init` through the task), matched its digest;
    * verified every file's size and SHA-256, and that the dump is the
      source's and holds every table with rows;
    * read the target server's identity over the endpoint `pg_restore`
      will use, and refused **the source itself** (same cluster, same name
      or oid), a cluster other than the pinned one, a mismatched major
      version, an older `pg_restore`, a different ICU collation version, a
      missing extension version, a missing or different role, a connecting
      role that is not a superuser, and a volume without room;
    * found the target database absent. A target that exists is compared
      with the bundle: the same state is reported as already restored and
      left alone; anything else, even an empty database, is refused and
      left as it was.

  ## Restoring

  The restore goes into a **staging database** (`<target>_dd_rs`), created
  from `template0` with the recorded encoding, locale and owner, and
  commented with a marker naming this bundle at once. `pg_restore` restores
  owners and privileges as recorded; the database-level settings,
  connection limit and privileges are applied; and the staging database's
  state is captured and compared with the bundle's. Only when nothing
  differs — the name, and the marker standing in for the comment, aside —
  is the staging database renamed to the target, and then given the
  recorded comment.

  So the target name only ever holds a verified database. A run interrupted
  before the rename leaves the marked staging database, which the next run
  drops and restores again; one interrupted between the rename and the
  comment leaves the target in the bundle's state with the marker, which
  the next run finishes. A staging database without this bundle's marker is
  someone else's and is refused. Nothing else is ever dropped. An advisory
  lock on the target server keeps a second bootstrap of the same target
  from running at the same time.

  No migration is applied: migrating is a separate, recorded step after the
  restore is accepted (#211 §4).
  """

  alias DevilsDictionary.Installation.{Bundle, Database, Files, Manifest, State, Volume}
  alias DevilsDictionary.Snapshot

  @suffix "_dd_rs"

  @doc "The staging database a restore into `name` uses."
  def staging_name(name), do: name <> @suffix

  @doc """
  Runs `mode` (`:restore`, `:init` or `:rebuild`). Options:

    * `:bundle` (required), `:target` (a name on the configured server, or
      an `ecto://` URL);
    * `:target_cluster` — the target server's `system_identifier`
      (required for `:restore`);
    * `:expect_manifest_sha256` — the approved manifest's digest;
    * `:volume`, `:uuid` — the mounted external volume the target server's
      data directory, and any placed inputs, must be on (required for
      `:restore`);
    * `:jobs` — parallel `pg_restore` workers (default 4);
    * `:place_inputs` — a checkout root to copy the bundle's inputs into;
    * `:report` — a path to write the JSON report to;
    * `:log` — `fun(line)` for progress.

  Returns `{:ok, report}` or `{:error, message}`.
  """
  def run(mode, opts) when mode in [:restore, :init] do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    bundle = Path.expand(Keyword.fetch!(opts, :bundle))
    target = Keyword.fetch!(opts, :target)
    started = System.monotonic_time(:millisecond)

    with {:ok, config} <- Database.resolve(target),
         name = config[:database],
         staging = staging_name(name),
         :ok <- Database.check_name(name),
         :ok <- Database.check_name(staging),
         :ok <- required(mode, opts),
         :ok <- report_free(opts[:report]),
         {:ok, manifest} <- Manifest.read(bundle),
         :ok <- Bundle.digest_pinned(bundle, opts[:expect_manifest_sha256]),
         :ok <- installation_bundle(manifest),
         :ok <- Manifest.confined(manifest),
         _ = log.("verifying every file in #{bundle}"),
         :ok <- verified(bundle),
         {:ok, state} <- read_state(bundle, manifest),
         {:ok, facts} <- target_facts(config, manifest),
         :ok <- cluster_pinned(facts, opts[:target_cluster]),
         :ok <- not_the_source(mode, manifest, facts, name),
         :ok <- same_name(mode, manifest, name),
         :ok <- compatible(manifest, facts),
         :ok <- superuser(config),
         :ok <- extensions_available(state, config),
         :ok <- roles_present(mode, manifest, state, config),
         :ok <- placeable(bundle, manifest, opts) do
      # One bootstrap per target at a time: a second one waits for nothing
      # and changes nothing.
      Database.with_lock(config, name, fn ->
        with {:ok, outcome} <-
               settle(mode, bundle, manifest, state, target, config, staging, opts, log),
             {:ok, placed} <- place(bundle, manifest, opts, log) do
          report(opts, %{
            mode: mode,
            outcome: outcome.outcome,
            bundle: bundle,
            manifest_sha256: Manifest.digest(bundle),
            target: Database.describe(config),
            target_cluster: facts.server.system_identifier,
            database: name,
            database_oid: outcome[:oid],
            differences: [],
            placed_inputs: placed,
            pending_migrations: pending(state),
            elapsed_ms: System.monotonic_time(:millisecond) - started
          })
        end
      end)
    end
  end

  def run(:rebuild, opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    bundle = opts[:bundle] && Path.expand(opts[:bundle])
    target = Keyword.fetch!(opts, :target)

    with {:ok, config} <- Database.resolve(target),
         name = config[:database],
         :ok <- Database.check_name(name),
         :ok <- report_free(opts[:report]),
         {:ok, inputs_root} <- inputs_root(bundle, opts),
         {:ok, rows} <- pinned_inputs(inputs_root),
         {:ok, facts} <- target_facts(config, nil),
         :ok <- empty_target(config, facts),
         {:ok, placed} <- place_rebuild(inputs_root, opts, log) do
      report(opts, %{
        mode: :rebuild,
        outcome: :ready_to_rebuild,
        inputs: rows,
        placed_inputs: placed,
        target: Database.describe(config),
        database: name,
        commands: rebuild_commands(config),
        note:
          "A rebuild renumbers every registry object; it is not a restore and cannot " <>
            "reproduce routing or curation state (ADR 0004 §8)."
      })
    end
  end

  # Under the lock, what the target name holds decides what happens: nothing
  # yet (restore, if there is room), this bundle's state (left alone), this
  # bundle's state still carrying the staging marker (a run interrupted
  # between its rename and its comment: finish it), or anything else
  # (refused).
  defp settle(mode, bundle, manifest, state, target, config, staging, opts, log) do
    marker = marker(bundle, config[:database])

    with {:ok, facts} <- target_facts(config, manifest),
         {:ok, existing} <- existing(target, facts, state, marker, log) do
      case existing do
        :same ->
          log.("#{Database.describe(config)} already holds this bundle's state; nothing restored")

          {:ok,
           %{outcome: :already_restored, database: config[:database], oid: facts.database["oid"]}}

        :marked ->
          log.("#{Database.describe(config)} is restored but still marked; finishing it")
          Database.set_comment!(config, config[:database], manifest["database"]["comment"])
          finished(config, facts.database["oid"], manifest)

        :absent ->
          with :ok <- room(opts, facts, manifest) do
            restore(mode, bundle, manifest, state, target, config, staging, marker, opts, log)
          end
      end
    end
  end

  # ── checks ───────────────────────────────────────────────────────────────

  defp required(:restore, opts) do
    missing =
      for key <- [:target_cluster, :volume, :expect_manifest_sha256], is_nil(opts[key]), do: key

    if missing == [],
      do: :ok,
      else: {:error, "--mode restore requires #{Enum.map_join(missing, ", ", &flag/1)}"}
  end

  defp required(:init, opts) do
    if opts[:expect_manifest_sha256],
      do: :ok,
      else:
        {:error, "--mode init requires --expect-manifest-sha256 (the approved bundle's digest)"}
  end

  defp flag(key), do: "--" <> String.replace(to_string(key), "_", "-")

  defp installation_bundle(%{"kind" => "installation"}), do: :ok

  defp installation_bundle(manifest),
    do: {:error, "the bundle is of kind #{inspect(manifest["kind"])}, not an installation"}

  defp verified(bundle) do
    case Bundle.verify(bundle, deep: true) do
      {:ok, _report} ->
        :ok

      {:error, report} ->
        failures =
          for(%{status: :failed} = row <- report.rows, do: "#{row.path}: #{row.detail}") ++
            report.problems

        {:error,
         "the bundle does not verify; nothing was changed:\n  " <> Enum.join(failures, "\n  ")}
    end
  end

  defp read_state(bundle, manifest) do
    path = Path.join(bundle, Manifest.file(manifest, "state")["path"])

    case path |> File.read!() |> Jason.decode() do
      {:ok, %{} = state} -> {:ok, state}
      _ -> {:error, "#{path} is not a captured state"}
    end
  end

  defp report_free(nil), do: :ok

  defp report_free(path) do
    if File.exists?(Path.expand(path)),
      do: {:error, "#{path} already exists; a report never overwrites a file"},
      else: :ok
  end

  # The ICU version is read for the bundle's own locale.
  defp target_facts(config, manifest) do
    locale = (manifest && manifest["database"]["locale"]) || "en-US"

    case Database.facts(config, icu_locale: locale) do
      {:ok, facts} ->
        {:ok, facts}

      {:error, reason} ->
        {:error, "the target server #{Database.describe(config)} cannot be read: #{reason}"}
    end
  end

  defp cluster_pinned(_facts, nil), do: :ok

  defp cluster_pinned(%{server: %{system_identifier: id}}, id), do: :ok

  defp cluster_pinned(%{server: server}, expected),
    do:
      {:error,
       "the target endpoint reaches cluster #{server.system_identifier} " <>
         "(data directory #{server.data_directory}), not the pinned #{expected}"}

  # The source is never a target, however it is reached: the same cluster,
  # with the same name or the same oid. A restore of the installation must
  # land on another cluster altogether.
  defp not_the_source(mode, manifest, facts, name) do
    source = manifest["source"]
    same_cluster? = source["system_identifier"] == facts.server.system_identifier

    source_db? =
      same_cluster? and
        (source["database"] == name or
           (facts.database && facts.database["oid"] == source["database_oid"]))

    cond do
      source_db? ->
        {:error,
         "refusing: the target is the bundle's source database #{source["database"]} " <>
           "(cluster #{source["system_identifier"]}). Nothing was changed"}

      mode == :restore and same_cluster? ->
        {:error,
         "refusing: --mode restore moves the installation to another cluster, and the target " <>
           "is on the source's own cluster #{source["system_identifier"]}"}

      true ->
        :ok
    end
  end

  defp same_name(:restore, %{"source" => %{"database" => name}}, name), do: :ok

  defp same_name(:restore, manifest, name),
    do:
      {:error,
       "--mode restore keeps the database's name: the target must be " <>
         "#{manifest["source"]["database"]}, not #{name} (use --mode init for another name)"}

  defp same_name(:init, _manifest, _name), do: :ok

  defp compatible(manifest, facts) do
    source_major = div(manifest["source"]["server_version_num"], 10_000)
    dumped_with = manifest["toolchain"]["pg_dump"]
    pg_restore = Bundle.tool_version("pg_restore")
    recorded_icu = manifest["database"]["actual_collation_version"]

    cond do
      facts.server.major != source_major ->
        {:error,
         "the target server is PostgreSQL #{facts.server.major}; the bundle was captured from " <>
           "#{source_major}. Use the same major version"}

      is_nil(pg_restore) ->
        {:error, "pg_restore is not on PATH"}

      Bundle.major(pg_restore) < Bundle.major(dumped_with) ->
        {:error,
         "pg_restore #{pg_restore} is older than the pg_dump #{dumped_with} that wrote the dump"}

      manifest["database"]["locale_provider"] == "i" and facts.server.icu_version != recorded_icu ->
        {:error,
         "the target's ICU collation version is #{inspect(facts.server.icu_version)}, the " <>
           "source's #{recorded_icu}. Text indexes would be built under another collation; " <>
           "use the same PostgreSQL build, or decide on a reindex explicitly"}

      true ->
        :ok
    end
  end

  defp superuser(config) do
    result =
      Snapshot.probe(Snapshot.maintenance(config), fn conn ->
        %{rows: [[user, su]]} =
          Postgrex.query!(
            conn,
            "SELECT current_user::text, rolsuper FROM pg_roles WHERE rolname = current_user",
            []
          )

        {user, su}
      end)

    case result do
      {:ok, {_user, true}} ->
        :ok

      {:ok, {user, false}} ->
        {:error,
         "#{user} is not a superuser; restoring owners and privileges as recorded needs one"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `pg_dump` writes `CREATE EXTENSION` without a version, so the restore
  # installs the server's default: that default must be the recorded one.
  defp extensions_available(state, config) do
    with {:ok, defaults} <- Database.default_extensions(config) do
      wrong =
        for %{"name" => name, "version" => version} <- state["extensions"],
            Map.get(defaults, name) != version,
            do:
              "#{name} #{version} (the server would install #{inspect(Map.get(defaults, name))})"

      if wrong == [],
        do: :ok,
        else: {:error, "the target server cannot restore #{Enum.join(wrong, ", ")}"}
    end
  end

  # Every role the database references, with the same attributes; for a
  # restore, every role of the source cluster too.
  defp roles_present(mode, manifest, state, config) do
    with {:ok, roles} <- Database.roles(config) do
      present = Map.new(roles, &{&1["name"], &1})

      wanted =
        if mode == :restore, do: manifest["cluster_roles"] ++ state["roles"], else: state["roles"]

      problems =
        wanted
        |> Enum.uniq_by(& &1["name"])
        |> Enum.flat_map(fn role ->
          case Map.get(present, role["name"]) do
            nil ->
              ["role #{role["name"]} does not exist"]

            ^role ->
              []

            other ->
              ["role #{role["name"]} differs: #{inspect(other)}, expected #{inspect(role)}"]
          end
        end)

      if problems == [],
        do: :ok,
        else:
          {:error,
           "the target cluster's roles do not match (create them with `mix dd.bootstrap.cluster`, " <>
             "or deliberately):\n  " <> Enum.join(problems, "\n  ")}
    end
  end

  # The target server's data directory must be on the external volume, with
  # room for the restored database.
  defp room(opts, facts, manifest) do
    case opts[:volume] do
      nil ->
        :ok

      mount_point ->
        need = div(manifest["source"]["database_bytes"] * 11, 10)

        case Volume.check(facts.server.data_directory, mount_point,
               uuid: opts[:uuid],
               need_bytes: need,
               probe: Keyword.get(opts, :probe, &Volume.probe/1)
             ) do
          {:ok, _volume} -> :ok
          {:error, message} -> {:error, "the target server's data directory: " <> message}
        end
    end
  end

  # What the target name holds now: nothing, exactly the bundle's state, or
  # that state still carrying this bundle's staging marker.
  defp existing(_target, %{database: nil}, _state, _marker, _log), do: {:ok, :absent}

  defp existing(target, facts, state, marker, log) do
    name = facts.database["name"]
    log.("#{name} exists; comparing it with the bundle")

    case Database.populated?(Database.config(target)) do
      {:ok, false} ->
        {:error,
         "#{name} exists and is empty. A bootstrap creates its own database with the recorded " <>
           "locale and owner; drop this one deliberately or choose another name"}

      {:ok, true} ->
        compare_existing(target, name, state, marker)

      {:error, reason} ->
        {:error, "#{name} cannot be read: #{reason}"}
    end
  end

  defp compare_existing(target, name, state, marker) do
    differences = State.diff(state, State.capture(target), ignore: [:name])

    cond do
      differences == [] ->
        {:ok, :same}

      without_marker(differences, marker) == [] ->
        {:ok, :marked}

      true ->
        {:error,
         "#{name} already exists with other contents; nothing was changed.\n  " <>
           (differences |> Enum.take(20) |> Enum.map_join("\n  ", &State.describe/1))}
    end
  rescue
    error -> {:error, "#{name} cannot be compared with the bundle: #{Exception.message(error)}"}
  end

  # ── restoring ────────────────────────────────────────────────────────────

  defp restore(_mode, bundle, manifest, state, target, config, staging, marker, opts, log) do
    staging_target = retarget(target, staging)

    with :ok <- clear_staging(config, staging, marker, log) do
      log.("creating #{staging} (staging) from template0")
      Database.create!(config, staging, manifest["database"], marker)
      dump = Path.join(bundle, Manifest.file(manifest, "dump")["path"])
      log.("pg_restore into #{staging}")
      :ok = pg_restore!(Keyword.put(config, :database, staging), dump, opts[:jobs] || 4)

      Database.apply_properties!(
        config,
        staging,
        Map.put(manifest["database"], "comment", marker)
      )

      log.("comparing #{staging} with the bundle's captured state")
      actual = State.capture(staging_target)

      case State.diff(state, actual, ignore: [:name]) |> without_marker(marker) do
        [] ->
          # Renamed first, commented after: a run interrupted between the
          # two leaves the target holding the verified state and the marker,
          # which the next run recognises and finishes.
          Database.rename!(config, staging, config[:database])
          Database.set_comment!(config, config[:database], manifest["database"]["comment"])
          finished(config, actual["database"]["oid"], manifest)

        differences ->
          {:error,
           "#{staging} does not match the bundle; it is left in place, marked, for inspection, " <>
             "and the next run starts it again:\n  " <>
             (differences |> Enum.take(20) |> Enum.map_join("\n  ", &State.describe/1))}
      end
    end
  end

  defp marker(bundle, name),
    do: "dd.bootstrap staging #{String.slice(Manifest.digest(bundle), 0, 16)} for #{name}"

  # The comment is the only difference the marker may make.
  defp without_marker(differences, marker) do
    Enum.reject(differences, &match?(%{section: "database comment", actual: ^marker}, &1))
  end

  defp clear_staging(config, staging, marker, log) do
    case Database.comment(config, staging) do
      {:ok, nil} ->
        # Absent, or present with no comment: only the first is ours to use.
        case Database.facts(Keyword.put(config, :database, staging)) do
          {:ok, %{database: nil}} ->
            :ok

          _ ->
            {:error,
             "#{staging} exists and is not this bootstrap's staging database; nothing was changed"}
        end

      {:ok, ^marker} ->
        log.("#{staging} is this bundle's unfinished staging database; starting it again")
        Database.drop_marked!(config, staging, marker)
        :ok

      {:ok, other} ->
        {:error,
         "#{staging} exists and carries #{inspect(other)}, not this bundle's marker; nothing was changed"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finished(config, oid, manifest) do
    case Database.facts(config) do
      {:ok, %{database: %{"comment" => comment, "oid" => ^oid}}} ->
        if comment == manifest["database"]["comment"],
          do: {:ok, %{outcome: :restored, database: config[:database], oid: oid}},
          else: {:error, "#{config[:database]} is in place but its comment did not apply"}

      other ->
        {:error,
         "#{config[:database]} does not read back as the restored database: #{inspect(other)}"}
    end
  end

  # The same endpoint, another database.
  defp retarget(target, name) do
    if String.contains?(target, "://") do
      uri = URI.parse(target)
      URI.to_string(%{uri | path: "/" <> name})
    else
      name
    end
  end

  defp pg_restore!(config, dump, jobs) do
    binary = System.find_executable("pg_restore") || raise "pg_restore is not on PATH"

    args =
      Snapshot.connection_args(config) ++
        ["--exit-on-error", "--jobs=#{jobs}", "--dbname=#{config[:database]}", dump]

    env = [{"PGPASSWORD", to_string(config[:password] || "")}]

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "pg_restore exited with #{status}: #{out}"
    end
  end

  # ── inputs ───────────────────────────────────────────────────────────────

  @placed ~w(input replay replay-manifest)

  # Everything placement could refuse, checked before the restore: the
  # volume and its room, paths inside the checkout, and no file already
  # there with other contents.
  defp placeable(bundle, manifest, opts) do
    case opts[:place_inputs] do
      nil ->
        :ok

      dir ->
        dir = Path.expand(dir)
        entries = Enum.filter(manifest["files"], &(&1["role"] in @placed))
        need = Enum.sum(for e <- entries, do: e["bytes"])

        with :ok <- placement_volume(dir, need, opts),
             :ok <- conflicts(dir, entries, bundle) do
          :ok
        end
    end
  end

  defp conflicts(dir, entries, _bundle) do
    problems =
      Enum.flat_map(entries, fn entry ->
        dest = Path.join(dir, entry["locator"] || "")

        cond do
          Manifest.inside(entry["locator"]) != :ok ->
            ["#{inspect(entry["locator"])} would be placed outside #{dir}"]

          not File.exists?(dest) ->
            []

          Files.check(dest, Map.take(entry, ~w(bytes sha256))) == :ok ->
            []

          true ->
            ["#{dest} exists with other contents"]
        end
      end)

    if problems == [],
      do: :ok,
      else:
        {:error,
         "the inputs cannot be placed; nothing was changed:\n  " <> Enum.join(problems, "\n  ")}
  end

  defp place(bundle, manifest, opts, log) do
    case opts[:place_inputs] do
      nil ->
        {:ok, []}

      dir ->
        entries = Enum.filter(manifest["files"], &(&1["role"] in @placed))
        copy_into(dir, entries, &Path.join(bundle, &1["path"]), opts, log)
    end
  end

  defp copy_into(dir, entries, source_of, opts, log) do
    dir = Path.expand(dir)
    need = Enum.sum(for e <- entries, do: e["bytes"])

    with :ok <- placement_volume(dir, need, opts) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        dest = Path.join(dir, entry["locator"])

        case Files.copy(source_of.(entry), dest, Map.take(entry, ~w(bytes sha256))) do
          {:ok, how} ->
            log.("#{entry["locator"]}: #{how}")
            {:cont, {:ok, [%{"locator" => entry["locator"], "result" => to_string(how)} | acc]}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp placement_volume(dir, need, opts) do
    case opts[:volume] do
      nil ->
        :ok

      mount_point ->
        case Volume.check(dir, mount_point,
               uuid: opts[:uuid],
               need_bytes: need,
               probe: Keyword.get(opts, :probe, &Volume.probe/1)
             ) do
          {:ok, _} -> :ok
          {:error, message} -> {:error, "placing inputs: " <> message}
        end
    end
  end

  defp inputs_root(nil, opts) do
    case opts[:inputs_from] do
      nil -> {:error, "--mode rebuild needs --bundle or --inputs-from"}
      dir -> {:ok, Path.expand(dir)}
    end
  end

  defp inputs_root(bundle, _opts) do
    with {:ok, _manifest} <- Manifest.read(bundle), do: {:ok, Path.join(bundle, "inputs")}
  end

  # Checked against the pins in this checkout, not against whatever the
  # bundle says: a rebuild reads what the code pins.
  defp pinned_inputs(root) do
    rows =
      for entry <- Bundle.input_entries("."), entry["role"] in ["input", "replay"] do
        status = Files.check(Path.join(root, entry["locator"]), Map.take(entry, ~w(bytes sha256)))
        %{"locator" => entry["locator"], "status" => status_name(status)}
      end

    if Enum.all?(rows, &(&1["status"] == "ok")),
      do: {:ok, rows},
      else:
        {:error,
         "the inputs under #{root} are not the pinned ones: " <>
           Enum.map_join(
             Enum.reject(rows, &(&1["status"] == "ok")),
             ", ",
             &"#{&1["locator"]} #{&1["status"]}"
           )}
  end

  defp status_name(:ok), do: "ok"
  defp status_name({:error, reason}), do: Files.describe(reason)

  defp place_rebuild(root, opts, log) do
    case opts[:place_inputs] do
      nil ->
        {:ok, []}

      dir ->
        entries =
          for e <- Bundle.input_entries("."), e["role"] in ["input", "replay"], do: e

        copy_into(dir, entries, &Path.join(root, &1["locator"]), opts, log)
    end
  end

  defp empty_target(_config, %{database: nil}), do: :ok

  defp empty_target(config, %{database: %{"name" => name}}) do
    case Database.populated?(config) do
      {:ok, false} -> :ok
      _ -> {:error, "#{name} exists and holds data; a rebuild needs an empty or absent database"}
    end
  end

  defp rebuild_commands(config) do
    env = "DD_DATABASE=#{config[:database]} DD_DATABASE_PORT=#{config[:port]}"

    [
      "#{env} mix ecto.create",
      "#{env} mix ecto.migrate",
      "#{env} mix dd.rebuild --scope <scope> --dry-run",
      "#{env} mix dd.rebuild --scope <scope>"
    ]
  end

  # ── reporting ────────────────────────────────────────────────────────────

  defp pending(state) do
    recorded = MapSet.new(state["migrations"])

    for version <- code_migrations(), not MapSet.member?(recorded, version), do: version
  end

  @doc "The migration versions this checkout carries, ascending."
  def code_migrations do
    "priv/repo/migrations/*.exs"
    |> Path.wildcard()
    |> Enum.map(
      &(&1
        |> Path.basename()
        |> String.split("_", parts: 2)
        |> hd()
        |> String.to_integer())
    )
    |> Enum.sort()
  end

  defp report(opts, report) do
    if path = opts[:report] do
      Files.write_atomic!(Path.expand(path), Jason.encode_to_iodata!(report, pretty: true))
    end

    {:ok, report}
  end
end
