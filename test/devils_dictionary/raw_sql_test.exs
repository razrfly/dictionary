defmodule DevilsDictionary.RawSqlTest do
  @moduledoc """
  The guard for the half of this codebase `mix compile` cannot see.

  Three modules are raw SQL against hard-coded table names — `Absorb.Linker`
  entirely, the write halves of `Absorb.Resolver` and `Absorb.ScopeBuilder`, and
  `Health`'s heredocs — and they alias nothing that was deleted. During the #74
  port they compiled clean and would have failed at run time on `entries`,
  `lexical_relations`, `concepts`, `concept_links`, `concept_relations` and the
  silent one: `scope_lexemes`, which became `scope_lexeme_members` with no
  compile error anywhere to say so. Two real defects reached a green build that
  way before this test existed.

  So: no source file may name a table this schema does not have, and every table
  a raw statement does name must exist. The suite exercises most of these
  statements, but "most" is what let the last two through.
  """

  use DevilsDictionary.DataCase, async: true

  # The MVP-0 tables the encyclopedia model retired, and the two renames. A hit
  # is a real defect: nothing in this application may still be reading them.
  @retired ~w(
    entries
    lexical_relations
    concepts
    concept_links
    concept_relations
    people
    scope_lexemes
  )

  # Prose is allowed to say "entries" — the ban is on SQL and on Ecto's
  # string-table form, both of which touch the database.
  @sql_context [
    "FROM TABLE",
    "JOIN TABLE",
    "INTO TABLE",
    "UPDATE TABLE",
    "DELETE FROM TABLE",
    "in \"TABLE\"",
    "TABLE TABLE"
  ]

  describe "no source file reads a retired table" do
    test "not in raw SQL, and not through Ecto's string-table form" do
      offences =
        for path <- sources(),
            contents = File.read!(path),
            table <- @retired,
            pattern <- patterns(table),
            String.contains?(contents, pattern) do
          "#{Path.relative_to_cwd(path)} still names `#{table}` (#{inspect(pattern)})"
        end

      assert offences == [], Enum.join(offences, "\n")
    end
  end

  describe "every table a raw statement names exists" do
    test "including the ones only the linker and the resolver ever touch" do
      existing = table_names()

      missing =
        for path <- sources(),
            contents = File.read!(path),
            # A CTE and a LATERAL alias are named the same way a table is, so
            # the names this file itself defines are subtracted rather than
            # guessed at — a genuinely missing table must not hide behind a
            # loose rule.
            defined = defined_names(contents),
            # A trailing `(` means a set-returning function — `FROM unnest(...)`,
            # `FROM jsonb_array_elements_text(...)` — which is a call, not a
            # table. Captured rather than excluded by a lookahead, because a
            # greedy name would give back a character to satisfy one.
            match <-
              Regex.scan(~r/\b(?:FROM|JOIN|INTO|UPDATE)\s+([a-z_][a-z0-9_]*)(\s*\()?/, contents),
            [name, call] = pad(match),
            call == "",
            name not in keywords(),
            not MapSet.member?(defined, name),
            not MapSet.member?(existing, name),
            uniq: true do
          "#{Path.relative_to_cwd(path)}: #{name}"
        end

      assert missing == [],
             "raw SQL names tables this schema does not have:\n" <> Enum.join(missing, "\n")
    end
  end

  defp sources do
    Path.wildcard("lib/**/*.ex")
  end

  # `Regex.scan/2` drops a trailing optional group when it did not participate.
  defp pad([_full, name]), do: [name, ""]
  defp pad([_full, name, call]), do: [name, call]

  defp patterns(table) do
    Enum.map(@sql_context, &String.replace(&1, "TABLE", table))
  end

  defp table_names do
    Repo.query!("""
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    """)
    |> Map.fetch!(:rows)
    |> Enum.map(&hd/1)
    |> MapSet.new()
  end

  # Every name a file defines for itself: its CTEs (`WITH x AS (`, `, x AS (`,
  # and the recursive `x(cols) AS (` form), its LATERAL subqueries, and the
  # `LATERAL` keyword itself.
  defp defined_names(contents) do
    ctes =
      ~r/\b([a-z_][a-z0-9_]*)\s*(?:\([^)]*\)\s*)?AS\s*\(/
      |> Regex.scan(contents)
      |> Enum.map(&Enum.at(&1, 1))

    laterals =
      ~r/\)\s+([a-z_][a-z0-9_]*)\s+ON\s+(?:TRUE|true)/
      |> Regex.scan(contents)
      |> Enum.map(&Enum.at(&1, 1))

    MapSet.new(["lateral" | ctes ++ laterals])
  end

  # Words that follow FROM or JOIN without naming anything: `DELETE FROM x` is
  # covered above, and a line break can put a bare `AND` after one.
  defp keywords, do: ~w(and or not lateral select)
end
