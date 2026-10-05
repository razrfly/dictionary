defmodule DevilsDictionary.Installation.VolumeTest do
  @moduledoc """
  A path is accepted only on the mounted, external volume it was meant for:
  not on an unmounted mount point, not on an internal volume, not on
  another drive mounted at the same path, not through a symlink out of the
  volume, and not without room. Nothing is created by the check.
  """
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2]

  alias DevilsDictionary.Installation.Volume

  setup do
    mount = Path.join(System.tmp_dir!(), "dd-volume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(mount)
    on_exit(fn -> File.rm_rf(mount) end)
    %{mount: mount}
  end

  defp probe(facts), do: fn _mount -> {:ok, facts} end

  @external %{mounted: true, external: true, device: "/dev/disk9s1", uuid: "UUID-A"}

  test "a path under the mounted external volume is accepted, and nothing is created",
       %{mount: mount} do
    path = Path.join(mount, "bundles/new/db")

    assert {:ok, facts} = Volume.check(path, mount, probe: probe(@external), uuid: "UUID-A")
    assert facts.uuid == "UUID-A"
    assert facts.free_bytes > 0
    refute File.exists?(Path.join(mount, "bundles"))
  end

  test "an unmounted or internal volume is refused", %{mount: mount} do
    assert {:error, message} =
             Volume.check(mount, mount, probe: probe(%{@external | mounted: false}))

    assert message =~ "not a mounted volume"

    assert {:error, message} =
             Volume.check(mount, mount, probe: probe(%{@external | external: false}))

    assert message =~ "internal volume"
  end

  test "another drive mounted at the same path is refused", %{mount: mount} do
    assert {:error, message} = Volume.check(mount, mount, probe: probe(@external), uuid: "UUID-B")
    assert message =~ "not the expected UUID-B"
  end

  test "a path outside the mount point, or a symlink out of it, is refused", %{mount: mount} do
    elsewhere = Path.join(System.tmp_dir!(), "dd-elsewhere-#{System.unique_integer([:positive])}")
    File.mkdir_p!(elsewhere)
    on_exit(fn -> File.rm_rf(elsewhere) end)

    assert {:error, message} = Volume.check(elsewhere, mount, probe: probe(@external))
    assert message =~ "is not on"

    link = Path.join(mount, "escape")
    File.ln_s!(elsewhere, link)
    assert {:error, message} = Volume.check(Path.join(link, "x"), mount, probe: probe(@external))
    assert message =~ "is not on"
  end

  test "a volume without room is refused", %{mount: mount} do
    assert {:error, message} =
             Volume.check(mount, mount, probe: probe(@external), need_bytes: 1 <<< 60)

    assert message =~ "free; this needs"
  end
end
