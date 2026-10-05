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

  @doc false
  def gib(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
end
