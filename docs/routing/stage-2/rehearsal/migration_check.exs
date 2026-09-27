# Stage 2 rehearsal: prove that migrating a restored copy of the corpus left
# every pre-existing section exactly as it was, and added exactly what the
# migrations add — no more, no less.
#
# What the migrations add is not listed by hand. It is derived from a
# reference: an empty database migrated over the same range of versions. The
# copy must add the same migrations, the same schema rows, the same new
# sequences and the same new tables with the same contents as the reference
# did, and change nothing else. So the check is exact for any boundary:
#
#   * the historical routing-only reproduction, pinned with
#     `mix ecto.migrate --to 20260926193256`;
#   * current main, whatever it adds after routing (#206's curation schema).
#
#   # the reference (empty; created with `mix ecto.create`)
#   DD_DATABASE=devils_dictionary_stage2a_reference … mix ecto.migrate --to SOURCE_VERSION
#   … migration_check.exs capture REF_BEFORE.bin
#   DD_DATABASE=devils_dictionary_stage2a_reference … mix ecto.migrate [--to TARGET]
#   … migration_check.exs capture REF_AFTER.bin
#
#   # the copy
#   … migration_check.exs capture BEFORE.bin
#   DD_DATABASE=<copy> … mix ecto.migrate [--to TARGET]
#   … migration_check.exs compare BEFORE.bin REF_BEFORE.bin REF_AFTER.bin REPORT.json
#
# Every command runs with DD_STAGE2A_REHEARSAL=1 DD_DATABASE_PORT=<scratch>
# and `mix run --no-start`. Starts no application; reads only.
Code.require_file("guard.exs", __DIR__)

alias DevilsDictionary.Routing.MigrationCheck

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{_host, _port, database} = Stage2A.Guard.check!(oban: false)
load = fn path -> path |> File.read!() |> :erlang.binary_to_term() end

case System.argv() do
  ["capture", out] ->
    state = MigrationCheck.capture(database)
    File.write!(out, :erlang.term_to_binary(state))

    IO.puts(
      "captured #{database}: #{map_size(state.manifest)} sections, routing #{inspect(state.routing)}, " <>
        "#{length(state.migrations)} migrations, latest #{List.last(state.migrations)}"
    )

  ["compare", before_path, ref_before_path, ref_after_path, report_path] ->
    report =
      MigrationCheck.compare(
        load.(before_path),
        MigrationCheck.capture(database),
        load.(ref_before_path),
        load.(ref_after_path)
      )

    File.write!(report_path, Jason.encode_to_iodata!(report, pretty: true))

    IO.puts(
      if report["pass"],
        do:
          "PASS: #{report["pre_existing_tables"]} pre-existing tables unchanged; added exactly the " <>
            "reference's #{length(report["migrations_added"])} migrations, " <>
            "#{length(report["tables_added"])} tables and #{report["schema_rows_added"]} schema rows",
        else: "FAIL: see #{report_path}"
    )

    unless report["pass"], do: System.halt(1)
end
