defmodule DevilsDictionary.Installation.Cluster do
  @moduledoc """
  Creates a dedicated PostgreSQL cluster for the dictionary from a bundle's
  record (#211 §1: a dedicated external cluster rather than moving the
  shared one, which serves other projects).

  The cluster is made with the `initdb` and `pg_ctl` on PATH — the same
  PostgreSQL build as the source, which the bundle's server version and ICU
  collation version then confirm — and is initialised with the source
  database's encoding, locale provider, ICU locale, collate and ctype, and
  data checksums. Once started it is given the source cluster's roles with
  their recorded attributes and memberships. **No password is set**: the
  bundle never carries one, and authentication is the `auth:` given here
  (`trust` on local connections, as both existing local clusters use).
  Passwords, where wanted, are set deliberately afterwards.

  Refused before anything is written: a data directory that is not on the
  expected mounted external volume, that already exists with content, or a
  port already in use. A cluster already initialised at that directory and
  running on that port is reported, not touched.

  It never stops, moves or reconfigures any other cluster.
  """

  alias DevilsDictionary.Installation.{Bundle, Database, Manifest, Volume}

  @doc """
  Options: `:bundle`, `:data_dir`, `:port`, `:volume` (required); `:uuid`;
  `:auth` (default `"trust"`); `:log`; `:probe` (the volume probe).

  `{:ok, %{outcome: :created | :present, system_identifier, port, data_dir, log_file}}`
  or `{:error, message}`.
  """
  def init(opts) do
    log = Keyword.get(opts, :log, fn _ -> :ok end)
    bundle = Path.expand(Keyword.fetch!(opts, :bundle))
    data = Path.expand(Keyword.fetch!(opts, :data_dir))
    port = Keyword.fetch!(opts, :port)
    auth = Keyword.get(opts, :auth, "trust")
    settings = Keyword.get(opts, :settings, [])
    log_file = Path.join(Path.dirname(data), "postgresql-#{port}.log")

    with {:ok, manifest} <- Manifest.read(bundle),
         :ok <- Bundle.digest_pinned(bundle, opts[:expect_manifest_sha256]),
         :ok <- role_names(manifest["cluster_roles"]),
         :ok <- setting_names(settings),
         {:ok, tools} <- tools(),
         :ok <- same_major(tools, manifest),
         {:ok, _volume} <-
           Volume.check(data, Keyword.fetch!(opts, :volume),
             uuid: opts[:uuid],
             need_bytes: div(manifest["source"]["database_bytes"] * 12, 10),
             probe: Keyword.get(opts, :probe, &Volume.probe/1)
           ) do
      try do
        case existing(data, port) do
          :absent -> create(manifest, data, port, auth, log_file, tools, settings, log)
          :running -> present(manifest, data, port, log_file, settings, log)
          {:error, message} -> {:error, message}
        end
      rescue
        error -> {:error, "setting up the cluster at #{data} failed: #{Exception.message(error)}"}
      end
    end
  end

  # The settings this task manages itself, from --port and the endpoint it
  # reaches the server on; another value for them would be a different cluster.
  @managed ~w(port listen_addresses unix_socket_directories data_directory config_file
              hba_file ident_file)

  # Server settings as given (`--setting key=value`), checked before
  # `initdb`: plain parameter names, any case (`TimeZone`), each once, none
  # of the managed ones, and no custom `ext.name` (an extension's own
  # setting cannot be read back until the extension is loaded).
  defp setting_names(settings) do
    malformed =
      Enum.reject(settings, fn {key, value} ->
        is_binary(key) and key =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/ and is_binary(value)
      end)

    keys = Enum.map(settings, fn {key, _} -> String.downcase(to_string(key)) end)

    repeated =
      keys |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0))

    managed = Enum.filter(keys, &(&1 in @managed))

    cond do
      malformed != [] ->
        {:error,
         "refusing settings #{inspect(malformed)}: each is name=value, with a plain parameter name"}

      repeated != [] ->
        {:error, "refusing settings: #{Enum.join(repeated, ", ")} given more than once"}

      managed != [] ->
        {:error,
         "refusing settings #{Enum.join(managed, ", ")}: this task sets them itself " <>
           "(the port is --port; the server listens on localhost)"}

      true ->
        :ok
    end
  end

  # Checked before `initdb`, so a bad name refuses before anything exists.
  defp role_names(roles) do
    names = Enum.flat_map(roles, &[&1["name"] | &1["member_of"]])

    case Enum.reject(names, &valid_name?/1) do
      [] -> :ok
      bad -> {:error, "the bundle records role names this setup refuses: #{inspect(bad)}"}
    end
  end

  defp valid_name?(name), do: is_binary(name) and name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  defp tools do
    found = for tool <- ~w(initdb pg_ctl), into: %{}, do: {tool, System.find_executable(tool)}

    case for({tool, nil} <- found, do: tool) do
      [] -> {:ok, Map.put(found, "version", Bundle.tool_version("initdb"))}
      missing -> {:error, "#{Enum.join(missing, " and ")} not found on PATH"}
    end
  end

  defp same_major(%{"version" => version}, manifest) do
    source = div(manifest["source"]["server_version_num"], 10_000)

    if version && Bundle.major(version) == source,
      do: :ok,
      else: {:error, "initdb is #{inspect(version)}; the bundle's source is PostgreSQL #{source}"}
  end

  defp existing(data, port) do
    cond do
      not File.exists?(data) ->
        if port_free?(port),
          do: :absent,
          else: {:error, "port #{port} is already in use; choose another with --port"}

      File.dir?(data) and File.ls!(data) == [] ->
        if port_free?(port),
          do: :absent,
          else: {:error, "port #{port} is already in use; choose another with --port"}

      File.exists?(Path.join(data, "PG_VERSION")) and not port_free?(port) ->
        :running

      true ->
        {:error,
         "#{data} already exists and is not an empty directory; a cluster is never " <>
           "initialised over existing files"}
    end
  end

  @doc "Whether nothing listens on localhost:`port`."
  def port_free?(port) do
    case :gen_tcp.connect(~c"localhost", port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _} ->
        true
    end
  end

  defp create(manifest, data, port, auth, log_file, tools, settings, log) do
    db = manifest["database"]
    File.mkdir_p!(Path.dirname(data))
    log.("initdb #{data}")

    {out, status} =
      System.cmd(
        tools["initdb"],
        [
          "-D",
          data,
          "-U",
          "postgres",
          "--auth=#{auth}",
          "--encoding=#{db["encoding"]}",
          "--data-checksums"
        ] ++ locale_args(db),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("initdb exited with #{status}: #{out}")

    log.("starting it on port #{port} (log #{log_file})")

    {out, status} =
      System.cmd(
        tools["pg_ctl"],
        [
          "-D",
          data,
          "-l",
          log_file,
          "-w",
          "-o",
          "-p #{port} -c listen_addresses=localhost",
          "start"
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("pg_ctl start exited with #{status}: #{out}")

    # From here the server is running. Whatever fails before its setup is
    # complete stops it again — the collation first, so a cluster that
    # cannot hold the database exactly is stopped before anything is added
    # to it — and says so: no server is left running that nobody asked for.
    case started(manifest, db, endpoint(port), %{
           port: port,
           data: data,
           log_file: log_file,
           tools: tools,
           settings: settings,
           log: log
         }) do
      {:ok, result} -> {:ok, result}
      {:error, message} -> stopped(tools, data, message)
    end
  end

  defp started(manifest, db, config, at) do
    %{port: port, data: data, log_file: log_file, tools: tools, settings: settings, log: log} = at

    with {:ok, facts} <- Database.facts(config, icu_locale: db["locale"]),
         :ok <- same_icu(facts, db),
         :ok <- complete(config, port, manifest["cluster_roles"]),
         {:ok, applied} <- apply_settings(config, settings, tools, data, log_file, log) do
      {:ok,
       %{
         outcome: :created,
         system_identifier: facts.server.system_identifier,
         port: port,
         data_dir: data,
         log_file: log_file,
         settings: applied
       }}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Each setting, under the server's own name for it, is written with ALTER
  # SYSTEM (validated by the server as it is written) — a list of quoted
  # names (`shared_preload_libraries=a,b`) element by element, as
  # `Database.setting_values/2` gives a database's settings back — and made
  # effective: a reload, then a restart if any waits for one. Then each is
  # read back as running (`effective_settings/2`).
  defp apply_settings(_config, [], _tools, _data, _log_file, _log), do: {:ok, %{}}

  defp apply_settings(config, settings, tools, data, log_file, log) do
    with {:ok, settings} <- canonical_names(config, settings) do
      run!(
        config,
        Enum.map(settings, fn {key, value} ->
          values =
            key |> Database.setting_values(value) |> Enum.map_join(", ", &"'#{literal(&1)}'")

          ~s|ALTER SYSTEM SET "#{key}" = #{values}|
        end)
      )

      # A reload first: only once the server has re-read its configuration
      # does pg_settings say which settings wait for a restart.
      run!(config, ["SELECT pg_reload_conf()"])
      Process.sleep(300)

      if pending_restart?(config) do
        log.("restarting it for #{Enum.map_join(settings, ", ", &elem(&1, 0))}")

        # With its log file again: without `-l` the restarted server would
        # keep pg_ctl's output open, and this call would never return.
        {out, status} =
          System.cmd(tools["pg_ctl"], ["-D", data, "-l", log_file, "-m", "fast", "-w", "restart"],
            stderr_to_stdout: true
          )

        if status != 0, do: raise("pg_ctl restart exited with #{status}: #{String.trim(out)}")
      end

      effective_settings(config, settings, data)
    end
  end

  # The server's own spelling of each name (`timezone` → `TimeZone`), and a
  # refusal for any it does not know.
  defp canonical_names(config, settings) do
    {:ok, names} =
      DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
        %{rows: rows} = Postgrex.query!(conn, "SELECT lower(name), name FROM pg_settings", [])
        Map.new(rows, fn [lower, name] -> {lower, name} end)
      end)

    case Enum.reject(settings, fn {key, _} -> Map.has_key?(names, String.downcase(key)) end) do
      [] ->
        {:ok, Enum.map(settings, fn {key, value} -> {names[String.downcase(key)], value} end)}

      unknown ->
        {:error, "the server knows no setting #{Enum.map_join(unknown, ", ", &elem(&1, 0))}"}
    end
  end

  defp pending_restart?(config) do
    {:ok, pending} =
      DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
        %{rows: [[n]]} =
          Postgrex.query!(conn, "SELECT count(*) FROM pg_settings WHERE pending_restart", [])

        n > 0
      end)

    pending
  end

  # `{:ok, %{name => current_setting}}` when every setting is running as
  # requested, which pg_file_settings alone cannot say (its `applied` means
  # "could be applied", and only postmaster settings ever wait for a
  # restart). So for each:
  #
  #   * postgresql.auto.conf's last entry for it holds the requested value
  #     (for a list of quoted names, the same elements), and parses;
  #   * the running value comes from postgresql.auto.conf
  #     (`pg_settings.source` and `sourcefile`), not the command line or
  #     postgresql.conf;
  #   * the file has not changed since the server last loaded its
  #     configuration (`pg_conf_load_time()` against the file's
  #     modification time), so what runs is what the file says — a value
  #     written without a reload is refused;
  #   * no restart is pending.
  #
  # Not line numbers: ALTER SYSTEM moves the entry it rewrites to the end
  # of the file, so they shift whenever anything is set again.
  #
  # Values are compared as written: `16GB` and `16384MB` are different
  # requests here, so a re-run repeats the spelling it was created with.
  defp effective_settings(_config, [], _data), do: {:ok, %{}}

  defp effective_settings(config, settings, data) do
    with {:ok, settings} <- canonical_names(config, settings) do
      {:ok, {loaded?, rows}} =
        DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
          loaded? = loaded_since_written?(conn, data)

          rows =
            for {key, value} <- settings do
              %{rows: [running]} =
                Postgrex.query!(
                  conn,
                  """
                  SELECT f.setting, f.applied, f.error, s.source, s.sourcefile, s.pending_restart,
                         current_setting(s.name)
                    FROM pg_settings s
                    LEFT JOIN LATERAL (
                      SELECT * FROM pg_file_settings f
                       WHERE f.name = s.name AND f.sourcefile LIKE '%postgresql.auto.conf'
                       ORDER BY f.seqno DESC LIMIT 1) f ON true
                   WHERE s.name = $1
                  """,
                  [key]
                )

              {key, value, running}
            end

          {loaded?, rows}
        end)

      problems =
        Enum.flat_map(rows, fn {key, value, running} ->
          case in_effect(key, value, running, loaded?) do
            :ok -> []
            {:error, why} -> ["#{key}: #{why}"]
          end
        end)

      if problems == [],
        do: {:ok, Map.new(rows, fn {key, _value, running} -> {key, List.last(running)} end)},
        else: {:error, "settings are not in effect as requested: " <> Enum.join(problems, "; ")}
    end
  end

  # The server's last configuration load against the file's modification
  # time, to the sub-second: the data directory is local to this task, and
  # pg_stat_file's time has one-second resolution, which would let a write
  # in the same second as a reload pass as loaded.
  defp loaded_since_written?(conn, data) do
    %{rows: [[loaded_at]]} =
      Postgrex.query!(conn, "SELECT extract(epoch FROM pg_conf_load_time())::float8", [])

    case modified_at(Path.join(data, "postgresql.auto.conf")) do
      {:ok, modified} ->
        loaded_at >= modified

      :error ->
        %{rows: [[loaded?]]} =
          Postgrex.query!(
            conn,
            "SELECT pg_conf_load_time() > " <>
              "(pg_stat_file('postgresql.auto.conf')).modification + interval '1 second'",
            []
          )

        loaded?
    end
  end

  defp modified_at(path) do
    args =
      case :os.type() do
        {:unix, :darwin} -> ["-f", "%Fm", path]
        _ -> ["-c", "%.9Y", path]
      end

    with {out, 0} <- System.cmd("stat", args, stderr_to_stdout: true),
         {seconds, _} <- Float.parse(String.trim(out)) do
      {:ok, seconds}
    else
      _ -> :error
    end
  end

  defp in_effect(
         key,
         value,
         [file, applied, error, source, source_file, pending, current],
         loaded?
       ) do
    cond do
      is_nil(file) ->
        {:error, "not in postgresql.auto.conf (running #{inspect(current)} from #{source})"}

      not same_value?(key, file, value) ->
        {:error, "postgresql.auto.conf holds #{inspect(file)}, not #{inspect(value)}"}

      error != nil or applied != true ->
        {:error, "postgresql.auto.conf's value cannot be applied (#{inspect(error)})"}

      pending ->
        {:error, "written, and waiting for a restart"}

      not loaded? ->
        {:error,
         "written but not running: postgresql.auto.conf changed after the server last loaded it " <>
           "(running #{inspect(current)}; reload or restart it)"}

      source != "configuration file" or
          not String.ends_with?(to_string(source_file), "postgresql.auto.conf") ->
        {:error,
         "written but not running: the server's value #{inspect(current)} comes from #{source} " <>
           "#{source_file}, which takes precedence"}

      true ->
        :ok
    end
  end

  defp same_value?(key, file, value) do
    case Database.list_elements(file) do
      {:ok, elements} -> elements == Database.setting_values(key, value) or file == value
      :error -> file == value
    end
  rescue
    ArgumentError -> file == value
  end

  defp literal(value), do: String.replace(value, "'", "''")

  # A server that never came back from a restart has nothing to stop; the
  # message says so rather than asking for a stop by hand.
  defp stopped(tools, data, message) do
    running? =
      match?({_, 0}, System.cmd(tools["pg_ctl"], ["-D", data, "status"], stderr_to_stdout: true))

    {out, status} =
      if running?,
        do:
          System.cmd(tools["pg_ctl"], ["-D", data, "-m", "fast", "-w", "stop"],
            stderr_to_stdout: true
          ),
        else: {"", 0}

    remove =
      "Its directory #{data} holds no dictionary data: remove it and run again, or choose another --data-dir."

    note =
      cond do
        not running? ->
          "The new cluster is not running. " <> remove

        status == 0 ->
          "The new cluster has been stopped. " <> remove

        true ->
          "Stopping the new cluster failed too (#{String.trim(out)}): stop it by hand, then remove #{data}."
      end

    {:error, "#{message} #{note}"}
  end

  defp complete(config, port, roles) do
    complete!(config, port, roles)
    :ok
  rescue
    error -> {:error, "completing the cluster's setup failed: #{Exception.message(error)}"}
  end

  # What makes a started cluster the dictionary's: its port and addresses
  # recorded in the cluster itself (so a later plain `pg_ctl start`, or a
  # Postgres.app server entry, uses them), and the recorded roles. Both are
  # idempotent, so a setup interrupted after the start is completed by the
  # next run rather than reported as present.
  defp complete!(config, port, roles) do
    # The socket directory is the build's default (`/tmp` for Postgres.app)
    # and is not written: a list setting given as one string is stored
    # quoted, differs from the running value, and forces a restart.
    # Only what is missing or different is written, so a re-run on a
    # complete cluster leaves postgresql.auto.conf untouched (a write would
    # make every setting look unloaded until the next reload).
    {:ok, recorded} =
      DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
        %{rows: rows} =
          Postgrex.query!(
            conn,
            "SELECT name, setting FROM pg_file_settings " <>
              "WHERE sourcefile LIKE '%postgresql.auto.conf' AND name IN ('port', 'listen_addresses') " <>
              "ORDER BY seqno",
            []
          )

        Map.new(rows, fn [name, setting] -> {name, setting} end)
      end)

    wanted = %{"port" => Integer.to_string(port), "listen_addresses" => "localhost"}

    statements =
      for {name, value} <- wanted,
          recorded[name] != value,
          do: "ALTER SYSTEM SET #{name} = '#{value}'"

    if statements != [], do: run!(config, statements)

    roles!(config, roles)
  end

  defp locale_args(%{"locale_provider" => "i"} = db) do
    [
      "--locale-provider=icu",
      "--icu-locale=#{db["locale"]}",
      "--lc-collate=#{db["collate"]}",
      "--lc-ctype=#{db["ctype"]}"
    ] ++
      if(db["icu_rules"], do: ["--icu-rules=#{db["icu_rules"]}"], else: [])
  end

  defp locale_args(%{"locale_provider" => "c"} = db),
    do: ["--locale-provider=libc", "--lc-collate=#{db["collate"]}", "--lc-ctype=#{db["ctype"]}"]

  defp locale_args(%{"locale_provider" => "b"} = db),
    do: ["--locale-provider=builtin", "--builtin-locale=#{db["locale"]}"]

  # Neutral about whether the server is running: on creation the caller
  # stops it and says so; for a running cluster the caller reports it.
  defp same_icu(facts, %{"locale_provider" => "i"} = db) do
    if facts.server.icu_version == db["actual_collation_version"],
      do: :ok,
      else:
        {:error,
         "the cluster at #{facts.server.data_directory} has ICU collation version " <>
           "#{inspect(facts.server.icu_version)}; the source's is #{db["actual_collation_version"]}. " <>
           "Use the same PostgreSQL build."}
  end

  defp same_icu(_facts, _db), do: :ok

  # A running cluster is completed (port, addresses, roles) but its server
  # settings are only checked: changing them on a running cluster is a
  # deliberate act, not a side effect of a re-run.
  defp present(manifest, data, port, log_file, settings, log) do
    config = endpoint(port)

    with {:ok, facts} <- Database.facts(config, icu_locale: manifest["database"]["locale"]),
         :ok <- same_directory(facts, data, port),
         :ok <- same_icu(facts, manifest["database"]),
         _ =
           log.("a cluster from #{data} is running on #{port}; making sure its setup is complete"),
         :ok <- complete(config, port, manifest["cluster_roles"]),
         {:ok, applied} <- checked_settings(config, settings, data) do
      {:ok,
       %{
         outcome: :present,
         system_identifier: facts.server.system_identifier,
         port: port,
         data_dir: data,
         log_file: log_file,
         settings: applied
       }}
    else
      {:error, message} -> {:error, "a server is running on #{port}: #{message}"}
    end
  end

  defp checked_settings(config, settings, data) do
    case effective_settings(config, settings, data) do
      {:ok, applied} ->
        {:ok, applied}

      {:error, message} ->
        {:error,
         message <>
           ". A running cluster's settings are checked, never changed: set them deliberately " <>
           "(ALTER SYSTEM, then a reload or a restart) and run again, or stop it and remove " <>
           "#{data} to start over"}
    end
  end

  defp same_directory(facts, data, port) do
    if Path.expand(facts.server.data_directory) == data,
      do: :ok,
      else:
        {:error, "the server on port #{port} runs #{facts.server.data_directory}, not #{data}"}
  end

  # The bootstrap superuser exists already (`initdb -U postgres`); its
  # attributes are brought to the recorded ones too.
  defp roles!(config, roles) do
    {:ok, existing} = Database.roles(config)
    present = MapSet.new(existing, & &1["name"])

    statements =
      Enum.flat_map(roles, fn role ->
        verb = if MapSet.member?(present, role["name"]), do: "ALTER", else: "CREATE"
        [~s|#{verb} ROLE "#{name!(role["name"])}" WITH #{attributes(role)}|]
      end) ++
        for role <- roles, group <- role["member_of"] do
          ~s|GRANT "#{name!(group)}" TO "#{name!(role["name"])}"|
        end

    run!(config, statements)
  end

  defp attributes(role) do
    [
      {"superuser", "SUPERUSER", "NOSUPERUSER"},
      {"inherit", "INHERIT", "NOINHERIT"},
      {"createrole", "CREATEROLE", "NOCREATEROLE"},
      {"createdb", "CREATEDB", "NOCREATEDB"},
      {"login", "LOGIN", "NOLOGIN"},
      {"replication", "REPLICATION", "NOREPLICATION"},
      {"bypassrls", "BYPASSRLS", "NOBYPASSRLS"}
    ]
    |> Enum.map(fn {key, yes, no} -> if role[key], do: yes, else: no end)
    |> Kernel.++(["CONNECTION LIMIT #{Integer.to_string(role["connection_limit"])}"])
    |> Kernel.++(if role["valid_until"], do: ["VALID UNTIL '#{role["valid_until"]}'"], else: [])
    |> Enum.join(" ")
  end

  defp name!(name) do
    if valid_name?(name),
      do: name,
      else: raise(ArgumentError, "refusing role name #{inspect(name)}")
  end

  defp endpoint(port),
    do: [
      hostname: "localhost",
      port: port,
      username: "postgres",
      password: "",
      database: "postgres"
    ]

  defp run!(config, statements) do
    case DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
           Enum.each(statements, &Postgrex.query!(conn, &1, []))
           :done
         end) do
      {:ok, :done} -> :ok
      {:error, message} -> raise message
    end
  end
end
