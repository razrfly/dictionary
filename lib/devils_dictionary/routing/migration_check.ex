defmodule DevilsDictionary.Routing.MigrationCheck do
  @moduledoc """
  Proof that migrating a restored copy of the corpus changed nothing it
  already held, and added exactly what the migrations add (#194, Stage 2).

  What the migrations add is never listed by hand. It is derived from a
  **reference**: an empty database migrated over the same range of versions.
  The copy must add the same migrations, schema rows, sequences and tables,
  with the same contents, as the reference did — and leave every table it
  already had byte-identical. So one check is exact for any boundary made of
  schema additions: the historical routing-only reproduction (`--to
  20260926193256`) and current main, whatever it adds after routing.

  A migration that rewrites rows a table already held — a backfill — cannot
  be judged this way, because the reference has no rows to rewrite. The copy
  reports it under `pre_existing_tables_changed` and fails; such a migration
  needs a check of its own.

  `capture/1` reads a database (`Recovery.manifest/1`, its routing state and
  its migration history); `compare/4` judges four captures. Both only read.
  """

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  @doc "A database's manifest, routing state and migration history."
  def capture(database) do
    Recovery.with_database(database, fn ->
      %{
        database: database,
        manifest: Recovery.manifest(),
        routing: Recovery.routing_schema(),
        migrations:
          Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
          |> List.flatten()
      }
    end)
  end

  @doc """
  Judges a copy's migration, from its captures `before` and `now`, against
  a reference's `ref_before` and `ref_after`. Returns a report whose
  `"pass"` is true only when:

    * the reference started at the copy's migration history;
    * the copy added at least one migration and removed none;
    * every table the copy already had is byte-identical;
    * the copy's delta — migrations, schema rows, sequences, tables added
      and removed — equals the reference's exactly;
    * every table added holds exactly what it holds in the reference.
  """
  def compare(before, now, ref_before, ref_after) do
    copy = delta(before, now)
    reference = delta(ref_before, ref_after)
    same_start? = ref_before.migrations == before.migrations

    changed =
      for t <- tables(before),
          fingerprint(before.manifest[t]) != fingerprint(now.manifest[t]),
          do: t

    added_contents =
      for t <- copy.tables_added,
          fingerprint(now.manifest[t]) != fingerprint(ref_after.manifest[t]),
          do: t

    mismatches =
      for {key, value} <- copy, value != reference[key], into: %{} do
        {Atom.to_string(key),
         %{"copy_only" => value -- reference[key], "reference_only" => reference[key] -- value}}
      end

    pass? =
      same_start? and copy.migrations_added != [] and copy.migrations_removed == [] and
        changed == [] and mismatches == %{} and added_contents == []

    %{
      "pass" => pass?,
      "database" => now.database,
      "reference" => ref_after.database,
      "reference_starts_where_the_copy_started" => same_start?,
      "migrations_before" => List.last(before.migrations),
      "migrations_after" => List.last(now.migrations),
      "migrations_added" => copy.migrations_added,
      "routing_before" => inspect(before.routing),
      "routing_after" => inspect(now.routing),
      "pre_existing_tables" => length(tables(before)),
      "pre_existing_rows" =>
        before |> tables() |> Enum.map(&before.manifest[&1].count) |> Enum.sum(),
      "pre_existing_tables_changed" => changed,
      "tables_added" => copy.tables_added,
      "tables_added_with_other_contents_than_the_reference" => added_contents,
      "schema_rows_added" => length(copy.schema_added),
      "schema_rows_removed" => length(copy.schema_removed),
      "sequences_added" => Enum.map(copy.sequences_added, &Jason.decode!/1),
      "differences_from_the_reference_delta" => mismatches
    }
  end

  defp tables(state), do: Map.keys(state.manifest) -- ["schema", "sequences", "schema_migrations"]

  defp fingerprint(nil), do: nil
  defp fingerprint(section), do: Map.take(section, [:count, :sha256])

  defp rows(state, section), do: state.manifest[section].rows

  defp delta(before, after_) do
    %{
      migrations_added: after_.migrations -- before.migrations,
      migrations_removed: before.migrations -- after_.migrations,
      schema_added: Enum.sort(rows(after_, "schema") -- rows(before, "schema")),
      schema_removed: Enum.sort(rows(before, "schema") -- rows(after_, "schema")),
      sequences_added: Enum.sort(rows(after_, "sequences") -- rows(before, "sequences")),
      sequences_removed: Enum.sort(rows(before, "sequences") -- rows(after_, "sequences")),
      tables_added: Enum.sort(tables(after_) -- tables(before)),
      tables_removed: Enum.sort(tables(before) -- tables(after_))
    }
  end
end
