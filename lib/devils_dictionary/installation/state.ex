defmodule DevilsDictionary.Installation.State do
  @moduledoc """
  The comparison contract of #211 §3, as one captured value and one diff.

  A captured state is everything an installation move must reproduce,
  section by section:

    * **every table, every column**, ordered by primary key (byte order for
      text): registry identities and their references, routing rows,
      curation records and approvals, migration history — and, unlike
      routing recovery, Oban's queue tables, because a moved installation
      keeps its jobs too (`Routing.Recovery.manifest/1` with `queue: true`).
      Bodies (`text`, `json`, `jsonb`, `bytea`) are compared by MD5;
    * **the schema**: owners, column types and collations, constraints and
      indexes with their validity, triggers with whether they fire,
      functions, sequence parameters, policies, object and default
      privileges as granted, extension versions;
    * **every sequence's state**: `last_value` and `is_called`;
    * **routing**: whether the routing tables exist, and what every stored
      path and page id resolves to;
    * **the database itself** (`Installation.Database`): encoding, locale
      provider, collate, ctype, ICU locale and rules, recorded and actual
      collation version, owner, privileges, connection limit, comment and
      database-level settings;
    * **extensions** with their versions and schemas, and the **roles the
      database references** (owners, grantees, roles with settings in it)
      with their attributes — never passwords. A referenced role missing
      from the target is a difference; roles that serve other databases on
      the same cluster are not.

  `capture/2` takes the in-database part under one repeatable-read snapshot,
  or under an exported one (`snapshot:`), so a bundle's state describes
  exactly the rows its dump holds.

  `diff/3` compares two captured states. Its only exclusions are named in
  `@identity_only`: the database's name and oid, which identify a database
  rather than describe it. Initialising another installation from a bundle
  (`ignore: [:name]`) may use another name; nothing else is ever left out.
  """

  alias DevilsDictionary.Installation.Database
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  @format 1

  # A database's identity, not its content.
  @identity_only ~w(name oid)

  @doc """
  The state of the database `target` names (a name on the configured server
  or an `ecto://` URL). Read-only; starts nothing but a short-lived pool.

  Options: `snapshot:` — an exported snapshot id to read under.
  """
  def capture(target, opts \\ []) do
    config = Database.config(target)
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    in_database =
      Recovery.with_database(target, fn ->
        manifest =
          Recovery.manifest(mode: :exact, queue: true, snapshot: opts[:snapshot])

        {routing, resolutions, migrations} = routing(opts[:snapshot])

        %{
          manifest: manifest,
          routing: routing,
          resolutions: resolutions,
          migrations: migrations
        }
      end)

    with {:ok, %{database: properties} = facts} when is_map(properties) <-
           Database.facts(config),
         {:ok, extensions} <- Database.extensions(config),
         {:ok, referenced} <- Database.referenced_roles(config),
         {:ok, cluster_roles} <- Database.roles(config) do
      roles = Enum.filter(cluster_roles, &(&1["name"] in referenced))

      %{
        "format" => @format,
        "captured_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "server" => %{
          "system_identifier" => facts.server.system_identifier,
          "version_num" => facts.server.version_num,
          "icu_version" => facts.server.icu_version
        },
        "database" => properties,
        "extensions" => extensions,
        "roles" => roles,
        "migrations" => in_database.migrations,
        "routing" => routing_name(in_database.routing),
        "resolutions" => in_database.resolutions,
        "sections" => sections(in_database.manifest)
      }
    else
      {:ok, %{database: nil}} -> raise "#{Database.describe(config)} does not exist"
      {:error, reason} -> raise "#{Database.describe(config)}: #{reason}"
    end
  end

  defp routing(snapshot) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
          Recovery.import_snapshot(snapshot)

          migrations =
            case Repo.query!("SELECT to_regclass('public.schema_migrations') IS NOT NULL") do
              %{rows: [[true]]} ->
                Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
                |> Enum.map(&hd/1)

              _ ->
                []
            end

          case Recovery.routing_schema() do
            :present -> {:present, digest_resolutions(Recovery.resolutions()), migrations}
            other -> {other, nil, migrations}
          end
        end,
        timeout: :infinity
      )

    result
  end

  defp digest_resolutions(%{paths: paths, pages: pages}) do
    rows =
      Enum.map(paths, fn {path, summary} -> Jason.encode!(["path", path | flat(summary)]) end) ++
        Enum.map(pages, fn {id, summary} -> Jason.encode!(["page", id | flat(summary)]) end)

    %{
      "paths" => length(paths),
      "pages" => length(pages),
      "sha256" => sha256_lines(rows)
    }
  end

  defp flat({outcome, page, location, successors}),
    do: [to_string(outcome), page, location, successors]

  defp routing_name(:present), do: "present"
  defp routing_name(:absent), do: "absent"
  defp routing_name(other), do: inspect(other)

  defp sections(manifest) do
    Map.new(manifest, fn {section, %{count: count, sha256: sha} = summary} ->
      kept = if is_list(summary[:rows]), do: %{"rows" => summary.rows}, else: %{}
      {section, Map.merge(%{"count" => count, "sha256" => sha}, kept)}
    end)
  end

  defp sha256_lines(rows) do
    rows
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, [&1, ?\n]))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Where `actual` differs from `expected`: `[]` when the two are the same
  installation state. Each difference is `%{section, expected, actual}`
  (row-level detail for the schema and sequences, which keep their rows).

  Options: `ignore: [:name]` — another database name is not a difference
  (initialising a new installation). The oid never is one.
  """
  def diff(expected, actual, opts \\ []) do
    ignore_name? = :name in Keyword.get(opts, :ignore, [])

    []
    |> section_diffs(expected["sections"], actual["sections"])
    |> compare("migrations", expected["migrations"], actual["migrations"])
    |> compare("routing", expected["routing"], actual["routing"])
    |> compare("resolutions", expected["resolutions"], actual["resolutions"])
    |> database_diffs(expected["database"], actual["database"], ignore_name?)
    |> compare("extensions", expected["extensions"], actual["extensions"])
    |> roles_diff(expected["roles"], actual["roles"])
    |> Enum.reverse()
  end

  defp section_diffs(acc, expected, actual) do
    names = Enum.sort(Enum.uniq(Map.keys(expected) ++ Map.keys(actual)))

    Enum.reduce(names, acc, fn name, acc ->
      left = Map.get(expected, name)
      right = Map.get(actual, name)

      cond do
        is_nil(left) ->
          [%{section: "table " <> name, expected: :absent, actual: summary(right)} | acc]

        is_nil(right) ->
          [%{section: "table " <> name, expected: summary(left), actual: :absent} | acc]

        left["sha256"] == right["sha256"] and left["count"] == right["count"] ->
          acc

        true ->
          [
            %{
              section: section_name(name),
              expected: summary(left),
              actual: summary(right),
              only_expected: only(left["rows"], right["rows"]),
              only_actual: only(right["rows"], left["rows"])
            }
            | acc
          ]
      end
    end)
  end

  defp section_name(name) when name in ["schema", "sequences"], do: name
  defp section_name(name), do: "table " <> name

  defp summary(%{"count" => count, "sha256" => sha}),
    do: "#{count} rows, #{String.slice(sha, 0, 12)}…"

  defp only(rows, other) when is_list(rows) and is_list(other),
    do: (rows -- other) |> Enum.sort() |> Enum.take(10)

  defp only(_rows, _other), do: nil

  defp database_diffs(acc, expected, actual, ignore_name?) do
    skip = if ignore_name?, do: @identity_only, else: @identity_only -- ["name"]
    keys = Enum.sort(Enum.uniq(Map.keys(expected) ++ Map.keys(actual))) -- skip

    Enum.reduce(keys, acc, fn key, acc ->
      compare(acc, "database " <> key, Map.get(expected, key), Map.get(actual, key))
    end)
  end

  defp roles_diff(acc, expected, actual) do
    by_name = fn roles -> Map.new(roles, &{&1["name"], &1}) end
    {left, right} = {by_name.(expected), by_name.(actual)}

    # A role the installation never had is not a difference: the target
    # cluster may serve other databases. Every recorded role must be there,
    # with the same attributes.
    Enum.reduce(Enum.sort(Map.keys(left)), acc, fn name, acc ->
      compare(acc, "role " <> name, left[name], Map.get(right, name, :absent))
    end)
  end

  defp compare(acc, _section, same, same), do: acc

  defp compare(acc, section, expected, actual),
    do: [%{section: section, expected: expected, actual: actual} | acc]

  @doc "A difference as an operator reads it, one line."
  def describe(%{section: section, expected: expected, actual: actual} = difference) do
    detail =
      case difference do
        %{only_expected: [_ | _] = rows} -> "; only expected: #{Enum.join(rows, " | ")}"
        %{only_actual: [_ | _] = rows} -> "; only actual: #{Enum.join(rows, " | ")}"
        _ -> ""
      end

    "#{section}: expected #{show(expected)}, found #{show(actual)}#{detail}"
  end

  defp show(value) when is_binary(value), do: value
  defp show(value), do: inspect(value, limit: 20, printable_limit: 200)

  @doc "The sections a state compares, for a report: `%{section => count}`."
  def counts(state), do: Map.new(state["sections"], fn {name, s} -> {name, s["count"]} end)
end
