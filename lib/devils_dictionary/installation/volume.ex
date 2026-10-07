defmodule DevilsDictionary.Installation.Volume do
  @moduledoc """
  Whether a path is on the intended mounted volume, before anything is
  written there (#211 §1, §5).

  A directory at the expected mount path is not proof that the drive is
  mounted: an unmounted drive's mount point, or a directory someone created
  in its place, lives on the internal disk. So a path is accepted only when:

    * the volume reports itself mounted at exactly that mount point, and
      **not internal** (`diskutil info -plist`, as the curation runtime
      checks its model volume);
    * its `VolumeUUID` equals the expected one, when one is given — a mount
      path alone does not say which drive is plugged in;
    * the path, or its nearest existing ancestor, is on the **same device**
      as the mount point (`stat`'s device), and sits under it once symlinks
      are resolved. A symlink out of the volume is refused.

  Nothing here creates a directory. Callers create theirs only after
  `check/3` passes, so a missing drive can never become an internal
  fallback. `/Volumes` itself is not writable by an ordinary user, which is
  a second line: a mount point that is absent cannot be recreated by
  accident.

  The probe is replaceable (`probe:`), so the suite can describe a volume
  without one being plugged in.
  """

  alias DevilsDictionary.Curation.Runtime.System, as: Host

  @doc """
  `{:ok, facts}` when `path` may be written as part of the volume mounted at
  `mount_point`, or `{:error, message}`. `facts` carries the mount point,
  device node, UUID and free bytes, for a manifest or a doctor report.

  Options:

    * `uuid:` — the expected `VolumeUUID`;
    * `need_bytes:` — refuse when the volume has less free space;
    * `probe:` — `fun(mount_point) -> {:ok, %{mounted, external, device, uuid}}`.
  """
  def check(path, mount_point, opts \\ []) do
    mount_point = Path.expand(mount_point)
    path = Path.expand(path)
    probe = Keyword.get(opts, :probe, &probe/1)

    with {:ok, volume} <- probe.(mount_point),
         :ok <- mounted(volume, mount_point),
         :ok <- uuid(volume, opts[:uuid], mount_point),
         {:ok, anchor} <- nearest_existing(path),
         :ok <- under(anchor, path, mount_point),
         :ok <- same_device(anchor, mount_point),
         {:ok, free} <- free_bytes(mount_point),
         :ok <- room(free, opts[:need_bytes], mount_point) do
      {:ok,
       %{
         mount_point: mount_point,
         device: volume[:device],
         uuid: volume[:uuid],
         external: true,
         free_bytes: free
       }}
    end
  end

  @reserve_bytes 10 * 1_073_741_824

  @doc """
  `{:ok, facts}` when `path` may hold the **second copy** of a bundle on an
  internal volume (#211 D14): the copy that is still there when the
  external drive is lost. So it is accepted only when:

    * the bundle being copied, `apart_from:`, is on a mounted **external**
      volume: this is the copy of the external drive's bundle, not a third
      copy on the same disk;
    * the volume holding the path (through its nearest existing ancestor)
      is mounted and diskutil reports it **internal**. A second external
      drive is an ordinary destination, and goes through `check/3`;
    * a path under `/Volumes/` is on the volume mounted there. A directory
      standing in for an absent drive is not a destination;
    * that ancestor is on another device than the bundle;
    * no directory on the way up from it holds a `.git` (a work tree, a
      linked worktree's `.git` file, or a path inside a `.git` directory):
      a checkout is cleaned, re-cloned and reclaimed, and a copy inside one
      would go with it. This reads the filesystem, so it does not depend on
      git, its environment, or a worktree that has lost its repository;
    * the copy leaves `reserve_bytes:` free (default 10 GiB): the internal
      disk also holds the operating system, its swap and the old cluster.

  Nothing is created. Options: `apart_from:` (required), `need_bytes:`,
  `reserve_bytes:`, and for the suite `probe:` (the destination's volume, as
  in `check/3`), `source_probe:` (the bundle's; default `probe:`) and
  `stat:` (`File.stat/1`).
  """
  def check_internal(path, opts) do
    path = Path.expand(path)
    apart_from = Path.expand(Keyword.fetch!(opts, :apart_from))
    probe = Keyword.get(opts, :probe, &probe/1)
    source_probe = Keyword.get(opts, :source_probe, probe)
    stat = Keyword.get(opts, :stat, &File.stat/1)
    reserve = Keyword.get(opts, :reserve_bytes, @reserve_bytes)

    with {:ok, source_mount} <- mount_point_of(apart_from),
         {:ok, source} <- source_probe.(source_mount),
         :ok <- external_source(source, apart_from),
         {:ok, anchor} <- nearest_existing(path),
         {:ok, mount_point} <- mount_point_of(anchor),
         :ok <- not_in_place_of_a_drive(path, anchor, mount_point),
         {:ok, volume} <- probe.(mount_point),
         :ok <- internal(volume, mount_point),
         :ok <- another_device(anchor, apart_from, stat),
         :ok <- outside_repositories(anchor, path),
         {:ok, free} <- free_bytes(anchor),
         :ok <- room(free, (opts[:need_bytes] || 0) + reserve, mount_point, reserve) do
      {:ok,
       %{
         mount_point: mount_point,
         device: volume[:device],
         uuid: volume[:uuid],
         external: false,
         free_bytes: free
       }}
    end
  end

  defp external_source(%{mounted: true, external: true}, _bundle), do: :ok

  defp external_source(_volume, bundle),
    do:
      {:error,
       "#{bundle} is not on an external volume; the second copy is of the external drive's bundle"}

  # `/Volumes` itself is on the internal disk: a path under it that the
  # internal volume answers for is a directory where a drive should be.
  # Read from the anchor as the filesystem resolves it too, so neither a
  # symlink to /Volumes nor another case of its name gets around it.
  defp not_in_place_of_a_drive(path, anchor, mount_point) do
    real = resolve(anchor)

    under_volumes? =
      Enum.any?([path, real], &(&1 == "/Volumes" or String.starts_with?(&1, "/Volumes/")))

    if under_volumes? and not String.starts_with?(mount_point, "/Volumes/"),
      do:
        {:error,
         "#{path} is under /Volumes, but no volume is mounted there; " <>
           "nothing is written in its place"},
      else: :ok
  end

  # The mount point of the filesystem holding `path`: `df -P`'s last column,
  # which may itself contain spaces.
  defp mount_point_of(path) do
    case System.cmd("df", ["-P", "-k", path], stderr_to_stdout: true) do
      {out, 0} ->
        with [_header, line | _] <- String.split(out, "\n", trim: true),
             [_, mount_point] <- Regex.run(~r/^.+?\s+\d+\s+\d+\s+\d+\s+\d+%\s+(\/.*)$/, line) do
          {:ok, mount_point}
        else
          _ -> {:error, "#{path}: its volume cannot be read"}
        end

      {out, _} ->
        {:error, "#{path}: its volume cannot be read (#{String.trim(out)})"}
    end
  end

  defp internal(%{mounted: true, internal: true}, _mount_point), do: :ok

  defp internal(%{mounted: true, external: true}, mount_point),
    do:
      {:error,
       "#{mount_point} is an external volume; name it with --volume (and --volume-uuid) instead"}

  defp internal(%{mounted: true}, mount_point),
    do: {:error, "#{mount_point} does not report itself internal; nothing is written"}

  defp internal(_volume, mount_point),
    do: {:error, "#{mount_point} is not a mounted volume; nothing is written"}

  defp another_device(anchor, apart_from, stat) do
    with {:ok, %{major_device: a}} <- stat.(anchor),
         {:ok, %{major_device: b}} <- stat.(apart_from) do
      if a != b,
        do: :ok,
        else:
          {:error,
           "#{anchor} is on the same device as #{apart_from}: a second copy there " <>
             "survives nothing the first does not"}
    else
      {:error, reason} -> {:error, "#{anchor} or #{apart_from}: cannot stat (#{inspect(reason)})"}
    end
  end

  # A `.git` directory, a directory holding any `.git` entry (a dangling
  # link or a worktree's `.git` file included), or a bare repository.
  defp repository?(dir) do
    Path.basename(dir) == ".git" or git_entry?(Path.join(dir, ".git")) or
      (File.regular?(Path.join(dir, "HEAD")) and File.dir?(Path.join(dir, "objects")) and
         File.dir?(Path.join(dir, "refs")))
  end

  # Only "it does not exist" means no repository. A `.git` that cannot be
  # read (a directory that cannot be searched, a link loop) refuses the
  # destination rather than being assumed away.
  defp git_entry?(path) do
    case File.lstat(path) do
      {:ok, _} -> true
      {:error, reason} when reason in [:enoent, :enotdir] -> false
      {:error, _unknown} -> true
    end
  end

  # Every directory from the anchor (symlinks resolved) up to `/`: any of
  # them a repository puts the path inside one.
  defp outside_repositories(anchor, path) do
    found =
      anchor
      |> resolve()
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.reverse()
      |> Enum.find(&repository?/1)

    case found do
      nil ->
        :ok

      root ->
        {:error,
         "#{path} is inside the git repository at #{root}; " <>
           "a second copy belongs outside every checkout"}
    end
  end

  @doc "The host's view of a mount point: mounted, external, device node and UUID."
  def probe(mount_point) do
    case Host.volume(mount_point) do
      {:ok, facts} -> {:ok, Map.put(facts, :uuid, uuid_of(mount_point))}
      {:error, reason} -> {:error, "#{mount_point}: the volume cannot be read (#{reason})"}
    end
  end

  defp uuid_of(mount_point) do
    case System.cmd("diskutil", ["info", "-plist", mount_point], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r{<key>VolumeUUID</key>\s*<string>([^<]*)</string>}, out) do
          [_, uuid] -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp mounted(%{mounted: true, external: true}, _mount_point), do: :ok

  defp mounted(%{mounted: true}, mount_point),
    do:
      {:error,
       "#{mount_point} is an internal volume; bulk installation data belongs on the external drive"}

  defp mounted(_volume, mount_point),
    do:
      {:error,
       "#{mount_point} is not a mounted volume. Mount the drive; nothing is written in its place"}

  defp uuid(_volume, nil, _mount_point), do: :ok
  defp uuid(%{uuid: uuid}, uuid, _mount_point), do: :ok

  defp uuid(volume, expected, mount_point),
    do:
      {:error,
       "#{mount_point} is volume #{inspect(volume[:uuid])}, not the expected #{expected}: " <>
         "another drive is mounted there"}

  # The path itself, or the closest directory above it that exists. Nothing
  # below that point exists yet, so it would be created on the anchor's
  # device.
  defp nearest_existing(path) do
    cond do
      File.exists?(path) ->
        {:ok, path}

      Path.dirname(path) == path ->
        {:error, "#{path}: no part of it exists"}

      true ->
        nearest_existing(Path.dirname(path))
    end
  end

  defp under(anchor, path, mount_point) do
    real = resolve(anchor)
    real_mount = resolve(mount_point)

    if real == real_mount or String.starts_with?(real <> "/", real_mount <> "/") do
      :ok
    else
      {:error, "#{path} is not on #{mount_point} (it resolves to #{real})"}
    end
  end

  defp same_device(anchor, mount_point) do
    with {:ok, %{major_device: a}} <- File.stat(anchor),
         {:ok, %{major_device: b}} <- File.stat(mount_point) do
      if a == b,
        do: :ok,
        else: {:error, "#{anchor} is on another device than the volume mounted at #{mount_point}"}
    else
      {:error, reason} -> {:error, "#{anchor}: cannot stat (#{reason})"}
    end
  end

  # Symlinks resolved, as the operating system would follow them.
  defp resolve(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> path
    end
  rescue
    _ -> path
  end

  @doc "Free bytes on the filesystem holding `path`, from `df -k`."
  def free_bytes(path) do
    case System.cmd("df", ["-k", path], stderr_to_stdout: true) do
      {out, 0} ->
        with [_header, line | _] <- String.split(out, "\n", trim: true),
             [_fs, _blocks, _used, available | _] <- String.split(line),
             {kib, ""} <- Integer.parse(available) do
          {:ok, kib * 1024}
        else
          _ -> {:error, "#{path}: free space cannot be read"}
        end

      {out, _} ->
        {:error, "#{path}: free space cannot be read (#{String.trim(out)})"}
    end
  end

  defp room(_free, nil, _mount_point), do: :ok
  defp room(free, need, _mount_point) when free >= need, do: :ok

  defp room(free, need, mount_point),
    do:
      {:error,
       "#{mount_point} has #{gib(free)} free; this needs #{gib(need)}. Nothing was written"}

  # The internal disk keeps `reserve` free after the copy.
  defp room(free, need, _mount_point, _reserve) when free >= need, do: :ok

  defp room(free, need, mount_point, reserve),
    do:
      {:error,
       "#{mount_point} has #{gib(free)} free; this needs #{gib(need)}, of which " <>
         "#{gib(reserve)} must stay free on the internal disk. Nothing was written"}

  @doc false
  def gib(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
end
