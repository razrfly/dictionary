defmodule DevilsDictionary.Installation.Manifest do
  @moduledoc """
  A bundle's `MANIFEST.json`: what the bundle is, where it came from, and
  every file in it by size and SHA-256.

  The manifest binds verification to the data: it records the dump's own
  size and SHA-256, and the state captured under the very snapshot the dump
  was taken in (`db/<database>.state.json`, itself listed with its digest).
  A dump replaced, truncated or corrupted after the capture no longer
  matches, and nothing is restored from it.

  The manifest is written last, after every file it lists is in place, so a
  directory without one is an unfinished bundle, never a usable one. Its own
  SHA-256 is printed when it is written: that digest is what an operator
  approves, and what `mix dd.bootstrap --expect-manifest-sha256` pins.

  Format `dd.bundle/1`:

      format, kind ("installation"), privacy, created_at,
      code      — the installation's checkout: revision, dirty, branch
      tool      — the same for the code that took the capture
      toolchain — elixir, otp, pg_dump, pg_restore
      source    — system_identifier, database, database_oid, endpoint,
                  server_version, server_version_num, data_directory,
                  database_bytes
      database  — the database's properties and settings (Installation.Database)
      schema    — head and every recorded migration version
      cluster_roles — the source cluster's roles, attributes only
      quiescence — connections at start and end, write counters before
                   and after, and whether the window was quiet
      files     — [{path, role, bytes, sha256, …}]
      models    — an inventory of pinned model artifacts, not copied
  """

  alias DevilsDictionary.Installation.Files

  @format "dd.bundle/1"
  @file_name "MANIFEST.json"

  def format, do: @format
  def file_name, do: @file_name

  @doc "Where a bundle's manifest lives."
  def path(bundle), do: Path.join(bundle, @file_name)

  @doc "`{:ok, manifest}` or `{:error, message}`."
  def read(bundle) do
    with {:ok, json} <- read_file(path(bundle)),
         {:ok, %{} = manifest} <- decode(json, bundle),
         :ok <- known_format(manifest, bundle) do
      {:ok, manifest}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, json} ->
        {:ok, json}

      {:error, :enoent} ->
        {:error, "#{path} does not exist: the directory is not a finished bundle"}

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(json, bundle) do
    case Jason.decode(json) do
      {:ok, %{} = manifest} -> {:ok, manifest}
      _ -> {:error, "#{path(bundle)} is not a JSON object"}
    end
  end

  defp known_format(%{"format" => @format}, _bundle), do: :ok

  defp known_format(manifest, bundle),
    do:
      {:error,
       "#{path(bundle)} is format #{inspect(manifest["format"])}; this code reads #{@format} only"}

  @doc "The manifest file's own SHA-256."
  def digest(bundle), do: Files.sha256(path(bundle))

  @doc "Writes the manifest last and atomically; returns its SHA-256."
  def write!(bundle, manifest) do
    Files.write_atomic!(path(bundle), Jason.encode_to_iodata!(manifest, pretty: true))
    digest(bundle)
  end

  @doc "The listed file with `role`, or nil."
  def file(manifest, role), do: Enum.find(manifest["files"], &(&1["role"] == role))

  @doc "Every listed file with `role`."
  def files(manifest, role), do: Enum.filter(manifest["files"], &(&1["role"] == role))

  @doc """
  Checks every file the manifest lists: present, the recorded size, and —
  with `deep: true` (the default) — the recorded SHA-256. Paths must stay
  inside the bundle.

  `{:ok, rows}` or `{:error, rows}`; each row is `%{path, role, status,
  detail}` with status `:ok` or `:failed`.
  """
  def verify_files(bundle, manifest, opts \\ []) do
    deep? = Keyword.get(opts, :deep, true)

    rows =
      for entry <- manifest["files"] do
        path = entry["path"]

        status =
          with :ok <- inside(path),
               :ok <- Files.check(Path.join(bundle, path), entry, deep: deep?) do
            :ok
          end

        case status do
          :ok ->
            %{path: path, role: entry["role"], status: :ok, detail: "#{entry["bytes"]} bytes"}

          {:error, reason} ->
            %{path: path, role: entry["role"], status: :failed, detail: Files.describe(reason)}
        end
      end

    if Enum.all?(rows, &(&1.status == :ok)), do: {:ok, rows}, else: {:error, rows}
  end

  @doc """
  `:ok` when every path the manifest lists stays inside the bundle: relative,
  with no `..`. Checked before any file is copied anywhere.
  """
  def confined(manifest) do
    case Enum.reject(manifest["files"], &(inside(&1["path"]) == :ok)) do
      [] ->
        :ok

      bad ->
        {:error,
         "the manifest lists paths outside the bundle: #{Enum.map_join(bad, ", ", & &1["path"])}"}
    end
  end

  @doc false
  def inside(path) when is_binary(path) do
    if Path.type(path) == :relative and ".." not in Path.split(path),
      do: :ok,
      else: {:error, :outside_bundle}
  end

  def inside(_path), do: {:error, :outside_bundle}
end
