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

  # Operational queue state, not registry or routing: jobs and node heartbeats.
  @unmanifested ~w(oban_jobs oban_peers)

  # What re-projecting unchanged source records legitimately rewrites: its own
  # runs, and the stamps that say when a record was last materialized and by
  # which run. Everything else must be identical after `dd.materialize --all`.
  @projection_tables ~w(import_runs)
  @projection_columns ~w(updated_at materialized_at last_seen_run_id)

  # Values hashed rather than compared verbatim: bodies and payloads.
  @hashed ~r/^(text|json|jsonb|bytea)(\[\])?$/

  def routing_tables, do: @routing_tables

  @doc """
  The manifest of the current repo's database.

  Options:

    * `mode: :exact` (default) — every column, every sequence; what a restore
      must reproduce byte for byte.
    * `mode: :projected` — after `mix dd.materialize --all` on a restored copy:
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
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
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
            do: Map.put(sections, "sequences", capture(sequence_sql(), opts)),
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
      Repo.query!("""
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
      Repo.query!("""
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
  # amended migration is a difference too.
  defp schema(opts) do
    %{rows: rows} = Repo.query!(schema_sql())

    rows
    |> Enum.map(fn [kind, name, definition] ->
      Jason.encode!([kind, name, canonical(definition)])
    end)
    |> summarize(opts)
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

  defp schema_sql do
    """
    SELECT kind, name, definition FROM (
      SELECT 'constraint' AS kind, conrelid::regclass::text || '.' || conname AS name,
             pg_get_constraintdef(oid) AS definition
        FROM pg_constraint WHERE connamespace = 'public'::regnamespace
      UNION ALL
      SELECT 'index', indexrelid::regclass::text, pg_get_indexdef(indexrelid)
        FROM pg_index WHERE indrelid IN (
          SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
      UNION ALL
      SELECT 'trigger', tgrelid::regclass::text || '.' || tgname, pg_get_triggerdef(oid)
        FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN (
          SELECT oid FROM pg_class WHERE relnamespace = 'public'::regnamespace)
      UNION ALL
      SELECT 'function', oid::regprocedure::text, md5(pg_get_functiondef(oid))
        FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND prokind = 'f'
    ) AS definitions
    ORDER BY kind COLLATE "C", name COLLATE "C"
    """
  end

  defp sequence_sql do
    """
    SELECT json_build_array(sequencename, last_value)::text FROM pg_sequences
     WHERE schemaname = 'public' ORDER BY sequencename COLLATE "C"
    """
  end

  # A server-side cursor, fetched in batches: constant memory at corpus
  # scale, and — unlike `Ecto.Adapters.SQL.stream/4` — it follows a dynamic
  # repo, so the same code reads a restored copy.
  defp capture(sql, opts) do
    keep? = Keyword.get(opts, :rows, false)
    Repo.query!("DECLARE routing_manifest NO SCROLL CURSOR FOR #{sql}")
    {count, hash, rows} = fetch({0, :crypto.hash_init(:sha256), []}, keep?)
    Repo.query!("CLOSE routing_manifest")

    %{
      count: count,
      sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
      rows: if(keep?, do: Enum.reverse(rows))
    }
  end

  defp fetch(acc, keep?) do
    case Repo.query!("FETCH FORWARD 5000 FROM routing_manifest") do
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
  Compares the current repo's database with `baseline`: every manifest
  section, what every path and page id resolves to, and the sequences. With
  `projected: true` — after `mix dd.materialize --all` — the manifest is taken
  in `:projected` mode and the sequences need only not have fallen behind
  their tables. Neither database is modified.

  Returns `{:ok, report}` or `{:error, report}`.
  """
  def verify(baseline, opts \\ []) do
    mode = if Keyword.get(opts, :projected, false), do: :projected, else: :exact
    manifest_opts = [mode: mode, rows: Keyword.get(opts, :rows, false)]

    {expected, expected_resolutions} =
      with_database(baseline, fn -> {manifest(manifest_opts), resolutions()} end)

    actual = manifest(manifest_opts)

    report = %{
      sections: Map.new(actual, fn {section, %{count: n}} -> {section, n} end),
      differences: diff(expected, actual),
      missing_sections: Enum.sort(Map.keys(expected) -- Map.keys(actual)),
      extra_sections: Enum.sort(Map.keys(actual) -- Map.keys(expected)),
      resolutions_match: expected_resolutions == resolutions(),
      sequences_behind: sequences_behind()
    }

    exact? =
      report.differences == %{} and report.missing_sections == [] and
        report.extra_sections == [] and report.resolutions_match and
        report.sequences_behind == []

    if exact?, do: {:ok, report}, else: {:error, report}
  end

  @doc """
  Sequences whose next value their table already holds — `last_value + 1`
  once called, `last_value` before — for every sequence a table column owns.
  """
  def sequences_behind do
    %{rows: owned} =
      Repo.query!("""
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
        Repo.query!(~s|SELECT last_value, is_called FROM "#{sequence}"|)

      %{rows: [[max]]} = Repo.query!(~s|SELECT coalesce(max("#{column}"), 0) FROM "#{table}"|)
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
  Runs `fun` with `Repo` pointed at `database`, through a short-lived pool of
  its own. The configured database, and any other process, is untouched.
  """
  def with_database(database, fun) do
    config =
      Keyword.merge(Repo.config(),
        name: nil,
        database: database,
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

  # ── snapshots and the guard on destructive tasks ─────────────────────────

  @doc """
  Durable routing state in a database — row counts and a digest of every
  routing row — or `nil` if it has none, does not exist, or predates the
  routing tables. Connects directly, so it works before the application
  starts, and reads in one repeatable-read snapshot.
  """
  def durable_state(config) do
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
  # a ledger write, a publication change, anything — changes it. Must run
  # inside a repeatable-read transaction so the six tables are read at once.
  defp digest(conn) do
    %{rows: [[present?]]} =
      Postgrex.query!(conn, "SELECT to_regclass('public.route_changes') IS NOT NULL", [])

    if present? do
      Map.new(@routing_tables, fn table ->
        %{rows: [[n, md5]]} =
          Postgrex.query!(
            conn,
            ~s|SELECT count(*), md5(coalesce(string_agg(to_jsonb(r)::text, E'\\n' ORDER BY r.id), '')) FROM "#{table}" AS r|,
            []
          )

        {table, [n, md5]}
      end)
    end
  end

  @doc """
  Snapshots `config[:database]` to `path` and records beside it
  (`path <> ".routing.json"`) the digest of exactly the routing rows the dump
  contains.

  Exact because both come from one database snapshot: a repeatable-read
  transaction exports its snapshot, reads the digest, and `pg_dump` dumps
  under the same snapshot while the transaction stays open. The dump is
  written to a partial file and renamed only when complete, and any older
  sidecar is removed first, so a failed dump never leaves a sidecar beside it.
  """
  def snapshot!(config, path) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    partial = path <> ".partial"
    File.rm(digest_path(path))
    File.rm(partial)

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

    File.rename!(partial, path)

    File.write!(
      digest_path(path),
      Jason.encode!(%{"database" => config[:database], "digest" => digest})
    )

    path
  end

  defp digest_path(path), do: path <> ".routing.json"

  @doc """
  `:ok` if `action` may destroy `config[:database]`: it holds no durable
  routing state, or `snapshot` names a `snapshot!/2` of that same database
  that contains every routing table and whose recorded routing digest equals
  the database's now — no committed routing change since. Otherwise
  `{:error, message}` explaining the supported alternative.
  """
  def guard(config, action, snapshot) do
    case durable_state(config) do
      nil -> :ok
      state -> covered(config[:database], action, state, snapshot)
    end
  end

  defp covered(database, action, state, nil), do: {:error, refusal(database, action, state)}

  defp covered(database, action, state, path) do
    missing = MapSet.difference(MapSet.new(@routing_tables), tables_in(path))
    recorded = recorded(path)

    cond do
      not File.regular?(path) ->
        {:error, "#{action}: no snapshot at #{path}"}

      MapSet.size(missing) > 0 ->
        {:error, "#{action}: #{path} does not contain #{Enum.join(missing, ", ")}"}

      is_nil(recorded) ->
        {:error,
         "#{action}: #{path} has no routing digest beside it; take it with `mix dd.snapshot`"}

      recorded["database"] != database ->
        {:error, "#{action}: #{path} is a snapshot of #{recorded["database"]}, not #{database}"}

      recorded["digest"] != state.digest ->
        {:error,
         "#{action}: #{database}'s routing state has changed since #{path} was taken; snapshot it again"}

      true ->
        :ok
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

  defp tables_in(path) do
    if File.regular?(path), do: Snapshot.tables(path), else: MapSet.new()
  end

  defp refusal(database, action, state) do
    rows = Enum.map_join(state.counts, ", ", fn {table, n} -> "#{table} #{n}" end)

    """
    refusing to #{action} #{database}: it holds durable routing state (#{rows}).

    Pages, classification decisions and the address ledger reference registry
    object ids, and a rebuild from sources renumbers every object. They cannot be
    regenerated, only restored. The supported recovery is in
    docs/routing/recovery.md: snapshot, restore into a separate database, verify
    with `mix dd.routing.verify`, then re-project with `mix dd.materialize --all`.

    To proceed anyway, snapshot this database first and name it:

        mix dd.snapshot --out PATH
        ... --routing-snapshot PATH     (or DD_ROUTING_SNAPSHOT=PATH for mix ecto.drop)
    """
  end
end
