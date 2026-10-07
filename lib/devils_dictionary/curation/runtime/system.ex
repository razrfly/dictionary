defmodule DevilsDictionary.Curation.Runtime.System do
  @moduledoc """
  What the runtime needs to know about the host, read from the host.

    * `volume/1`: whether a mount point is a mounted, **external** volume.
      The model cache must be on one, and an unmounted drive's empty
      mount-point directory on the internal disk is never used in its place.
    * `memory/0`: swap in use and the system-wide free-memory percentage.
      This is the pause signal of #195, not a benchmark of a model.
    * `read_file/1`, `dir?/1`: the manifest and root checks.
    * `process_alive?/1`, `process_command/1`: whether a process id still
      exists, and what it runs, for recovery.

  The suite substitutes `Runtime.FakeSystem`. Nothing here creates, downloads
  or starts anything.
  """

  @doc """
  `{:ok, %{mounted, external, internal, device}}` or `{:error, reason}`.
  `external` and `internal` are each true only when diskutil says so;
  without its `Internal` key, both are false.
  """
  def volume(mount_point) do
    with {out, 0} <-
           System.cmd("diskutil", ["info", "-plist", mount_point], stderr_to_stdout: true),
         {:ok, mounted_at} <- plist_string(out, "MountPoint") do
      internal = plist_bool(out, "Internal")

      {:ok,
       %{
         mounted: mounted_at == mount_point,
         external: internal == false,
         internal: internal == true,
         device: plist_string(out, "DeviceNode") |> elem(1)
       }}
    else
      _ -> {:ok, %{mounted: false, external: false, internal: false, device: nil}}
    end
  rescue
    _ -> {:error, :volume_unreadable}
  end

  @doc "`{:ok, %{swap_used_bytes, swap_total_bytes, free_percent}}` or `{:error, :unavailable}`."
  def memory do
    with {swap, 0} <- System.cmd("sysctl", ["-n", "vm.swapusage"]),
         {pressure, 0} <- System.cmd("memory_pressure", ["-Q"]),
         [_, total, used] <- Regex.run(~r/total = ([\d.]+)M\s+used = ([\d.]+)M/, swap),
         [_, free] <- Regex.run(~r/free percentage: (\d+)%/, pressure) do
      {:ok,
       %{
         swap_total_bytes: megabytes(total),
         swap_used_bytes: megabytes(used),
         free_percent: String.to_integer(free)
       }}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Reads a file."
  def read_file(path), do: File.read(path)

  @doc "Whether a directory exists."
  def dir?(path), do: File.dir?(path)

  @doc "Whether an OS process id is still running."
  def process_alive?(pid) when is_integer(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  @doc """
  The executable an OS process id runs, as `ps` reports it (a full path on
  macOS): `{:ok, path}` or `:error`. After a reboot a recorded pid can belong
  to another program, so being alive does not make it the service.
  """
  def process_command(pid) when is_integer(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp megabytes(value) do
    {mb, _} = Float.parse(value)
    round(mb * 1024 * 1024)
  end

  defp plist_string(plist, key) do
    case Regex.run(~r{<key>#{key}</key>\s*<string>([^<]*)</string>}, plist) do
      [_, value] -> {:ok, value}
      _ -> {:error, :missing}
    end
  end

  defp plist_bool(plist, key) do
    case Regex.run(~r{<key>#{key}</key>\s*<(true|false)/>}, plist) do
      [_, "true"] -> true
      [_, "false"] -> false
      _ -> nil
    end
  end
end
