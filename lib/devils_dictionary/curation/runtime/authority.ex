defmodule DevilsDictionary.Curation.Runtime.Authority do
  @moduledoc """
  Which database owns the physical service's one slot (#195, G1).

  The slot is a row in PostgreSQL (`Runtime.Gateway`). A caller connected to
  another database, such as a test partition, a benchmark database or a
  second environment, would find a slot row of its own. Its generations
  would then overlap the authoritative caller's, and its budget would be
  counted apart. So the service is bound to exactly one database by a marker
  next to its process id, on the external volume:

      <run_dir>/authority.json
      {"database": "...", "system_identifier": "...", "service_key": "..."}

  `system_identifier` is the PostgreSQL cluster's own id, so two clusters
  with a database of the same name never match.

  Readiness refuses any caller whose database is not the bound one:
  `:foreign_authority`, or `:authority_unbound` when there is no marker.
  `ServiceProcess.start/1` writes the marker when there is none. It refuses to
  replace one naming another database unless told to rebind, which an
  operator does only once the old database's slot has no live attempt.
  """

  alias DevilsDictionary.Curation.Runtime.Endpoint
  alias DevilsDictionary.Repo

  @doc "Where the marker lives."
  def path(opts \\ []), do: Path.join(Endpoint.get(:run_dir, opts), "authority.json")

  @doc "The connected database: its name, its cluster's id, and the service key."
  def identity(opts \\ []) do
    %{rows: [[database, system_identifier]]} =
      Repo.query!(
        "SELECT current_database(), (SELECT system_identifier FROM pg_control_system())::text"
      )

    %{
      "database" => database,
      "system_identifier" => system_identifier,
      "service_key" => Endpoint.get(:service_key, opts)
    }
  end

  @doc """
  The bound identity: `{:ok, map}`, `:unbound`, or `{:error, :unreadable}`
  for a marker that is not the expected JSON.
  """
  def bound(opts \\ []) do
    case Endpoint.system(opts).read_file(path(opts)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"database" => _, "system_identifier" => _, "service_key" => _} = marker} ->
            {:ok, marker}

          _ ->
            {:error, :unreadable}
        end

      {:error, _} ->
        :unbound
    end
  end

  @doc """
  `{:ok, identity}` when the connected database is the bound one, or
  `{:error, reason, detail}`: `:authority_unbound`, `:foreign_authority` (with
  the bound database and service key) or `:authority_unreadable`.
  """
  def check(opts \\ []) do
    mine = identity(opts)

    case bound(opts) do
      {:ok, ^mine} -> {:ok, mine}
      {:ok, other} -> {:error, :foreign_authority, Map.take(other, ["database", "service_key"])}
      :unbound -> {:error, :authority_unbound, path(opts)}
      {:error, :unreadable} -> {:error, :authority_unreadable, path(opts)}
    end
  end

  @doc """
  Binds the service to the connected database, for `ServiceProcess.start/1`.
  It writes the real file: the marker is host state, like the process id.

  Returns `{:ok, identity}`, keeping an existing marker for this database.
  Without `rebind: true` it refuses to replace a marker naming another
  database, `{:error, {:bound_to_other_database, name}}`, or one it cannot
  read, `{:error, :authority_unreadable}`.
  """
  def bind(opts \\ []) do
    mine = identity(opts)
    rebind? = Keyword.get(opts, :rebind, false) == true

    case bound(opts) do
      {:ok, ^mine} ->
        {:ok, mine}

      :unbound ->
        write(mine, opts)

      _other_or_unreadable when rebind? ->
        write(mine, opts)

      {:ok, other} ->
        {:error, {:bound_to_other_database, other["database"]}}

      {:error, :unreadable} ->
        {:error, :authority_unreadable}
    end
  end

  defp write(identity, opts) do
    File.write!(path(opts), Jason.encode!(identity, pretty: true))
    {:ok, identity}
  end
end
