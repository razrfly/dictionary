defmodule DevilsDictionary.Installation.Database do
  @moduledoc """
  What a PostgreSQL server and one of its databases are, as the server
  reports them, and the few statements a bootstrap issues against it.

  Everything an installation move must carry beyond the database's own rows
  lives here, because `pg_dump` without `--create` leaves it out:

    * **database properties**: encoding, locale provider, collate and ctype,
      the ICU locale and rules, the recorded and actual collation versions,
      owner, connection limit, privileges (as granted), comment;
    * **database-level settings** (`ALTER DATABASE … SET`). Every
      `devils_dictionary*` database has `TimeZone=Etc/UTC`, which
      `ecto_sql`'s `storage_up` sets, while the server default is local
      time. A database restored with `createdb` and `pg_restore` alone would
      quietly lose it;
    * **roles**: their attributes, never their passwords;
    * the server's identity (`system_identifier`), version and data
      directory.

  Questions go through `Snapshot.probe/3`, so an unreachable server is an
  error returned, not a crash. Reads are read-only transactions where a
  transaction is possible.
  """

  alias DevilsDictionary.Routing.Recovery
  alias DevilsDictionary.Snapshot

  @name ~r/\A[a-z][a-z0-9_]*\z/

  @doc """
  A connection config for `target`: a database name on the configured
  server, or an `ecto://` URL naming its whole endpoint (as
  `mix dd.routing.verify --baseline` reads one).
  """
  def config(target), do: target |> Recovery.target_config() |> Snapshot.resolve()

  @doc "`config/1`, with a malformed URL as `{:error, message}` rather than a raise."
  def resolve(target) when is_binary(target) do
    {:ok, config(target)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def resolve(target), do: {:error, "no database named: #{inspect(target)}"}

  @doc "`{host, port, database}` as an operator reads it."
  def describe(config), do: config |> Recovery.identity() |> Recovery.describe()

  @doc """
  A database name this tooling may create or replace: lowercase, at most 63
  bytes (PostgreSQL silently truncates longer identifiers, which could make
  two names one), and beginning with `devils_dictionary`.
  """
  def check_name(name) do
    cond do
      not is_binary(name) or not Regex.match?(@name, name) ->
        {:error, "#{inspect(name)} is not a plain lowercase database name"}

      byte_size(name) > 63 ->
        {:error, "#{name} is longer than 63 bytes; PostgreSQL would truncate it"}

      not String.starts_with?(name, "devils_dictionary") ->
        {:error, "refusing #{name}: this tooling only writes devils_dictionary* databases"}

      true ->
        :ok
    end
  end

  # ── reading ──────────────────────────────────────────────────────────────

  @doc """
  The server `config` reaches, and the database it names if that exists:

      {:ok, %{server: %{system_identifier, version, version_num, major,
                        data_directory, icu_version},
              database: properties | nil,
              database_bytes: integer | nil}}

  `icu_version` is the actual collation version of the database's ICU
  locale (of `en-US` when the database does not exist yet).
  """
  def facts(config, opts \\ []) do
    config = Snapshot.resolve(config)
    database = config[:database]
    locale = Keyword.get(opts, :icu_locale, "en-US")

    Snapshot.probe(Snapshot.maintenance(config), fn conn ->
      server = server(conn)
      properties = properties(conn, database)
      icu = icu_version(conn, (properties && properties["locale"]) || locale)

      %{
        server: Map.put(server, :icu_version, icu),
        database: properties,
        database_bytes: properties && size(conn, properties["oid"])
      }
    end)
  end

  defp server(conn) do
    %{rows: [[id, version, num, dir]]} =
      Postgrex.query!(
        conn,
        """
        SELECT system_identifier::text, version(), current_setting('server_version_num')::int,
               current_setting('data_directory')
          FROM pg_control_system()
        """,
        []
      )

    %{
      system_identifier: id,
      version: version,
      version_num: num,
      major: div(num, 10_000),
      data_directory: dir
    }
  end

  # Not a property: a restored database carries no bloat, so its size
  # differs from its source's by design.
  defp size(conn, oid) do
    %{rows: [[bytes]]} = Postgrex.query!(conn, "SELECT pg_database_size($1::oid)", [oid])
    bytes
  end

  defp icu_version(conn, locale) do
    case Postgrex.query!(
           conn,
           "SELECT pg_collation_actual_version(oid) FROM pg_collation " <>
             "WHERE collprovider = 'i' AND collname = $1 || '-x-icu'",
           [locale]
         ) do
      %{rows: [[version]]} -> version
      _ -> nil
    end
  end

  @doc false
  def properties(conn, database) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT d.oid::bigint, pg_encoding_to_char(d.encoding), d.datlocprovider::text,
               d.datcollate, d.datctype, d.datlocale, d.daticurules, d.datcollversion,
               pg_database_collation_actual_version(d.oid), d.datconnlimit, d.datallowconn,
               d.datistemplate, pg_get_userbyid(d.datdba), shobj_description(d.oid, 'pg_database'),
               (SELECT coalesce(string_agg(g, ',' ORDER BY g COLLATE "C"), '')
                  FROM (SELECT concat_ws(':',
                                 CASE WHEN x.grantor = d.datdba THEN 'owner' ELSE pg_get_userbyid(x.grantor) END,
                                 CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                      WHEN x.grantee = d.datdba THEN 'owner'
                                      ELSE pg_get_userbyid(x.grantee) END,
                                 x.privilege_type, x.is_grantable) AS g
                          FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) AS x) AS grants)
          FROM pg_database d WHERE d.datname = $1
        """,
        [database]
      )

    case rows do
      [] ->
        nil

      [
        [
          oid,
          encoding,
          provider,
          collate,
          ctype,
          locale,
          rules,
          recorded,
          actual,
          limit,
          allow,
          template,
          owner,
          comment,
          acl
        ]
      ] ->
        %{
          "name" => database,
          "oid" => oid,
          "encoding" => encoding,
          "locale_provider" => provider,
          "collate" => collate,
          "ctype" => ctype,
          "locale" => locale,
          "icu_rules" => rules,
          "collation_version" => recorded,
          "actual_collation_version" => actual,
          "connection_limit" => limit,
          "allow_connections" => allow,
          "is_template" => template,
          "owner" => owner,
          "comment" => comment,
          "acl" => acl,
          "settings" => settings(conn, oid)
        }
    end
  end

  # `ALTER DATABASE … SET` and `ALTER ROLE … IN DATABASE … SET`, sorted.
  defp settings(conn, oid) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT CASE WHEN s.setrole = 0 THEN NULL ELSE pg_get_userbyid(s.setrole) END,
               s.setconfig
          FROM pg_db_role_setting s WHERE s.setdatabase = $1
         ORDER BY 1 NULLS FIRST
        """,
        [oid]
      )

    Enum.map(rows, fn [role, config] -> %{"role" => role, "config" => Enum.sort(config)} end)
  end

  @doc """
  Every role but PostgreSQL's own (`pg_*`), with its attributes and the
  roles it is a member of. Never a password.
  """
  def roles(config) do
    Snapshot.probe(Snapshot.maintenance(Snapshot.resolve(config)), fn conn ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          """
          SELECT r.rolname, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb,
                 r.rolcanlogin, r.rolreplication, r.rolbypassrls, r.rolconnlimit,
                 r.rolvaliduntil::text,
                 ARRAY(SELECT g.rolname FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                        WHERE m.member = r.oid ORDER BY g.rolname COLLATE "C")
            FROM pg_roles r WHERE r.rolname !~ '^pg_' ORDER BY r.rolname COLLATE "C"
          """,
          []
        )

      Enum.map(rows, fn [
                          name,
                          su,
                          inherit,
                          createrole,
                          createdb,
                          login,
                          repl,
                          bypass,
                          limit,
                          until,
                          member_of
                        ] ->
        %{
          "name" => name,
          "superuser" => su,
          "inherit" => inherit,
          "createrole" => createrole,
          "createdb" => createdb,
          "login" => login,
          "replication" => repl,
          "bypassrls" => bypass,
          "connection_limit" => limit,
          "valid_until" => until,
          "member_of" => Enum.reject(member_of, &String.starts_with?(&1, "pg_"))
        }
      end)
    end)
  end

  @doc """
  The roles the database depends on, by name: its owner, the owners of its
  schemas, relations, functions and types outside the system catalogs, every
  grantee of a privilege on them or on the database (default privileges
  included), and roles with settings in it. PostgreSQL's own `pg_*` roles
  and PUBLIC are left out.
  """
  def referenced_roles(config) do
    in_database(config, fn conn ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          """
          WITH ns AS (
            SELECT oid FROM pg_namespace
             WHERE nspname NOT IN ('pg_catalog', 'information_schema')
               AND nspname !~ '^pg_toast' AND nspname !~ '^pg_temp'
          ), owners AS (
            SELECT datdba AS role FROM pg_database WHERE datname = current_database()
            UNION SELECT nspowner FROM pg_namespace WHERE oid IN (SELECT oid FROM ns)
            UNION SELECT relowner FROM pg_class WHERE relnamespace IN (SELECT oid FROM ns)
            UNION SELECT proowner FROM pg_proc WHERE pronamespace IN (SELECT oid FROM ns)
            UNION SELECT typowner FROM pg_type WHERE typnamespace IN (SELECT oid FROM ns)
            UNION SELECT defaclrole FROM pg_default_acl
            UNION SELECT setrole FROM pg_db_role_setting
                   WHERE setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
          ), acls AS (
            SELECT relacl AS acl FROM pg_class WHERE relnamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT proacl FROM pg_proc WHERE pronamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT nspacl FROM pg_namespace WHERE oid IN (SELECT oid FROM ns)
            UNION ALL SELECT typacl FROM pg_type WHERE typnamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT defaclacl FROM pg_default_acl
            UNION ALL SELECT datacl FROM pg_database WHERE datname = current_database()
          ), grantees AS (
            SELECT (aclexplode(acl)).grantee AS role FROM acls WHERE acl IS NOT NULL
          )
          SELECT DISTINCT pg_get_userbyid(role) FROM (
            SELECT role FROM owners UNION SELECT role FROM grantees
          ) r
           WHERE role <> 0 AND pg_get_userbyid(role) !~ '^pg_'
           ORDER BY 1
          """,
          []
        )

      Enum.map(rows, &hd/1)
    end)
  end

  @doc "Extensions installed in the database: `[%{name, version, schema}]`."
  def extensions(config) do
    in_database(config, fn conn ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT extname, extversion, extnamespace::regnamespace::text FROM pg_extension " <>
            "ORDER BY extname COLLATE \"C\"",
          []
        )

      Enum.map(rows, fn [name, version, schema] ->
        %{"name" => name, "version" => version, "schema" => schema}
      end)
    end)
  end

  @doc """
  The version of each extension the server installs by default:
  `%{name => version}`. `pg_dump` writes `CREATE EXTENSION` without a
  version, so a restore gets exactly this one.
  """
  def default_extensions(config) do
    Snapshot.probe(Snapshot.maintenance(Snapshot.resolve(config)), fn conn ->
      %{rows: rows} =
        Postgrex.query!(conn, "SELECT name, default_version FROM pg_available_extensions", [])

      Map.new(rows, fn [name, version] -> {name, version} end)
    end)
  end

  @doc "Migration versions recorded in the database, ascending; `[]` without a history."
  def migrations(config) do
    in_database(config, fn conn ->
      %{rows: [[history?]]} =
        Postgrex.query!(conn, "SELECT to_regclass('public.schema_migrations') IS NOT NULL", [])

      if history? do
        %{rows: rows} =
          Postgrex.query!(conn, "SELECT version FROM schema_migrations ORDER BY version", [])

        Enum.map(rows, &hd/1)
      else
        []
      end
    end)
  end

  @doc """
  Other client sessions connected to the database, as `pg_stat_activity`
  shows them: `[%{pid, application, client, state, backend_start}]`. This
  probe's own session is never among them.
  """
  def connections(config) do
    config = Snapshot.resolve(config)

    Snapshot.probe(Snapshot.maintenance(config), fn conn ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          """
          SELECT pid, application_name, coalesce(client_addr::text, 'local'), state,
                 backend_start::text
            FROM pg_stat_activity
           WHERE datname = $1 AND pid <> pg_backend_pid() AND backend_type = 'client backend'
           ORDER BY pid
          """,
          [config[:database]]
        )

      Enum.map(rows, fn [pid, app, client, state, started] ->
        %{
          "pid" => pid,
          "application" => app,
          "client" => client,
          "state" => state,
          "backend_start" => started
        }
      end)
    end)
  end

  @doc """
  The row counters a quiet window must leave unchanged (docs/routing/recovery.md
  step 1): sums of `n_tup_ins`, `n_tup_upd` and `n_tup_del` over the
  database's user tables. Reads do not move them.
  """
  def write_counters(config) do
    in_database(config, fn conn ->
      %{rows: [[ins, upd, del]]} =
        Postgrex.query!(
          conn,
          "SELECT coalesce(sum(n_tup_ins), 0)::bigint, coalesce(sum(n_tup_upd), 0)::bigint, " <>
            "coalesce(sum(n_tup_del), 0)::bigint FROM pg_stat_user_tables",
          []
        )

      %{"inserted" => ins, "updated" => upd, "deleted" => del}
    end)
  end

  @doc """
  What the write counters cannot see, as one fingerprint: every sequence's
  `last_value` and `is_called` (a `nextval` that writes no row, as an
  upsert that does nothing, moves no counter), and the catalog rows of the
  user schemas by oid and `xmin` (any DDL writes new ones). Sequences and
  catalog definitions are not read under a transaction's snapshot, so a
  capture is exact only if this is the same before and after it.
  """
  def window_fingerprint(config) do
    in_database(config, fn conn ->
      %{rows: sequences} =
        Postgrex.query!(
          conn,
          """
          SELECT c.oid::regclass::text FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'S' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
           ORDER BY c.oid::regclass::text COLLATE "C"
          """,
          []
        )

      states =
        Enum.map(sequences, fn [name] ->
          %{rows: [[last, called]]} =
            Postgrex.query!(conn, "SELECT last_value, is_called FROM #{name}", [])

          "#{name}=#{last}:#{called}"
        end)

      %{rows: [[catalog]]} =
        Postgrex.query!(
          conn,
          """
          WITH ns AS (SELECT oid FROM pg_namespace
                       WHERE nspname NOT IN ('pg_catalog', 'information_schema')
                         AND nspname !~ '^pg_toast' AND nspname !~ '^pg_temp')
          SELECT md5(coalesce(string_agg(entry, ',' ORDER BY entry COLLATE "C"), '')) FROM (
            SELECT 'c' || oid || ':' || xmin AS entry FROM pg_class WHERE relnamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT 'a' || attrelid || '.' || attnum || ':' || a.xmin FROM pg_attribute a
              JOIN pg_class c ON c.oid = a.attrelid WHERE c.relnamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT 'k' || oid || ':' || xmin FROM pg_constraint WHERE connamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT 'p' || oid || ':' || xmin FROM pg_proc WHERE pronamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT 't' || t.oid || ':' || t.xmin FROM pg_trigger t
              JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace IN (SELECT oid FROM ns)
            UNION ALL SELECT 'n' || oid || ':' || xmin FROM pg_namespace WHERE oid IN (SELECT oid FROM ns)
          ) entries
          """,
          []
        )

      digest =
        :crypto.hash(:sha256, Enum.join(states, "\n"))
        |> Base.encode16(case: :lower)

      %{"sequences" => digest, "sequence_count" => length(states), "catalog" => catalog}
    end)
  end

  @doc "Whether the database has any relation in a non-system schema."
  def populated?(config) do
    in_database(config, fn conn ->
      %{rows: [[n]]} =
        Postgrex.query!(
          conn,
          """
          SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
             AND n.nspname !~ '^pg_temp' AND n.nspname !~ '^pg_toast_temp'
          """,
          []
        )

      n > 0
    end)
  end

  @doc "Runs `fun` on a read-only connection to the database itself."
  def in_database(config, fun, timeout \\ 60_000) do
    config = Snapshot.resolve(config)

    connection =
      config
      |> Snapshot.maintenance()
      |> Keyword.put(:database, config[:database])

    Snapshot.probe(
      connection,
      fn conn ->
        {:ok, result} =
          Postgrex.transaction(conn, fn conn ->
            Postgrex.query!(conn, "SET TRANSACTION READ ONLY", [])
            fun.(conn)
          end)

        result
      end,
      timeout
    )
  end

  # ── writing (bootstrap only) ──────────────────────────────────────────────

  @doc """
  Creates `name` on `config`'s server from `template0` with the recorded
  encoding, locale and owner, and comments it with `marker` at once, so a
  later run can tell its own unfinished database from anyone else's.
  """
  def create!(config, name, properties, marker) do
    :ok = ok!(check_name(name))
    provider = locale_clause(properties)

    sql =
      ~s|CREATE DATABASE "#{name}" TEMPLATE template0 ENCODING '#{literal(properties["encoding"])}' | <>
        provider <>
        ~s| OWNER "#{identifier(properties["owner"])}"|

    # CREATE DATABASE cannot share a transaction with the COMMENT, so a
    # database this call created and could not mark is dropped again at once:
    # an unmarked staging database is never left behind by this code.
    maintenance!(config, fn conn ->
      Postgrex.query!(conn, sql, [])

      try do
        Postgrex.query!(conn, ~s|COMMENT ON DATABASE "#{name}" IS '#{literal(marker)}'|, [])
      rescue
        error ->
          Postgrex.query(conn, ~s|DROP DATABASE "#{name}"|, [])
          reraise error, __STACKTRACE__
      end
    end)
  end

  @doc """
  Runs `fun` while holding a session-level advisory lock named `key` on
  `config`'s server, so two bootstraps of one target cannot interleave.
  `{:error, message}` at once if another session holds it.
  """
  def with_lock(config, key, fun) do
    lock = :erlang.phash2({:dd_bootstrap, key}, 2_147_483_647)

    result =
      Snapshot.probe(
        Snapshot.maintenance(Snapshot.resolve(config)),
        fn conn ->
          case Postgrex.query!(conn, "SELECT pg_try_advisory_lock($1)", [lock]) do
            %{rows: [[true]]} ->
              try do
                fun.()
              after
                Postgrex.query(conn, "SELECT pg_advisory_unlock($1)", [lock])
              end

            %{rows: [[false]]} ->
              {:error,
               "another bootstrap of #{key} is running against #{describe(config)}; nothing was changed"}
          end
        end,
        :timer.hours(24)
      )

    case result do
      {:ok, inner} -> inner
      {:error, message} -> {:error, message}
    end
  end

  defp locale_clause(%{"locale_provider" => "i"} = p) do
    rules = if p["icu_rules"], do: " ICU_RULES '#{literal(p["icu_rules"])}'", else: ""

    "LOCALE_PROVIDER icu ICU_LOCALE '#{literal(p["locale"])}' " <>
      "LC_COLLATE '#{literal(p["collate"])}' LC_CTYPE '#{literal(p["ctype"])}'" <> rules
  end

  defp locale_clause(%{"locale_provider" => "c"} = p),
    do:
      "LOCALE_PROVIDER libc LC_COLLATE '#{literal(p["collate"])}' LC_CTYPE '#{literal(p["ctype"])}'"

  defp locale_clause(%{"locale_provider" => "b"} = p),
    do:
      "LOCALE_PROVIDER builtin BUILTIN_LOCALE '#{literal(p["locale"])}' " <>
        "LC_COLLATE '#{literal(p["collate"])}' LC_CTYPE '#{literal(p["ctype"])}'"

  @doc """
  Applies the recorded database-level settings, connection limit, privileges
  and comment to `name`. Each is compared again afterwards; nothing here is
  trusted to have worked.
  """
  def apply_properties!(config, name, properties) do
    :ok = ok!(check_name(name))

    maintenance!(config, fn conn ->
      for %{"role" => role, "config" => entries} <- properties["settings"],
          entry <- entries do
        [key, value] = String.split(entry, "=", parts: 2)

        target =
          if role,
            do: ~s|ROLE "#{identifier(role)}" IN DATABASE "#{name}"|,
            else: ~s|DATABASE "#{name}"|

        Postgrex.query!(
          conn,
          ~s|ALTER #{target} SET "#{identifier(key)}" TO '#{literal(value)}'|,
          []
        )
      end

      Postgrex.query!(
        conn,
        ~s|ALTER DATABASE "#{name}" CONNECTION LIMIT #{Integer.to_string(properties["connection_limit"])}|,
        []
      )

      comment!(conn, name, properties["comment"])
      privileges!(conn, name, properties["acl"])
    end)
  end

  @doc "Sets or clears the database's comment."
  def set_comment!(config, name, comment) do
    :ok = ok!(check_name(name))
    maintenance!(config, &comment!(&1, name, comment))
  end

  defp comment!(conn, name, nil),
    do: Postgrex.query!(conn, ~s|COMMENT ON DATABASE "#{name}" IS NULL|, [])

  defp comment!(conn, name, comment),
    do: Postgrex.query!(conn, ~s|COMMENT ON DATABASE "#{name}" IS '#{literal(comment)}'|, [])

  # The database's privileges, as granted: everything revoked, then exactly
  # the recorded grants. The default (`owner` everything, PUBLIC CONNECT and
  # TEMPORARY) is left alone when that is what was recorded, so an
  # unchanged database keeps its NULL ACL.
  @default_acl "owner:PUBLIC:CONNECT:f,owner:PUBLIC:TEMPORARY:f,owner:owner:CONNECT:f," <>
                 "owner:owner:CREATE:f,owner:owner:TEMPORARY:f"

  defp privileges!(_conn, _name, @default_acl), do: :ok

  defp privileges!(conn, name, acl) do
    Postgrex.query!(conn, ~s|REVOKE ALL ON DATABASE "#{name}" FROM PUBLIC|, [])

    %{rows: [[owner]]} =
      Postgrex.query!(
        conn,
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = $1",
        [name]
      )

    Postgrex.query!(conn, ~s|REVOKE ALL ON DATABASE "#{name}" FROM "#{identifier(owner)}"|, [])

    for grant <- String.split(acl, ",", trim: true) do
      [_grantor, grantee, privilege, grantable] = String.split(grant, ":")

      who =
        if grantee == "PUBLIC",
          do: "PUBLIC",
          else: ~s|"#{identifier(resolve_owner(grantee, owner))}"|

      option = if grantable == "t", do: " WITH GRANT OPTION", else: ""

      Postgrex.query!(
        conn,
        ~s|GRANT #{privilege(privilege)} ON DATABASE "#{name}" TO #{who}#{option}|,
        []
      )
    end
  end

  defp resolve_owner("owner", owner), do: owner
  defp resolve_owner(role, _owner), do: role

  defp privilege(p) when p in ~w(CONNECT CREATE TEMPORARY), do: p

  @doc "Renames `from` to `to`. Refuses unless both names may be written here."
  def rename!(config, from, to) do
    :ok = ok!(check_name(from))
    :ok = ok!(check_name(to))
    maintenance!(config, &rename(&1, from, to, 20))
  end

  # A session that has just disconnected from `from` can still hold it for
  # a moment (`object_in_use`); a rename waits for it, briefly.
  defp rename(conn, from, to, tries) do
    Postgrex.query!(conn, ~s|ALTER DATABASE "#{from}" RENAME TO "#{to}"|, [])
  rescue
    error in Postgrex.Error ->
      if tries > 1 and error.postgres[:code] == :object_in_use do
        Process.sleep(100)
        rename(conn, from, to, tries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Drops `name`, which must carry exactly `marker` as its comment: only a
  bootstrap's own unfinished staging database is ever dropped here.
  """
  def drop_marked!(config, name, marker) do
    :ok = ok!(check_name(name))

    maintenance!(config, fn conn ->
      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = $1",
          [name]
        )

      case rows do
        [[^marker]] -> Postgrex.query!(conn, ~s|DROP DATABASE "#{name}" WITH (FORCE)|, [])
        [] -> :ok
        _ -> raise "refusing to drop #{name}: it does not carry this bootstrap's marker"
      end
    end)
  end

  @doc "The comment on database `name`, or nil (also when it does not exist)."
  def comment(config, name) do
    Snapshot.probe(Snapshot.maintenance(Snapshot.resolve(config)), fn conn ->
      case Postgrex.query!(
             conn,
             "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = $1",
             [name]
           ) do
        %{rows: [[comment]]} -> comment
        _ -> nil
      end
    end)
  end

  defp maintenance!(config, fun) do
    case Snapshot.probe(Snapshot.maintenance(Snapshot.resolve(config)), fun, 600_000) do
      {:ok, result} -> result
      {:error, reason} -> raise "#{describe(config)}: #{reason}"
    end
  end

  defp ok!(:ok), do: :ok
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  # Values recorded from the server's own catalogs, quoted all the same.
  defp literal(value), do: String.replace(to_string(value), "'", "''")

  defp identifier(value) do
    value = to_string(value)

    if String.contains?(value, ~s|"|),
      do: raise(ArgumentError, "refusing identifier #{inspect(value)}"),
      else: value
  end
end
