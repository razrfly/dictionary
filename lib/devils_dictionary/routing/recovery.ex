defmodule DevilsDictionary.Routing.Recovery do
  @moduledoc """
  What recovery must preserve, how to check it, and what may not destroy it
  (ADR 0004 §8; procedure in `docs/routing/recovery.md`).

  Registry identities and routing state exist only in the database. A rebuild
  from sources renumbers every object, so pages, decisions and the address
  ledger cannot be regenerated. They can only be restored — whole, with the
  registry they reference — and then re-projected from source records.

    * `manifest/1` — every registry identity and every routing row, by exact
      id and reference, hashed section by section in one repeatable-read
      snapshot. Counts alone would miss a renumbered object.
    * `resolutions/0` — what every stored path and every page id resolves to.
    * `diff/2` — the sections two manifests disagree on.
    * `with_database/2` — runs code against another database, for comparing a
      restored copy with its source without touching either's configuration.
    * `snapshot!/2` — a snapshot with the routing high-water marks it covers.
    * `guard/3` — whether a destructive task may run against a database that
      holds durable routing state.
  """

  import Ecto.Query

  alias DevilsDictionary.{Repo, Snapshot}
  alias DevilsDictionary.Routing.{Address, Page, PublicPath, Resolution, Resolver}

  @routing_tables ~w(pages page_revisions page_memberships public_paths classification_decisions route_changes)

  # Each section is an exact, ordered projection of identity and reference
  # columns. Bodies are hashed; bookkeeping timestamps are left out except on
  # append-only history, where the time is part of the record.
  @sections [
    {"objects", "id", "id, kind, lifecycle_state"},
    {"entities", "object_id", "object_id, entity_kind, preferred_label"},
    {"lexemes", "object_id", "object_id, lexical_key, slug"},
    {"senses", "object_id", "object_id, lexeme_id, source_id, external_key, identity_state"},
    {"sense_revisions", "id",
     "id, sense_id, revision_number, md5(coalesce(gloss, '')), lifecycle_state, is_current"},
    {"content_items", "object_id", "object_id, content_kind, source_id"},
    {"content_revisions", "id",
     "id, content_id, revision_number, md5(coalesce(body, '')), lifecycle_state, is_current"},
    {"external_identifiers", "id", "id, object_id, namespace, external_id, status"},
    {"object_names", "id", "id, object_id, name, name_kind, language_tag"},
    {"identity_events", "id", "id, operation, actor_id, reason"},
    {"identity_event_members", "event_id, object_id, role", "event_id, object_id, role"},
    {"assertions", "id", "id, source_id, origin_key"},
    {"assertion_revisions", "id",
     "id, assertion_id, revision_number, subject_object_id, predicate_id, object_object_id, lifecycle_state, is_current"},
    {"actors", "id", "id, actor_kind, user_id, bot_source_id, entity_id"},
    {"sources", "id", "id, slug"},
    {"pages", "id",
     "id, role, locale, target_object_id, publication_state, lifecycle_state, merged_into_page_id, current_revision_id, canonical_path_id, last_route_change_id"},
    {"page_revisions", "id",
     "id, page_id, revision_number, title, md5(coalesce(body, '')), body_format, author_actor_id, reviewer_actor_id, evidence, membership_count, inserted_at"},
    {"page_memberships", "id",
     "id, page_id, page_revision_id, position, relationship, target_object_id, target_page_id, rationale, evidence"},
    {"classification_decisions", "id",
     "id, object_id, origin, status, family, candidate_families, rule_ids, reasons, warnings, policy_version, evidence_fingerprint, source_pins, reviewer_actor_id, reason, supersedes_id, is_current, inserted_at"},
    {"public_paths", "id",
     "id, path, kind, original_page_id, destination_page_id, last_route_change_id"},
    {"route_changes", "id",
     "id, operation_id, sequence, operation, path_id, before_kind, after_kind, before_destination_id, after_destination_id, page_id, before_lifecycle, after_lifecycle, before_canonical_path_id, after_canonical_path_id, before_merged_into_id, after_merged_into_id, before_revision_id, after_revision_id, classification_decision_id, policy_version, actor_id, reason, reverts_operation_id, details, inserted_at"}
  ]

  # The next ids these hand out. Equal right after a restore; afterwards only
  # required never to fall behind their table.
  @sequences [
    {"objects_id_seq", "objects"},
    {"actors_id_seq", "actors"},
    {"identity_events_id_seq", "identity_events"},
    {"pages_id_seq", "pages"},
    {"page_revisions_id_seq", "page_revisions"},
    {"page_memberships_id_seq", "page_memberships"},
    {"public_paths_id_seq", "public_paths"},
    {"classification_decisions_id_seq", "classification_decisions"},
    {"route_changes_id_seq", "route_changes"}
  ]

  def routing_tables, do: @routing_tables
  def section_names, do: Enum.map(@sections, &elem(&1, 0)) ++ ["sequences"]

  @doc """
  The exact manifest of the current repo's database.

  Options: `rows: true` keeps every row (for exact differences in tests),
  `sequences: false` leaves the sequence section out (after a re-projection,
  whose upserts may consume ids without writing rows).
  """
  def manifest(opts \\ []) do
    {:ok, manifest} =
      Repo.transaction(
        fn ->
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

          sections =
            Map.new(@sections, fn {table, key, columns} ->
              {table,
               capture(
                 "SELECT json_build_array(#{columns})::text FROM #{table} ORDER BY #{key}",
                 opts
               )}
            end)

          if Keyword.get(opts, :sequences, true),
            do: Map.put(sections, "sequences", capture(sequence_sql(), opts)),
            else: sections
        end,
        timeout: :infinity
      )

    manifest
  end

  defp sequence_sql do
    names = Enum.map_join(@sequences, ",", fn {sequence, _table} -> "'#{sequence}'" end)

    """
    SELECT json_build_array(sequencename, last_value)::text FROM pg_sequences
     WHERE schemaname = 'public' AND sequencename IN (#{names}) ORDER BY sequencename
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
  were kept. Sections present in only one manifest are ignored.
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
  Compares the current repo's database with `baseline`, exactly: every
  manifest section, what every path and page id resolves to, and the
  sequences. With `projected: true` — after `mix dd.materialize --all` — the
  sequences need only not have fallen behind their tables, because upserts
  may consume ids without writing rows. Neither database is modified.

  Returns `{:ok, report}` or `{:error, report}`.
  """
  def verify(baseline, opts \\ []) do
    projected? = Keyword.get(opts, :projected, false)
    manifest_opts = [sequences: not projected?, rows: Keyword.get(opts, :rows, false)]

    {expected, expected_resolutions} =
      with_database(baseline, fn -> {manifest(manifest_opts), resolutions()} end)

    actual = manifest(manifest_opts)

    report = %{
      sections: Map.new(actual, fn {section, %{count: n}} -> {section, n} end),
      differences: diff(expected, actual),
      missing_sections: Enum.sort(Map.keys(expected) -- Map.keys(actual)),
      resolutions_match: expected_resolutions == resolutions(),
      sequences_behind: sequences_behind()
    }

    exact? =
      report.differences == %{} and report.missing_sections == [] and report.resolutions_match and
        report.sequences_behind == []

    if exact?, do: {:ok, report}, else: {:error, report}
  end

  @doc "Sequences that would hand out an id their table already holds."
  def sequences_behind do
    Enum.flat_map(@sequences, fn {sequence, table} ->
      %{rows: [[last, max]]} =
        Repo.query!(
          "SELECT (SELECT last_value FROM #{sequence}), (SELECT coalesce(max(id), 0) FROM #{table})"
        )

      if last < max, do: [{sequence, last, max}], else: []
    end)
  end

  @doc """
  What every stored path and every page id resolves to, in order: outcome,
  page id, location and successor page ids.
  """
  def resolutions do
    paths = Repo.all(from p in PublicPath, order_by: p.path, select: p.path)
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

  # ── the guard on destructive tasks ───────────────────────────────────────

  @doc """
  Durable routing state in a database, or `nil` if it has none (or does not
  exist, or predates the routing tables). Connects directly, so it works before
  the application starts.
  """
  def durable_state(config) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    connection =
      Keyword.take(config, [:hostname, :port, :username, :password, :database, :socket_dir])

    maintenance = Keyword.put(connection, :database, config[:maintenance_database] || "postgres")

    exists? =
      connected(maintenance, fn conn ->
        Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [
          config[:database]
        ]).num_rows == 1
      end)

    if exists?, do: connected(connection, &state/1)
  end

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
    %{rows: [[present?]]} =
      Postgrex.query!(conn, "SELECT to_regclass('public.route_changes') IS NOT NULL", [])

    if present? do
      counts =
        Map.new(@routing_tables, fn table ->
          %{rows: [[n]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{table}", [])
          {table, n}
        end)

      if Enum.all?(counts, fn {_table, n} -> n == 0 end),
        do: nil,
        else: %{counts: counts, marks: marks(conn)}
    end
  end

  # Routing high-water marks: the highest id in each append-only or ledgered
  # table, and the last page update (publication is not on the ledger). Any
  # routing write moves at least one.
  defp marks(conn) do
    ids =
      Map.new(@routing_tables, fn table ->
        %{rows: [[max]]} = Postgrex.query!(conn, "SELECT coalesce(max(id), 0) FROM #{table}", [])
        {table, max}
      end)

    %{rows: [[updated]]} =
      Postgrex.query!(conn, "SELECT max(updated_at)::text FROM pages", [])

    Map.put(ids, "pages_updated_at", updated)
  end

  @doc """
  Snapshots `config[:database]` to `path` with `DevilsDictionary.Snapshot`,
  and records beside it (`path <> ".routing.json"`) the routing high-water
  marks it covers. The marks are read *before* the dump starts, so a routing
  write racing the dump makes the snapshot look older, never newer: the guard
  then refuses, which is the safe side.
  """
  def snapshot!(config, path) do
    marks = with_state(config, fn state -> state && state.marks end)
    Snapshot.dump!(config, path)

    File.write!(
      marks_path(path),
      Jason.encode!(%{"database" => config[:database], "marks" => marks})
    )

    path
  end

  defp with_state(config, fun), do: fun.(durable_state(config))
  defp marks_path(path), do: path <> ".routing.json"

  @doc """
  `:ok` if `action` may destroy `config[:database]`: it holds no durable
  routing state, or `snapshot` names a `snapshot!/2` of it that contains every
  routing table and whose recorded high-water marks equal the database's now —
  no routing write since. Otherwise `{:error, message}` explaining the
  supported alternative.
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
    recorded = recorded_marks(path)

    cond do
      not File.regular?(path) ->
        {:error, "#{action}: no snapshot at #{path}"}

      MapSet.size(missing) > 0 ->
        {:error, "#{action}: #{path} does not contain #{Enum.join(missing, ", ")}"}

      is_nil(recorded) ->
        {:error,
         "#{action}: #{path} has no routing marks beside it; take it with `mix dd.snapshot`"}

      recorded != state.marks ->
        {:error,
         "#{action}: #{database} has routing writes after #{path} was taken; snapshot it again"}

      true ->
        :ok
    end
  end

  defp recorded_marks(path) do
    with {:ok, json} <- File.read(marks_path(path)),
         {:ok, %{"marks" => marks}} when is_map(marks) <- Jason.decode(json) do
      marks
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
        ... --routing-snapshot PATH
    """
  end
end
