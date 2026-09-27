defmodule DevilsDictionary.Routing.Recovery do
  @moduledoc """
  What recovery must preserve, how to check it, and what may not destroy it
  (ADR 0004 §8; procedure in `docs/routing/recovery.md`).

  Registry identities and routing state exist only in the database. A rebuild
  from sources renumbers every object, so pages, decisions and the address
  ledger cannot be regenerated. They can only be restored — whole, with the
  registry they reference — and then re-projected from source records.

    * `manifest/1` — **every column of every table** (Oban's queue state
      apart), ordered by primary key, plus the schema's constraints, indexes,
      triggers and functions and every sequence, hashed section by section in
      one repeatable-read snapshot. Nothing is hand-picked, so no identity or
      reference can be missed by omission.
    * `resolutions/0` — what every stored path and every page id resolves to.
    * `diff/2` and `verify/2` — where two databases disagree.
    * `with_database/2` — runs code against another database.
    * `snapshot!/2` — a snapshot plus the exact routing content it contains.
    * `guard/3` — whether a destructive task may run against a database that
      holds durable routing state.
  """

  import Ecto.Query

  alias DevilsDictionary.{Repo, Snapshot}
  alias DevilsDictionary.Routing.{Address, Page, PublicPath, Resolution, Resolver}

  @routing_tables ~w(pages page_revisions page_memberships public_paths classification_decisions route_changes)

  # The migration that creates them.
  @routing_migration 20_260_926_193_256

  # Operational queue state, not registry or routing: jobs and node heartbeats.
  @unmanifested ~w(oban_jobs oban_peers)

  # What re-projecting unchanged source records legitimately rewrites: its own
  # runs, and the stamps that say when a record was last materialized and by
  # which run. Everything else must be identical after
  # `dd.materialize --all --resolve`.
  @projection_tables ~w(import_runs)
  @projection_columns ~w(updated_at materialized_at last_seen_run_id)

  # Values hashed rather than compared verbatim: bodies and payloads.
  @hashed ~r/^(text|json|jsonb|bytea)(\[\])?$/

  def routing_tables, do: @routing_tables

  # No timeout: at corpus scale a sort before the first batch, or one batch
  # of a wide table, can outlast the pool's default 15 seconds. Every query
  # here only reads.
  defp query!(sql, params \\ []), do: Repo.query!(sql, params, timeout: :infinity)

  @doc """
  The manifest of the current repo's database.

  Options:

    * `mode: :exact` (default) — every column, and every sequence's
      `last_value` and `is_called`, used or not; what a restore must reproduce
      byte for byte.
    * `mode: :projected` — after `mix dd.materialize --all --resolve` on a
      restored copy:
      leaves out `import_runs` and the columns `updated_at`, `materialized_at`
      and `last_seen_run_id`, and the sequences, whose upserts may consume ids
      without writing rows (`sequences_behind/0` checks them instead).
    * `rows: true` — keeps every row, for exact differences in tests.
  """
  def manifest(opts \\ []) do
    mode = Keyword.get(opts, :mode, :exact)

    {:ok, manifest} =
      Repo.transaction(
        fn ->
          query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
          keys = primary_keys()

          sections =
            for {table, columns} <- columns(),
                table not in @unmanifested,
                mode == :exact or table not in @projection_tables,
                into: %{} do
              kept = Enum.reject(columns, fn {name, _type} -> skipped?(name, mode) end)
              {table, capture(table_sql(table, kept, Map.get(keys, table, [])), opts)}
            end

          sections = Map.put(sections, "schema", schema(opts))

          if mode == :exact,
            do: Map.put(sections, "sequences", sequences()),
            else: sections
        end,
        timeout: :infinity
      )

    manifest
  end

  defp skipped?(column, :projected), do: column in @projection_columns
  defp skipped?(_column, :exact), do: false

  defp columns do
    %{rows: rows} =
      query!("""
      SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'r'
       ORDER BY c.relname, a.attnum
      """)

    rows
    |> Enum.group_by(&Enum.at(&1, 0), fn [_table, column, type] -> {column, type} end)
    |> Enum.sort()
  end

  defp primary_keys do
    %{rows: rows} =
      query!("""
      SELECT c.relname, a.attname
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, position) ON true
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
       WHERE i.indisprimary AND c.relnamespace = 'public'::regnamespace
       ORDER BY c.relname, k.position
      """)

    Enum.group_by(rows, &Enum.at(&1, 0), &Enum.at(&1, 1))
  end

  defp table_sql(table, columns, key) do
    rendered =
      Enum.map_join(columns, ", ", fn {name, type} ->
        if Regex.match?(@hashed, type), do: ~s|md5("#{name}"::text)|, else: ~s|"#{name}"|
      end)

    # The primary key, text in byte order so the server's collation cannot
    # reorder it; every column, likewise, for a table without one.
    types = Map.new(columns)

    order =
      case key do
        [] -> Enum.map(columns, fn {name, _} -> ~s|"#{name}"::text COLLATE "C"| end)
        key -> Enum.map(key, &ordered(&1, Map.get(types, &1, "")))
      end

    ~s|SELECT json_build_array(#{rendered})::text FROM "#{table}" ORDER BY #{Enum.join(order, ", ")}|
  end

  defp ordered(column, type) do
    if type =~ ~r/^(text|character)/, do: ~s|"#{column}" COLLATE "C"|, else: ~s|"#{column}"|
  end

  # The schema's definitions, so a copy migrated to a different version of an
  # amended migration is a difference too. Its rows are always kept, as are
  # the sequences': both are small, and an operator needs to see which
  # definition differs.
  defp schema(_opts) do
    %{rows: rows} = query!(schema_sql())

    rows
    |> Enum.map(fn [kind, name, definition] ->
      Jason.encode!([kind, name, canonical(definition)])
    end)
    |> summarize(rows: true)
  end

  # pg_dump writes `x = ANY ((ARRAY['a'::character varying, …])::text[])` as it
  # is stored, and the restoring server re-parses it with the cast pushed into
  # each element: `ARRAY[('a'::character varying)::text, …]`. The same
  # condition, so both are compared in the restored form. Nothing else is
  # rewritten.
  @array_cast ~r/\(ARRAY\[((?:[^\[\]']|'(?:[^']|'')*')*)\]\)::([a-z ]+)\[\]/

  @doc false
  def canonical(definition) do
    Regex.replace(@array_cast, definition, fn _match, elements, type ->
      cast =
        ~r/(?:[^,']|'(?:[^']|'')*')+/
        |> Regex.scan(elements)
        |> Enum.map_join(", ", fn [element] -> "(#{String.trim(element)})::#{type}" end)

      "ARRAY[#{cast}]"
    end)
  end

  defp summarize(rows, opts) do
    hash =
      Enum.reduce(rows, :crypto.hash_init(:sha256), &:crypto.hash_update(&2, [&1, ?\n]))

    %{
      count: length(rows),
      sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      rows: if(Keyword.get(opts, :rows, false), do: rows)
    }
  end

  # Relations with their owner, row security and privileges; columns (type,
  # collation, nullability, default, privileges); constraints and indexes
  # with their validity; triggers with whether they fire; functions with
  # their owner and privileges; sequence parameters; policies; the public
  # schema's owner and privileges, and default privileges; extension
  # versions.
  #
  # Privileges are compared as granted, not as stored: a NULL ACL and the
  # explicit default it stands for are the same, and the owner appears as
  # `owner` (it is compared once, by name), so a copy owned by the same role
  # with the same grants matches.
  defp schema_sql do
    """
    SELECT kind, name, definition FROM (
      SELECT 'relation' AS kind, c.relname::text AS name,
             concat_ws(' ', c.relkind::text, 'owner=' || pg_get_userbyid(c.relowner),
                       'rls=' || c.relrowsecurity, 'force=' || c.relforcerowsecurity,
                       'acl=' || #{privileges("c.relacl", "CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END", "c.relowner")},
                       CASE WHEN c.relkind IN ('v', 'm') THEN md5(pg_get_viewdef(c.oid)) END) AS definition
        FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
         AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
      UNION ALL
      SELECT 'rule', ev_class::regclass::text || '.' || rulename, md5(pg_get_ruledef(r.oid))
        FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class
       WHERE c.relnamespace = 'public'::regnamespace AND r.rulename <> '_RETURN'
      UNION ALL
      SELECT 'column', a.attrelid::regclass::text || '.' || a.attname,
             concat_ws(' ', format_type(a.atttypid, a.atttypmod),
                       CASE WHEN a.attcollation <> 0 THEN 'COLLATE ' || a.attcollation::regcollation::text END,
                       CASE WHEN a.attnotnull THEN 'NOT NULL' END,
                       'DEFAULT ' || pg_get_expr(d.adbin, d.adrelid),
                       'acl=' || #{privileges("a.attacl", "'c'", "c.relowner")})
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
         AND a.attnum > 0 AND NOT a.attisdropped
      UNION ALL
      SELECT 'constraint', conrelid::regclass::text || '.' || conname,
             concat_ws(' ', pg_get_constraintdef(oid), CASE WHEN NOT convalidated THEN 'NOT VALID' END)
        FROM pg_constraint WHERE connamespace = 'public'::regnamespace
      UNION ALL
      SELECT 'index', i.indexrelid::regclass::text,
             concat_ws(' ', pg_get_indexdef(i.indexrelid), CASE WHEN NOT i.indisvalid THEN 'INVALID' END)
        FROM pg_index i WHERE i.indrelid IN (
          SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
      UNION ALL
      SELECT 'trigger', tgrelid::regclass::text || '.' || tgname,
             pg_get_triggerdef(oid) || ' [enabled=' || tgenabled::text || ']'
        FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN (
          SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
      UNION ALL
      SELECT 'function', p.oid::regprocedure::text,
             concat_ws(' ', md5(pg_get_functiondef(p.oid)), 'owner=' || pg_get_userbyid(p.proowner),
                       'acl=' || #{privileges("p.proacl", "'f'", "p.proowner")})
        FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      UNION ALL
      SELECT 'sequence', sequencename::text,
             concat_ws(' ', data_type, start_value, min_value, max_value, increment_by,
                       cycle, cache_size)
        FROM pg_sequences WHERE schemaname = 'public'
      UNION ALL
      SELECT 'policy', tablename::text || '.' || policyname,
             concat_ws(' ', permissive, roles::text, cmd, qual, with_check)
        FROM pg_policies WHERE schemaname = 'public'
      UNION ALL
      SELECT 'namespace', n.nspname::text,
             concat_ws(' ', 'owner=' || pg_get_userbyid(n.nspowner),
                       'acl=' || #{privileges("n.nspacl", "'n'", "n.nspowner")})
        FROM pg_namespace n WHERE n.oid = 'public'::regnamespace
      UNION ALL
      SELECT 'default privileges',
             concat_ws('.', pg_get_userbyid(d.defaclrole),
                       CASE WHEN d.defaclnamespace = 0 THEN '*' ELSE d.defaclnamespace::regnamespace::text END,
                       d.defaclobjtype::text),
             #{privileges("d.defaclacl", "CASE d.defaclobjtype WHEN 'S' THEN 's' ELSE d.defaclobjtype END", "d.defaclrole")}
        FROM pg_default_acl d WHERE d.defaclnamespace IN (0, 'public'::regnamespace)
      UNION ALL
      SELECT 'extension', extname::text, extversion FROM pg_extension
    ) AS definitions
    ORDER BY kind COLLATE "C", name COLLATE "C"
    """
  end

  # An ACL as the privileges it grants, sorted: NULL means the object type's
  # default for its owner, and the owner is written `owner`.
  defp privileges(acl, type, owner) do
    """
    (SELECT coalesce(string_agg(g, ',' ORDER BY g COLLATE "C"), '')
       FROM (SELECT concat_ws(':',
                      CASE WHEN x.grantor = #{owner} THEN 'owner' ELSE pg_get_userbyid(x.grantor) END,
                      CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                           WHEN x.grantee = #{owner} THEN 'owner'
                           ELSE pg_get_userbyid(x.grantee) END,
                      x.privilege_type, x.is_grantable) AS g
               FROM aclexplode(coalesce(#{acl}, acldefault((#{type})::"char", #{owner}))) AS x) AS grants)
    """
  end

  # Every sequence's own state: the value it last handed out and whether it
  # has handed it out yet (`is_called`), which together fix the next id. Read
  # from the sequence itself, because `pg_sequences.last_value` is null for a
  # sequence never used, whatever `setval/3` has set it to.
  defp sequences do
    %{rows: names} =
      query!("""
      SELECT relname FROM pg_class
       WHERE relkind = 'S' AND relnamespace = 'public'::regnamespace
       ORDER BY relname COLLATE "C"
      """)

    names
    |> Enum.map(fn [name] ->
      %{rows: [[last, called?]]} = query!(~s|SELECT last_value, is_called FROM "#{name}"|)
      Jason.encode!([name, last, called?])
    end)
    |> summarize(rows: true)
  end

  # A server-side cursor, fetched in batches: constant memory at corpus
  # scale, and — unlike `Ecto.Adapters.SQL.stream/4` — it follows a dynamic
  # repo, so the same code reads a restored copy.
  defp capture(sql, opts) do
    keep? = Keyword.get(opts, :rows, false)
    query!("DECLARE routing_manifest NO SCROLL CURSOR FOR #{sql}")
    {count, hash, rows} = fetch({0, :crypto.hash_init(:sha256), []}, keep?)
    query!("CLOSE routing_manifest")

    %{
      count: count,
      sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      rows: if(keep?, do: Enum.reverse(rows))
    }
  end

  defp fetch(acc, keep?) do
    case query!("FETCH FORWARD 5000 FROM routing_manifest") do
      %{rows: []} ->
        acc

      %{rows: batch} ->
        batch
        |> Enum.reduce(acc, fn [row], {n, hash, rows} ->
          {n + 1, :crypto.hash_update(hash, [row, ?\n]), if(keep?, do: [row | rows], else: rows)}
        end)
        |> fetch(keep?)
    end
  end

  @doc """
  The sections two manifests disagree on, with exact differences where rows
  were kept. Sections present in only one manifest are ignored here; `verify/2`
  reports them.
  """
  def diff(a, b) do
    for {section, left} <- a,
        right = Map.get(b, section),
        right != nil,
        left.sha256 != right.sha256 or left.count != right.count,
        into: %{} do
      {section,
       %{
         counts: {left.count, right.count},
         only_before: only(left.rows, right.rows),
         only_after: only(right.rows, left.rows)
       }}
    end
  end

  defp only(rows, other) when is_list(rows) and is_list(other),
    do:
      rows |> MapSet.new() |> MapSet.difference(MapSet.new(other)) |> Enum.sort() |> Enum.take(10)

  defp only(_rows, _other), do: :not_kept

  @doc """
  Compares the current repo's database with `baseline` — a database name on
  the same server, or an `ecto://` URL naming one on another: every manifest
  section, what every path and page id resolves to, and the sequences. With
  `projected: true` — after `mix dd.materialize --all --resolve` — the manifest is taken
  in `:projected` mode and the sequences need only not have fallen behind
  their tables. Neither database is modified.

  Routing is compared only where it exists. `report.routing` is:

    * `:present` — both databases have all six routing tables, and
      `report.resolutions_match` says whether every path and page resolves
      the same;
    * `:not_applicable` — neither has any of them: both predate the routing
      migration. The manifest comparison still decides the result, but
      nothing about routing recovery has been shown, and
      `report.resolutions_match` is `:not_applicable`;
    * `{:mismatch, baseline, current}` — anything else: one side has them and
      the other not, or either has only some (`{:partial, tables}`). Always a
      failure.

  The two manifests are taken at once, one in a task: at corpus scale each
  reads every row.

  Returns `{:ok, report}` or `{:error, report}`.
  """
  def verify(baseline, opts \\ []) do
    mode = if Keyword.get(opts, :projected, false), do: :projected, else: :exact
    manifest_opts = [mode: mode, rows: Keyword.get(opts, :rows, false)]
    capture = fn -> {manifest(manifest_opts), routing_state()} end

    baseline_task = Task.async(fn -> with_database(baseline, capture) end)
    {actual, {actual_routing, actual_resolutions}} = capture.()
    {expected, {expected_routing, expected_resolutions}} = Task.await(baseline_task, :infinity)

    {routing, resolutions_match} =
      case {expected_routing, actual_routing} do
        {:present, :present} -> {:present, expected_resolutions == actual_resolutions}
        {:absent, :absent} -> {:not_applicable, :not_applicable}
        {baseline_state, current_state} -> {{:mismatch, baseline_state, current_state}, false}
      end

    report = %{
      sections: Map.new(actual, fn {section, %{count: n}} -> {section, n} end),
      differences: diff(expected, actual),
      missing_sections: Enum.sort(Map.keys(expected) -- Map.keys(actual)),
      extra_sections: Enum.sort(Map.keys(actual) -- Map.keys(expected)),
      routing: routing,
      resolutions_match: resolutions_match,
      sequences_behind: sequences_behind()
    }

    exact? =
      report.differences == %{} and report.missing_sections == [] and
        report.extra_sections == [] and resolutions_match in [true, :not_applicable] and
        report.sequences_behind == []

    if exact?, do: {:ok, report}, else: {:error, report}
  end

  @doc """
  Where the current database stands on the routing migration
  (`#{@routing_migration}`), judged by its tables **and** its migration history:

    * `:present` — all six routing tables, and the migration recorded;
    * `:absent` — none of them, and the migration not recorded: the database
      predates routing;
    * `{:partial, tables}` — only some of the tables;
    * `{:inconsistent, reason}` — the tables and the history disagree:
      `:migration_without_tables` (recorded, but every table gone),
      `:tables_without_migration`, or `:no_migration_history` (no
      `schema_migrations` at all, so nothing can be said).

  Only `:present` and `:absent` can be compared; `verify/2` fails on the rest.
  """
  def routing_schema do
    %{rows: rows} =
      query!(
        "SELECT t FROM unnest($1::text[]) AS t WHERE to_regclass('public.' || t) IS NOT NULL",
        [@routing_tables]
      )

    present = rows |> Enum.map(&hd/1) |> Enum.sort()
    all? = length(present) == length(@routing_tables)

    case {present, all?, routing_migration()} do
      {_present, _all?, :no_history} -> {:inconsistent, :no_migration_history}
      {[], _all?, false} -> :absent
      {[], _all?, true} -> {:inconsistent, :migration_without_tables}
      {_present, true, true} -> :present
      {_present, true, false} -> {:inconsistent, :tables_without_migration}
      {present, false, _recorded?} -> {:partial, present}
    end
  end

  defp routing_migration do
    %{rows: [[history?]]} = query!("SELECT to_regclass('public.schema_migrations') IS NOT NULL")

    if history? do
      %{rows: [[recorded?]]} =
        query!("SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)", [
          @routing_migration
        ])

      recorded?
    else
      :no_history
    end
  end

  defp routing_state do
    case routing_schema() do
      :present -> {:present, resolutions()}
      other -> {other, nil}
    end
  end

  @doc """
  Sequences whose next value their table already holds — `last_value + 1`
  once called, `last_value` before — for every sequence a table column owns.
  """
  def sequences_behind do
    %{rows: owned} =
      query!("""
      SELECT s.relname, t.relname, a.attname
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid AND d.deptype = 'a'
        JOIN pg_class t ON t.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
       WHERE s.relkind = 'S' AND s.relnamespace = 'public'::regnamespace
       ORDER BY s.relname
      """)

    Enum.flat_map(owned, fn [sequence, table, column] ->
      %{rows: [[last, called?]]} =
        query!(~s|SELECT last_value, is_called FROM "#{sequence}"|)

      %{rows: [[max]]} = query!(~s|SELECT coalesce(max("#{column}"), 0) FROM "#{table}"|)
      next = if called?, do: last + 1, else: last
      if next <= max, do: [{sequence, next, max}], else: []
    end)
  end

  @doc """
  What every stored path and every page id resolves to, in byte order of the
  path and by id: outcome, page id, location and successor page ids.
  """
  def resolutions do
    paths =
      Repo.all(
        from p in PublicPath, order_by: fragment(~s|? COLLATE "C"|, p.path), select: p.path
      )

    pages = Repo.all(from p in Page, order_by: p.id, select: p.id)

    %{
      paths: Enum.map(paths, &{&1, summary(Resolver.resolve(Address.encode(&1)))}),
      pages: Enum.map(pages, &{&1, summary(Resolver.resolve_page(&1))})
    }
  end

  defp summary(%Resolution{} = resolution) do
    {resolution.outcome, resolution.page && resolution.page.id, resolution.location,
     Enum.map(resolution.successors, & &1.page_id)}
  end

  @doc """
  Runs `fun` with `Repo` pointed at `target` — a database name on the
  configured server, or an `ecto://` URL naming a database on any server —
  through a short-lived pool of its own. The configured database, and any
  other process, is untouched.
  """
  def with_database(target, fun) do
    config =
      target
      |> target_config()
      |> Keyword.merge(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    {:ok, pid} = Repo.start_link(config)
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end

  # The configured connection with `target` applied. The URL is expanded,
  # then removed: Ecto lets a configured `url:` override a `database:` passed
  # to `start_link/1`, which would point the pool back at the configured
  # database and compare a database with itself.
  defp target_config(target) do
    base = Repo.config() |> Snapshot.resolve() |> Keyword.put(:url, nil)

    if url?(target),
      do: Keyword.merge(base, Ecto.Repo.Supervisor.parse_url(target)),
      else: Keyword.put(base, :database, target)
  end

  defp url?(target), do: String.contains?(target, "://")

  @doc """
  The server and database a Repo config, a snapshot's recorded source, or a
  `with_database/2` target names: `{host, port, database}`, with the local
  host's spellings made one and the default port filled in. Two identities
  are equal exactly when they name the same database.
  """
  def identity(config) when is_list(config) do
    config = Snapshot.resolve(config)
    {host(config), config[:port] || 5432, config[:database]}
  end

  def identity(target) when is_binary(target), do: target |> target_config() |> identity()

  defp host(config) do
    cond do
      config[:socket_dir] -> "socket:" <> config[:socket_dir]
      config[:hostname] in [nil, "localhost", "127.0.0.1", "::1"] -> "localhost"
      true -> config[:hostname]
    end
  end

  @doc """
  Whether a Repo config and a `with_database/2` target reach the same
  database, as their servers identify it (`Snapshot.database_identity/1`).
  Raises if either server cannot say: a comparison must not run against an
  unknown baseline.
  """
  def same_database?(config, target) when is_list(config) do
    target_config = if is_binary(target), do: target_config(target), else: target

    with {:ok, a} <- Snapshot.database_identity(config),
         {:ok, b} <- Snapshot.database_identity(target_config) do
      a.system_identifier == b.system_identifier and
        (a.database == b.database or
           (is_integer(a.database_oid) and a.database_oid == b.database_oid))
    else
      {:error, reason} -> raise "cannot establish which database is which: #{reason}"
    end
  end

  @doc "An identity, as an operator reads it."
  def describe({nil, _port, database}), do: database
  def describe({host, port, database}), do: "#{database} on #{host}:#{port}"

  # ── snapshots and the guard on destructive tasks ─────────────────────────

  @doc """
  Durable routing state in a database — row counts and a digest of every
  routing row — or `nil` if it has none, does not exist, or predates the
  routing tables. Connects directly, so it works before the application
  starts, and reads in one repeatable-read snapshot.
  """
  def durable_state(config) do
    config = Snapshot.resolve(config)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    connection = connection(config)
    maintenance = Keyword.put(connection, :database, config[:maintenance_database] || "postgres")

    exists? =
      connected(maintenance, fn conn ->
        Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [
          config[:database]
        ]).num_rows == 1
      end)

    if exists? do
      connected(connection, fn conn ->
        {:ok, state} =
          Postgrex.transaction(conn, fn conn ->
            Postgrex.query!(
              conn,
              "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
              []
            )

            state(conn)
          end)

        state
      end)
    end
  end

  defp connection(config),
    do: Keyword.take(config, [:hostname, :port, :username, :password, :database, :socket_dir])

  # A connection that cannot be made raises in the caller, which for a
  # destructive task is the safe way to fail.
  defp connected(connection, fun) do
    {:ok, conn} = Postgrex.start_link(connection ++ [backoff_type: :stop, sync_connect: true])

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp state(conn) do
    case digest(conn) do
      nil ->
        nil

      digest ->
        counts = Map.new(digest, fn {table, [n, _md5]} -> {table, n} end)

        if Enum.all?(counts, fn {_table, n} -> n == 0 end),
          do: nil,
          else: %{counts: counts, digest: digest}
    end
  end

  # Every routing row, whole, in id order: any committed routing change —
  # a ledger write, a publication change, anything — changes it. Each row is
  # hashed by the server and the hashes stream through a cursor, so neither a
  # table nor a batch of long On bodies is ever one value in memory
  # (PostgreSQL caps a value at 1 GB). Must run inside a repeatable-read
  # transaction so the six tables are read at once.
  defp digest(conn) do
    %{rows: [[present?]]} =
      Postgrex.query!(conn, "SELECT to_regclass('public.route_changes') IS NOT NULL", [])

    if present? do
      Map.new(@routing_tables, fn table ->
        Postgrex.query!(
          conn,
          ~s|DECLARE routing_digest NO SCROLL CURSOR FOR SELECT md5(to_jsonb(r)::text) FROM "#{table}" AS r ORDER BY r.id|,
          []
        )

        {n, hash} = digest_rows(conn, {0, :crypto.hash_init(:sha256)})
        Postgrex.query!(conn, "CLOSE routing_digest", [])
        {table, [n, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)]}
      end)
    end
  end

  defp digest_rows(conn, {n, hash}) do
    case Postgrex.query!(conn, "FETCH FORWARD 5000 FROM routing_digest", []) do
      %{rows: []} ->
        {n, hash}

      %{rows: rows} ->
        rows
        |> Enum.reduce({n, hash}, fn [row], {n, hash} ->
          {n + 1, :crypto.hash_update(hash, [row, ?\n])}
        end)
        |> then(&digest_rows(conn, &1))
    end
  end

  @doc """
  Snapshots `config[:database]` to `path` and records beside it
  (`path <> ".routing.json"`) the digest of exactly the routing rows the dump
  contains.

  Exact because both come from one database snapshot: a repeatable-read
  transaction exports its snapshot, reads the digest, and `pg_dump` dumps
  under the same snapshot while the transaction stays open.

  The dump and its sidecar are each written to a partial file and renamed
  into place only when complete, the dump first. A snapshot that fails leaves
  an earlier one at `path` exactly as it was, still restorable. At no moment
  does a sidecar vouch for bytes it does not describe: between the two
  renames, the old sidecar's recorded SHA-256 no longer matches, and a
  restore refuses.
  """
  def snapshot!(config, path) do
    config = Snapshot.resolve(config)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    partial = path <> ".partial"
    File.rm(partial)
    File.rm(digest_path(path) <> ".partial")

    # The source as its server reports it; a snapshot whose source cannot be
    # established would be one no restore can trust.
    source =
      case Snapshot.database_identity(config) do
        {:ok, %{database_oid: oid} = source} when is_integer(oid) -> source
        {:ok, _} -> raise "cannot snapshot #{config[:database]}: it does not exist"
        {:error, reason} -> raise "cannot snapshot #{config[:database]}: #{reason}"
      end

    digest =
      connected(connection(config), fn conn ->
        {:ok, digest} =
          Postgrex.transaction(
            conn,
            fn conn ->
              Postgrex.query!(
                conn,
                "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
                []
              )

              %{rows: [[snapshot]]} = Postgrex.query!(conn, "SELECT pg_export_snapshot()", [])
              digest = digest(conn)
              Snapshot.dump!(config, partial, snapshot: snapshot)
              digest
            end,
            timeout: :infinity
          )

        digest
      end)

    {host, port, database} = identity(config)
    sidecar = digest_path(path) <> ".partial"

    File.write!(
      sidecar,
      Jason.encode!(%{
        "format" => 2,
        "source" => %{
          "system_identifier" => source.system_identifier,
          "database" => source.database,
          "database_oid" => source.database_oid
        },
        # The endpoint it was taken through, for a reader; identity is `source`.
        "database" => database,
        "host" => host,
        "port" => port,
        "digest" => digest,
        "dump" => Snapshot.fingerprint(partial)
      })
    )

    File.rename!(partial, path)
    File.rename!(sidecar, digest_path(path))
    path
  end

  defp digest_path(path), do: Snapshot.sidecar_path(path)

  @doc """
  `:ok` if `action` may destroy `config[:database]`: it holds no durable
  routing state, or `snapshot` names a `snapshot!/2` of that same database
  that contains every routing table and whose recorded routing digest equals
  the database's now — no committed routing change since. Otherwise
  `{:error, message}` explaining the supported alternative.
  """
  def guard(config, action, snapshot) do
    config = Snapshot.resolve(config)

    # A config that names no database cannot be checked, so it is refused:
    # the destructive task might still resolve one by another route.
    if is_binary(config[:database]) do
      case durable_state(config) do
        nil -> :ok
        state -> covered(config, action, state, snapshot)
      end
    else
      {:error, "refusing to #{action}: the configuration names no database to check"}
    end
  end

  defp covered(config, action, state, nil),
    do: {:error, refusal(config[:database], action, state)}

  defp covered(config, action, state, path) do
    database = config[:database]
    recorded = recorded(path)

    cond do
      not File.regular?(path) ->
        {:error, "#{action}: no snapshot at #{path}"}

      is_nil(recorded) ->
        {:error,
         "#{action}: #{path} has no routing digest beside it; take it with `mix dd.snapshot`"}

      # Checked before `pg_restore --list` reads the file: a damaged dump can
      # still list every table.
      recorded["dump"] != Snapshot.fingerprint(path) ->
        {:error,
         "#{action}: #{path} is not the dump its routing digest was taken with (size or SHA-256 differ)"}

      (missing = missing_tables(path)) != [] ->
        {:error, "#{action}: #{path} does not contain #{Enum.join(missing, ", ")}"}

      (mismatch = source_mismatch(config, path)) != nil ->
        {:error, "#{action}: #{path} #{mismatch}"}

      recorded["digest"] != state.digest ->
        {:error,
         "#{action}: #{database}'s routing state has changed since #{path} was taken; snapshot it again"}

      true ->
        :ok
    end
  end

  # A snapshot covers only the database it was taken from, as the server
  # identifies both: nil when it does, otherwise why not.
  defp source_mismatch(config, path) do
    with {:ok, source} <- Snapshot.source(path),
         {:ok, target} <- Snapshot.database_identity(config) do
      if Snapshot.same_database?(source, target),
        do: nil,
        else:
          "is a snapshot of #{source.database} (cluster #{source.system_identifier}), " <>
            "not #{target.database} (cluster #{target.system_identifier})"
    else
      {:error, reason} -> "cannot be tied to #{config[:database]}: #{inspect(reason)}"
    end
  end

  defp recorded(path) do
    with {:ok, json} <- File.read(digest_path(path)),
         {:ok, %{"digest" => digest} = recorded} when is_map(digest) <- Jason.decode(json) do
      recorded
    else
      _ -> nil
    end
  end

  defp missing_tables(path),
    do: @routing_tables |> MapSet.new() |> MapSet.difference(Snapshot.tables(path)) |> Enum.sort()

  defp refusal(database, action, state) do
    rows = Enum.map_join(state.counts, ", ", fn {table, n} -> "#{table} #{n}" end)

    """
    refusing to #{action} #{database}: it holds durable routing state (#{rows}).

    Pages, classification decisions and the address ledger reference registry
    object ids, and a rebuild from sources renumbers every object. They cannot be
    regenerated, only restored. The supported recovery is in
    docs/routing/recovery.md: snapshot, restore into a separate database, verify
    with `mix dd.routing.verify`, then re-project with `mix dd.materialize --all --resolve`.

    To proceed anyway, snapshot this database first and name it:

        mix dd.snapshot --out PATH
        ... --routing-snapshot PATH     (or DD_ROUTING_SNAPSHOT=PATH for mix ecto.drop)
    """
  end
end
