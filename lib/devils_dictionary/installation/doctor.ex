defmodule DevilsDictionary.Installation.Doctor do
  @moduledoc """
  Is this installation ready? A read-only answer (#130 §4, #211 §2).

  Every check is a map `%{id, category, status, detail}`:

    * `category` — `:core` (the dictionary cannot run correctly without it)
      or `:optional` (provider credentials, the curation model service);
    * `status` — `:ok`, `:warn` (works, but look), `:fail`, `:absent` (an
      optional thing that is simply not here) or `:skipped` (not asked for).

  The installation is **usable** when no core check fails. Optional
  failures make it **degraded**, never unusable: missing provider keys or a
  stopped model service leave definitions and reading intact.

  Read-only by construction. It starts no application, Oban node, endpoint
  or model; with `deep:` it opens one short-lived Repo pool to read the full
  state, and closes it. Every database question is a read-only transaction
  or a catalog read (so it passes against a database whose transactions are
  read-only by default); files are stat'ed, and hashed only with `deep:`;
  `.env` is read for its key names only, never its values; ports are probed
  with a TCP connect. Nothing is created, downloaded or generated.
  """

  alias DevilsDictionary.Installation.{
    Bootstrap,
    Bundle,
    Database,
    Files,
    Manifest,
    State,
    Volume
  }

  @doc """
  Runs every check. Options:

    * `:target` — a database name on the configured server or an `ecto://`
      URL (default: the configured database);
    * `:expect_cluster` — the `system_identifier` the database must be on;
    * `:volume`, `:uuid` — the external volume the server's data directory
      must be on;
    * `:bundle` — compare with this bundle's database record (and its
      files); with `deep: true`, its full state as well;
    * `:deep` — hash files and compare the full state (minutes at corpus
      scale);
    * `:root` — the checkout (default `"."`); `:env` — the Mix env checked
      for a build (default the current one).
  """
  def run(opts \\ []) do
    root = Path.expand(Keyword.get(opts, :root, "."))
    target = opts[:target] || DevilsDictionary.Repo.config()[:database]
    deep? = Keyword.get(opts, :deep, false)
    bundle = opts[:bundle] && read_bundle(opts[:bundle])

    {config, facts} =
      case Database.resolve(target) do
        {:ok, config} -> {config, Database.facts(config)}
        {:error, message} -> {[database: target], {:error, message}}
      end

    checks =
      [
        toolchain(root),
        pg_tools(facts),
        endpoint(config),
        server(facts, opts),
        volume(facts, opts),
        database(facts, config),
        locale(facts, bundle),
        settings(facts, bundle),
        extensions(facts, config, bundle),
        schema(facts, config),
        state(facts, target, bundle, deep?),
        bundle_files(bundle, deep?),
        inputs(root, deep?),
        replay(root, deep?),
        build(root, opts),
        http_port(),
        jobs(),
        env_file(root),
        runtime(facts)
      ]
      |> List.flatten()

    %{
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      target: Database.describe(config),
      usable: not Enum.any?(checks, &(&1.category == :core and &1.status == :fail)),
      degraded: Enum.any?(checks, &(&1.category == :optional and &1.status in [:fail, :warn])),
      checks: checks
    }
  end

  defp check(id, category, status, detail),
    do: %{id: id, category: category, status: status, detail: detail}

  defp read_bundle(path) do
    path = Path.expand(path)

    case Manifest.read(path) do
      {:ok, manifest} -> %{path: path, manifest: manifest}
      {:error, message} -> %{path: path, error: message}
    end
  end

  # ── toolchain ────────────────────────────────────────────────────────────

  defp toolchain(root) do
    pinned =
      case File.read(Path.join(root, ".tool-versions")) do
        {:ok, text} ->
          for line <- String.split(text, "\n", trim: true),
              [tool, version | _] <- [String.split(line)],
              into: %{},
              do: {tool, version}

        _ ->
          %{}
      end

    running = %{"elixir" => System.version(), "erlang" => otp_version()}

    problems =
      for tool <- ~w(elixir erlang),
          expected = pinned[tool],
          expected != nil,
          not matches?(tool, expected, running[tool]),
          do: "#{tool} #{running[tool]}, pinned #{expected}"

    if problems == [],
      do: check("toolchain", :core, :ok, "elixir #{running["elixir"]}, OTP #{running["erlang"]}"),
      else: check("toolchain", :core, :fail, Enum.join(problems, "; ") <> " (run `mise install`)")
  end

  # `.tool-versions` pins `1.19.0-otp-28`; the running Elixir reports `1.19.0`.
  defp matches?("elixir", expected, running), do: hd(String.split(expected, "-")) == running

  defp matches?("erlang", expected, running),
    do: running == expected or String.starts_with?(running, expected <> ".")

  defp otp_version do
    path = Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"])

    case File.read(path) do
      {:ok, version} -> String.trim(version)
      _ -> System.otp_release()
    end
  end

  defp pg_tools(facts) do
    versions =
      for tool <- ~w(pg_dump pg_restore psql), into: %{}, do: {tool, Bundle.tool_version(tool)}

    missing = for {tool, nil} <- versions, do: tool

    cond do
      missing != [] ->
        check("pg_tools", :core, :fail, "not on PATH: #{Enum.join(missing, ", ")}")

      match?({:ok, _}, facts) and
          Enum.any?(versions, fn {_t, v} -> Bundle.major(v) != elem(facts, 1).server.major end) ->
        check(
          "pg_tools",
          :core,
          :fail,
          "#{inspect(versions)} against a PostgreSQL #{elem(facts, 1).server.major} server"
        )

      true ->
        check("pg_tools", :core, :ok, Enum.map_join(versions, ", ", fn {t, v} -> "#{t} #{v}" end))
    end
  end

  # ── the database ─────────────────────────────────────────────────────────

  defp endpoint(config) do
    case DevilsDictionary.Snapshot.followable(config) do
      :ok -> check("endpoint", :core, :ok, Database.describe(config))
      {:error, message} -> check("endpoint", :core, :fail, message)
    end
  end

  defp server({:error, reason}, _opts),
    do: check("server", :core, :fail, "unreachable: #{reason}")

  defp server({:ok, facts}, opts) do
    s = facts.server

    detail =
      "cluster #{s.system_identifier}, PostgreSQL #{div(s.version_num, 10_000)}.#{rem(s.version_num, 10_000)}, " <>
        "data #{s.data_directory}"

    case opts[:expect_cluster] do
      nil -> check("server", :core, :ok, detail)
      id when id == s.system_identifier -> check("server", :core, :ok, detail <> " (as pinned)")
      id -> check("server", :core, :fail, detail <> "; expected cluster #{id}")
    end
  end

  defp volume({:ok, facts}, opts) do
    case opts[:volume] do
      nil ->
        check("volume", :core, :skipped, "no --volume given")

      mount_point ->
        case Volume.check(facts.server.data_directory, mount_point,
               uuid: opts[:uuid],
               probe: Keyword.get(opts, :probe, &Volume.probe/1)
             ) do
          {:ok, v} ->
            check(
              "volume",
              :core,
              :ok,
              "data directory on #{v.mount_point} (#{v.uuid || "uuid not checked"}), " <>
                "#{Volume.gib(v.free_bytes)} free"
            )

          {:error, message} ->
            check("volume", :core, :fail, message)
        end
    end
  end

  defp volume({:error, _}, _opts), do: check("volume", :core, :skipped, "server unreachable")

  defp database({:error, _}, _config),
    do: check("database", :core, :skipped, "server unreachable")

  defp database({:ok, %{database: nil}}, config),
    do: check("database", :core, :fail, "#{config[:database]} does not exist")

  defp database({:ok, facts}, _config),
    do:
      check(
        "database",
        :core,
        :ok,
        "#{facts.database["name"]} (oid #{facts.database["oid"]}), #{Volume.gib(facts.database_bytes)}"
      )

  defp locale({:ok, %{database: db}}, bundle) when is_map(db) do
    drift = db["collation_version"] != db["actual_collation_version"]
    expected = recorded(bundle)

    differs =
      if expected,
        do:
          for(
            key <-
              ~w(encoding locale_provider collate ctype locale icu_rules actual_collation_version),
            expected[key] != db[key],
            do: "#{key} #{inspect(db[key])} ≠ #{inspect(expected[key])}"
          ),
        else: []

    cond do
      drift ->
        check(
          "locale",
          :core,
          :fail,
          "collation version drift: recorded #{db["collation_version"]}, library #{db["actual_collation_version"]}; " <>
            "text indexes may be wrong until reindexed"
        )

      differs != [] ->
        check("locale", :core, :fail, "differs from the bundle: " <> Enum.join(differs, "; "))

      true ->
        check(
          "locale",
          :core,
          :ok,
          "#{db["encoding"]}, #{provider(db["locale_provider"])} #{db["locale"]}, " <>
            "collate #{db["collate"]}, collation version #{db["actual_collation_version"]}"
        )
    end
  end

  defp locale(_facts, _bundle), do: check("locale", :core, :skipped, "no database")

  defp provider("i"), do: "ICU"
  defp provider("c"), do: "libc"
  defp provider("b"), do: "builtin"
  defp provider(other), do: other

  defp recorded(%{manifest: manifest}), do: manifest["database"]
  defp recorded(_bundle), do: nil

  # Ecto's storage_up sets TimeZone=Etc/UTC on the database; the server's
  # default is local time. Without it every timestamptz reads differently.
  defp settings({:ok, %{database: db}}, bundle) when is_map(db) do
    timezone? =
      Enum.any?(db["settings"], &(&1["role"] == nil and "TimeZone=Etc/UTC" in &1["config"]))

    expected = recorded(bundle)

    cond do
      expected && expected["settings"] != db["settings"] ->
        check(
          "db_settings",
          :core,
          :fail,
          "#{inspect(db["settings"])}, the bundle records #{inspect(expected["settings"])}"
        )

      not timezone? ->
        check(
          "db_settings",
          :core,
          :fail,
          "the database has no TimeZone=Etc/UTC setting (#{inspect(db["settings"])}); " <>
            "timestamps would read in the server's local zone"
        )

      true ->
        check(
          "db_settings",
          :core,
          :ok,
          Enum.map_join(db["settings"], "; ", &Enum.join(&1["config"], ","))
        )
    end
  end

  defp settings(_facts, _bundle), do: check("db_settings", :core, :skipped, "no database")

  defp extensions({:ok, %{database: db}}, config, bundle) when is_map(db) do
    case Database.extensions(config) do
      {:ok, installed} ->
        names = Map.new(installed, &{&1["name"], &1["version"]})
        missing = for ext <- ~w(citext pg_trgm), not Map.has_key?(names, ext), do: ext
        detail = Enum.map_join(installed, ", ", &"#{&1["name"]} #{&1["version"]}")

        cond do
          missing != [] ->
            check("extensions", :core, :fail, "missing #{Enum.join(missing, ", ")} (#{detail})")

          bundle_state(bundle) && bundle_state(bundle)["extensions"] != installed ->
            check(
              "extensions",
              :core,
              :fail,
              "#{detail}; the bundle records " <>
                Enum.map_join(
                  bundle_state(bundle)["extensions"],
                  ", ",
                  &"#{&1["name"]} #{&1["version"]}"
                )
            )

          true ->
            check("extensions", :core, :ok, detail)
        end

      {:error, reason} ->
        check("extensions", :core, :fail, reason)
    end
  end

  defp extensions(_facts, _config, _bundle),
    do: check("extensions", :core, :skipped, "no database")

  defp bundle_state(%{path: path, manifest: manifest}) do
    case Manifest.file(manifest, "state") do
      nil -> nil
      file -> path |> Path.join(file["path"]) |> File.read!() |> Jason.decode!()
    end
  rescue
    _ -> nil
  end

  defp bundle_state(_bundle), do: nil

  defp schema({:ok, %{database: db}}, config) when is_map(db) do
    with {:ok, recorded} <- Database.migrations(config) do
      code = Bootstrap.code_migrations()
      pending = code -- recorded
      unknown = recorded -- code

      cond do
        recorded == [] ->
          check("schema", :core, :fail, "no migration history")

        unknown != [] ->
          check(
            "schema",
            :core,
            :fail,
            "the database records migrations this checkout does not have: #{Enum.join(unknown, ", ")}"
          )

        pending != [] ->
          check(
            "schema",
            :core,
            :warn,
            "head #{List.last(recorded)}; #{length(pending)} pending in this checkout: " <>
              Enum.join(pending, ", ") <>
              ". Apply them only as a recorded step (never on a baseline being compared)"
          )

        true ->
          check(
            "schema",
            :core,
            :ok,
            "head #{List.last(recorded)}, #{length(recorded)} migrations, none pending"
          )
      end
    else
      {:error, reason} -> check("schema", :core, :fail, reason)
    end
  end

  defp schema(_facts, _config), do: check("schema", :core, :skipped, "no database")

  defp state(_facts, _target, nil, _deep?), do: []

  defp state(_facts, _target, %{error: message}, _deep?),
    do: check("state", :core, :fail, "bundle: #{message}")

  defp state({:ok, %{database: db}}, target, bundle, true) when is_map(db) do
    case bundle_state(bundle) do
      nil ->
        check("state", :core, :fail, "the bundle has no readable state")

      expected ->
        case safe_diff(expected, target) do
          {:error, message} ->
            check("state", :core, :fail, "the state cannot be compared: #{message}")

          [] ->
            check("state", :core, :ok, "equal to the bundle's captured state, every section")

          diffs ->
            check(
              "state",
              :core,
              :fail,
              "#{length(diffs)} differences: " <>
                (diffs |> Enum.take(5) |> Enum.map_join("; ", &State.describe/1))
            )
        end
    end
  end

  defp state(_facts, _target, _bundle, _deep?),
    do: check("state", :core, :skipped, "the full state comparison runs with --deep")

  defp safe_diff(expected, target) do
    State.diff(expected, State.capture(target), ignore: [:name])
  rescue
    error -> {:error, Exception.message(error)}
  end

  # ── files ────────────────────────────────────────────────────────────────

  defp bundle_files(nil, _deep?), do: []
  defp bundle_files(%{error: message}, _deep?), do: check("bundle", :core, :fail, message)

  defp bundle_files(%{path: path}, deep?) do
    case Bundle.verify(path, deep: deep?) do
      {:ok, report} ->
        check(
          "bundle",
          :core,
          :ok,
          "#{length(report.rows)} files #{if deep?, do: "hashed", else: "sized"}; manifest #{report.digest}"
        )

      {:error, report} ->
        failed = for %{status: :failed} = r <- report.rows, do: "#{r.path}: #{r.detail}"
        check("bundle", :core, :fail, Enum.join(failed ++ report.problems, "; "))
    end
  end

  # The archived inputs only a rebuild reads: absent is not a failure.
  defp inputs(root, deep?) do
    {_result, rows} =
      DevilsDictionary.Sources.Manifest.verify(
        root: root,
        path: Path.join(root, "priv/sources/MANIFEST.json"),
        quick: not deep?
      )

    bad = Enum.filter(rows, &(&1.status == :mismatch))
    missing = Enum.filter(rows, &(&1.status == :missing))
    how = if deep?, do: "hashed", else: "sized"

    cond do
      bad != [] ->
        check("inputs", :core, :fail, Enum.map_join(bad, "; ", &"#{&1.locator}: #{&1.detail}"))

      missing != [] ->
        check(
          "inputs",
          :optional,
          :absent,
          "#{length(rows) - length(missing)}/#{length(rows)} present (#{how}); absent: " <>
            Enum.map_join(missing, ", ", & &1.locator) <> ". Needed only to rebuild"
        )

      true ->
        check("inputs", :core, :ok, "#{length(rows)} pinned inputs present (#{how})")
    end
  end

  defp replay(root, deep?) do
    manifest = Path.join(root, "priv/replay/MANIFEST.json")

    case File.read(manifest) do
      {:ok, json} ->
        rows =
          for file <- Jason.decode!(json)["files"] do
            expected = %{"bytes" => file["byte_count"], "sha256" => file["sha256"]}

            {file["file"],
             Files.check(Path.join([root, "priv/replay", file["file"]]), expected, deep: deep?)}
          end

        bad = for {f, {:error, r}} <- rows, r != :missing, do: "#{f}: #{Files.describe(r)}"
        missing = for {f, {:error, :missing}} <- rows, do: f

        cond do
          bad != [] ->
            check("replay", :core, :fail, Enum.join(bad, "; "))

          missing != [] ->
            check(
              "replay",
              :optional,
              :absent,
              "absent: #{Enum.join(missing, ", ")}. Needed only to replay"
            )

          true ->
            check("replay", :core, :ok, "#{length(rows)} archives present")
        end

      _ ->
        check("replay", :core, :fail, "#{manifest} is missing")
    end
  end

  # ── build, endpoint, jobs ───────────────────────────────────────────────

  # A checkout moved without recompiling still reads `priv/routing` from the
  # old path, which `Routing.Policy` bakes in at compile time.
  defp build(root, opts) do
    env = Keyword.get(opts, :env, Mix.env())

    app =
      Path.join([
        root,
        "_build",
        to_string(env),
        "lib/devils_dictionary/ebin/devils_dictionary.app"
      ])

    policy_root = DevilsDictionary.Routing.Policy.root()
    expected_root = Path.join(root, "priv/routing")

    cond do
      not File.exists?(app) ->
        check("build", :core, :fail, "no #{env} build at #{app}; run `mix compile` first")

      Path.expand(policy_root) != expected_root ->
        check(
          "build",
          :core,
          :fail,
          "compiled for #{policy_root}, not this checkout (#{expected_root}); run `mix compile --force`"
        )

      true ->
        check("build", :core, :ok, "#{env} build present, compiled for this checkout")
    end
  end

  defp http_port do
    port =
      Application.get_env(:devils_dictionary, DevilsDictionaryWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port)

    cond do
      is_nil(port) ->
        check("http_port", :core, :skipped, "no HTTP port configured")

      DevilsDictionary.Installation.Cluster.port_free?(port) ->
        check("http_port", :core, :ok, "#{port} free")

      true ->
        check(
          "http_port",
          :core,
          :warn,
          "#{port} is in use (#{listener(port)}); a second server would not start"
        )
    end
  end

  defp listener(port) do
    case System.cmd("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fpc"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.map_join(" ", &String.slice(&1, 1..-1//1))

      _ ->
        "unknown process"
    end
  end

  # What starting the application here would run, against which database.
  defp jobs do
    oban = Application.get_env(:devils_dictionary, Oban, [])

    case {Keyword.get(oban, :testing), Keyword.get(oban, :queues), Keyword.get(oban, :plugins)} do
      {mode, _, _} when mode in [:manual, :inline] ->
        check("jobs", :core, :ok, "Oban testing mode #{mode}: nothing runs")

      {_, false, false} ->
        check("jobs", :core, :ok, "Oban with no queues and no plugins (DD_NO_OBAN)")

      {_, queues, _} ->
        check(
          "jobs",
          :core,
          :warn,
          "starting the server would run Oban queues #{inspect(queues)} and its plugins against " <>
            "this database; set DD_NO_OBAN=1 while it is being verified"
        )
    end
  end

  defp env_file(root) do
    example = Path.join(root, ".env.example")
    env = Path.join(root, ".env")

    keys = fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*([A-Z][A-Z0-9_]*)=(.*)$/, line) do
          [_, key, value] -> [{key, String.trim(value) != ""}]
          _ -> []
        end
      end)
      |> Map.new()
    end

    cond do
      not File.exists?(example) ->
        check("env", :optional, :skipped, "no .env.example")

      not File.exists?(env) ->
        check(
          "env",
          :optional,
          :absent,
          "no .env: provider shelves that need keys stay off (copy it privately; never in a bundle)"
        )

      true ->
        wanted = keys.(example)
        have = keys.(env)
        unset = for {key, _} <- wanted, not Map.has_key?(have, key), do: key

        # Names only, never values.
        if unset == [],
          do: check("env", :optional, :ok, ".env names every key .env.example does"),
          else:
            check(
              "env",
              :optional,
              :warn,
              ".env does not name: #{Enum.join(Enum.sort(unset), ", ")}"
            )
    end
  end

  # The curation model service: read its files, never start it.
  defp runtime(facts) do
    cfg = Application.get_env(:devils_dictionary, :curation_runtime, [])
    run_dir = cfg[:run_dir]
    binary = cfg[:binary]
    models = cfg[:models_root]

    cond do
      is_nil(run_dir) ->
        check("runtime", :optional, :skipped, "no curation runtime configured")

      not File.dir?(run_dir) ->
        check(
          "runtime",
          :optional,
          :absent,
          "#{run_dir} is not there (is #{cfg[:mount_point]} mounted?)"
        )

      true ->
        authority = authority(Path.join(run_dir, "authority.json"), facts)

        problems =
          [
            if(binary && not File.exists?(binary), do: "no binary at #{binary}"),
            if(models && not File.dir?(Path.join(models, "manifests")),
              do: "no model manifests under #{models}"
            )
          ]
          |> Enum.reject(&is_nil/1)

        cond do
          problems != [] ->
            check("runtime", :optional, :fail, Enum.join(problems, "; "))

          authority != :match ->
            check("runtime", :optional, :warn, authority_detail(authority))

          true ->
            check("runtime", :optional, :ok, "binary and models present; bound to this database")
        end
    end
  end

  defp authority(path, {:ok, %{database: %{"name" => name}, server: server}}) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"database" => ^name, "system_identifier" => id}}
          when id == server.system_identifier ->
            :match

          {:ok, %{"database" => db, "system_identifier" => id}} ->
            {:foreign, db, id}

          _ ->
            :unreadable
        end

      _ ->
        :unbound
    end
  end

  defp authority(_path, _facts), do: :unbound

  defp authority_detail({:foreign, db, id}),
    do:
      "the service is bound to #{db} on cluster #{id}, not this database; rebind deliberately with `mix dd.runtime service start --rebind`"

  defp authority_detail(:unbound), do: "the service is bound to no database yet"
  defp authority_detail(:unreadable), do: "authority.json is unreadable"

  @doc "A report as lines for a terminal."
  def lines(report) do
    width = report.checks |> Enum.map(&String.length(&1.id)) |> Enum.max(fn -> 10 end)

    rows =
      Enum.map(report.checks, fn c ->
        "  #{mark(c.status)} #{String.pad_trailing(c.id, width)}  #{c.category}  #{c.detail}"
      end)

    verdict =
      cond do
        not report.usable -> "NOT USABLE: a core check failed"
        report.degraded -> "usable; optional parts degraded"
        true -> "usable"
      end

    ["doctor: #{report.target}", "" | rows] ++ ["", "  #{verdict}"]
  end

  defp mark(:ok), do: "✅"
  defp mark(:warn), do: "⚠️ "
  defp mark(:fail), do: "❌"
  defp mark(:absent), do: "◻️ "
  defp mark(:skipped), do: "– "
end
