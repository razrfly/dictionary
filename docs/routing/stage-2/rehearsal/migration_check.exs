# Stage 2A, step 3: prove the routing migration leaves the captured corpus
# exactly as it was, and adds only the routing schema.
#
#   DD_STAGE2A_REHEARSAL=1 DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 \
#     mix run --no-start docs/routing/stage-2/rehearsal/migration_check.exs capture BEFORE.bin
#   (mix ecto.migrate on the same copy)
#   ... migration_check.exs compare BEFORE.bin REPORT.json
#
# Starts no application. Read-only.
Code.require_file("guard.exs", __DIR__)

alias DevilsDictionary.Repo
alias DevilsDictionary.Routing.Recovery

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{_host, _port, database} = Stage2A.Guard.check!(oban: false)

capture = fn ->
  Recovery.with_database(database, fn ->
    %{
      manifest: Recovery.manifest(),
      routing: Recovery.routing_schema(),
      migrations: Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows |> List.flatten()
    }
  end)
end

case System.argv() do
  ["capture", out] ->
    state = capture.()
    File.write!(out, :erlang.term_to_binary(state))
    IO.puts("captured #{map_size(state.manifest)} sections, routing #{inspect(state.routing)}, migrations #{length(state.migrations)}")

  ["compare", before_path, report_path] ->
    before = before_path |> File.read!() |> :erlang.binary_to_term()
    now = capture.()
    b = before.manifest
    a = now.manifest

    routing_tables = Recovery.routing_tables()
    pre_existing = Map.keys(b) -- ["schema", "sequences", "schema_migrations"]

    # 1. Every pre-existing table: the same rows, count and hash.
    fingerprint = fn section -> section && Map.take(section, [:count, :sha256]) end
    changed = for t <- pre_existing, fingerprint.(b[t]) != fingerprint.(a[t]), do: t

    # 2. New sections are exactly the six routing tables, all empty.
    added_sections = Map.keys(a) -- Map.keys(b)
    removed_sections = Map.keys(b) -- Map.keys(a)
    empty_routing? = Enum.all?(routing_tables, &(a[&1] && a[&1].count == 0))

    # 3. Migrations: exactly one added, the routing foundation.
    added_migrations = now.migrations -- before.migrations
    removed_migrations = before.migrations -- now.migrations

    # 4. Schema and sequences: nothing changed or removed; additions only,
    #    and only the routing schema's.
    schema_removed = b["schema"].rows -- a["schema"].rows
    schema_added = a["schema"].rows -- b["schema"].rows
    seq_removed = b["sequences"].rows -- a["sequences"].rows
    seq_added = a["sequences"].rows -- b["sequences"].rows

    # Every object the migration adds belongs to a routing table, or is one
    # of its `routing_*` functions.
    routing_name? = fn row ->
      [_kind, name, _definition] = Jason.decode!(row)
      Enum.any?(routing_tables, &String.starts_with?(name, &1)) or String.starts_with?(name, "routing_")
    end

    foreign_additions = Enum.reject(schema_added, routing_name?)

    seq_foreign =
      Enum.reject(seq_added, fn row ->
        [name, _last, called?] = Jason.decode!(row)
        Enum.any?(routing_tables, &String.starts_with?(name, &1 <> "_")) and called? == false
      end)

    report = %{
      "database" => database,
      "routing_before" => inspect(before.routing),
      "routing_after" => inspect(now.routing),
      "pre_existing_sections" => length(pre_existing),
      "pre_existing_sections_changed" => changed,
      "sections_added" => Enum.sort(added_sections),
      "sections_removed" => removed_sections,
      "routing_tables_empty" => empty_routing?,
      "migrations_added" => added_migrations,
      "migrations_removed" => removed_migrations,
      "schema_rows_before" => length(b["schema"].rows),
      "schema_rows_after" => length(a["schema"].rows),
      "schema_rows_removed_or_changed" => schema_removed,
      "schema_rows_added" => length(schema_added),
      "schema_rows_added_outside_routing" => foreign_additions,
      "sequences_removed_or_changed" => seq_removed,
      "sequences_added" => Enum.map(seq_added, &Jason.decode!/1),
      "sequences_added_outside_routing_or_used" => seq_foreign,
      "table_rows_compared" => pre_existing |> Enum.map(&b[&1].count) |> Enum.sum()
    }

    pass? =
      changed == [] and Enum.sort(added_sections) == Enum.sort(routing_tables) and removed_sections == [] and
        empty_routing? and added_migrations == [20_260_926_193_256] and removed_migrations == [] and
        schema_removed == [] and foreign_additions == [] and seq_removed == [] and seq_foreign == [] and
        before.routing == :absent and now.routing == :present

    report = Map.put(report, "pass", pass?)
    File.write!(report_path, Jason.encode_to_iodata!(report, pretty: true))
    IO.puts(if pass?, do: "PASS: the migration preserved every pre-existing section", else: "FAIL: see #{report_path}")
    unless pass?, do: System.halt(1)
end
