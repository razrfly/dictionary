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

  # Server settings as given (`--setting key=value`): plain names only, so
  # one can never be anything but a setting name in `ALTER SYSTEM`.
  defp setting_names(settings) do
    case Enum.reject(settings, fn {key, value} ->
           is_binary(key) and key =~ ~r/\A[a-z_][a-z0-9_.]*\z/ and is_binary(value)
         end) do
      [] -> :ok
      bad -> {:error, "refusing settings #{inspect(bad)}: names are lowercase setting names"}
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
          "-p #{port} -c listen_addresses=localhost -c unix_socket_directories=/tmp",
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

  # Each setting is written with ALTER SYSTEM (validated by the server as it
  # is written), then made effective: a restart when any needs one, a reload
  # otherwise. Then each is read back from the file it was written to,
  # applied, and with no restart pending.
  defp apply_settings(_config, [], _tools, _data, _log_file, _log), do: {:ok, %{}}

  defp apply_settings(config, settings, tools, data, log_file, log) do
    run!(
      config,
      Enum.map(settings, fn {key, value} ->
        ~s|ALTER SYSTEM SET "#{key}" = '#{literal(value)}'|
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

      if status != 0, do: raise("pg_ctl restart exited with #{status}: #{out}")
    end

    effective_settings(config, settings)
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

  # `{:ok, %{name => current_setting}}` when every requested setting is the
  # value written to postgresql.auto.conf, applied, with no restart pending.
  defp effective_settings(config, settings) do
    {:ok, rows} =
      DevilsDictionary.Snapshot.probe(DevilsDictionary.Snapshot.maintenance(config), fn conn ->
        for {key, value} <- settings do
          %{rows: file} =
            Postgrex.query!(
              conn,
              "SELECT setting, applied, error FROM pg_file_settings " <>
                "WHERE name = $1 AND sourcefile LIKE '%postgresql.auto.conf' ORDER BY seqno DESC LIMIT 1",
              [key]
            )

          %{rows: [[current, pending]]} =
            Postgrex.query!(
              conn,
              "SELECT current_setting($1), pending_restart FROM pg_settings WHERE name = $1",
              [key]
            )

          {key, value, file, current, pending}
        end
      end)

    problems =
      for {key, value, file, _current, pending} <- rows,
          file != [[value, true, nil]] or pending,
          do:
            "#{key}: requested #{inspect(value)}, file #{inspect(file)}, restart pending #{pending}"

    if problems == [],
      do: {:ok, Map.new(rows, fn {key, _value, _file, current, _pending} -> {key, current} end)},
      else: {:error, "settings are not in effect as requested: " <> Enum.join(problems, "; ")}
  end

  defp literal(value), do: String.replace(value, "'", "''")

  defp stopped(tools, data, message) do
    {out, status} =
      System.cmd(tools["pg_ctl"], ["-D", data, "-m", "fast", "-w", "stop"],
        stderr_to_stdout: true
      )

    note =
      if status == 0,
        do:
          "The new cluster has been stopped. Its directory #{data} holds no dictionary data: " <>
            "remove it and run again, or choose another --data-dir.",
        else: "Stopping the new cluster failed too (#{String.trim(out)}): stop it by hand."

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
    run!(config, [
      "ALTER SYSTEM SET port = #{port}",
      "ALTER SYSTEM SET listen_addresses = 'localhost'",
      "ALTER SYSTEM SET unix_socket_directories = '/tmp'"
    ])

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
         {:ok, applied} <- effective_settings(config, settings) do
      log.("a cluster from #{data} is running on #{port}; making sure its setup is complete")
      complete!(config, port, manifest["cluster_roles"])

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
