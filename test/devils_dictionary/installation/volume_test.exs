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

  describe "the second copy, on an internal volume (#211 D14)" do
    @internal %{
      mounted: true,
      external: false,
      internal: true,
      device: "/dev/disk3s5",
      uuid: "UUID-I"
    }

    setup %{mount: mount} do
      bundle = Path.join(mount, "external-bundle")
      File.mkdir_p!(bundle)

      # The bundle on an external drive, the destination internal, apart
      # from it, with no reserve to meet: the suite's one disk, described.
      ok = [
        apart_from: bundle,
        probe: probe(@internal),
        source_probe: probe(@external),
        stat: apart(bundle),
        reserve_bytes: 0
      ]

      %{bundle: bundle, ok: ok}
    end

    test "is accepted apart from the external bundle and outside every checkout, creating nothing",
         %{mount: mount, ok: ok} do
      path = Path.join(mount, "backups/dictionary/2026-10-05-v2")

      assert {:ok, facts} = Volume.check_internal(path, Keyword.put(ok, :need_bytes, 1))
      refute facts.external
      assert facts.free_bytes > 0
      refute File.exists?(Path.join(mount, "backups"))
    end

    test "is refused for a bundle that is not on an external volume", %{mount: mount, ok: ok} do
      path = Path.join(mount, "backups/v2")

      for source <- [@internal, %{@external | mounted: false}] do
        assert {:error, message} =
                 Volume.check_internal(path, Keyword.put(ok, :source_probe, probe(source)))

        assert message =~ "is not on an external volume"
      end
    end

    test "is refused unless diskutil reports the destination mounted and internal",
         %{mount: mount, ok: ok} do
      path = Path.join(mount, "backups/v2")

      for {volume, expected} <- [
            {@external, "is an external volume; name it with --volume"},
            {%{@internal | mounted: false}, "not a mounted volume"},
            # No `Internal` key: neither external nor internal, so not accepted.
            {%{@internal | internal: false}, "does not report itself internal"}
          ] do
        assert {:error, message} =
                 Volume.check_internal(path, Keyword.put(ok, :probe, probe(volume)))

        assert message =~ expected
      end
    end

    test "keeps 10 GiB free on the internal disk unless told otherwise", %{mount: mount, ok: ok} do
      path = Path.join(mount, "backups/v2")
      {:ok, free} = Volume.free_bytes(mount)
      default = Keyword.delete(ok, :reserve_bytes)

      # Room for the copy, but not for the copy and the default reserve.
      need = max(free - 5 * 1_073_741_824, 1)

      assert {:error, message} =
               Volume.check_internal(path, Keyword.put(default, :need_bytes, need))

      assert message =~ "10.0 GiB must stay free on the internal disk"

      assert {:ok, _} =
               Volume.check_internal(path, Keyword.merge(ok, need_bytes: need, reserve_bytes: 0))
    end

    test "is refused in place of an absent drive, beside the bundle, or without its reserve",
         %{mount: mount, bundle: bundle, ok: ok} do
      path = Path.join(mount, "backups/v2")

      # /Volumes itself is on the internal disk: an unmounted drive's path
      # is answered by the internal volume, and refused.
      absent = "dd-absent-#{System.unique_integer([:positive])}/backups"
      link = Path.join(mount, "volumes-link")
      File.ln_s!("/Volumes", link)

      # Typed as is, in another case (the filesystem ignores case), or
      # through a symlink to /Volumes.
      lowercase = if File.dir?("/volumes"), do: ["/volumes/"], else: []

      for spelled <- ["/Volumes/", link <> "/"] ++ lowercase do
        assert {:error, message} = Volume.check_internal(spelled <> absent, ok)
        assert message =~ "no volume is mounted there"
      end

      assert {:error, message} = Volume.check_internal(path, Keyword.delete(ok, :stat))
      assert message =~ "on the same device as #{bundle}"

      assert {:error, message} =
               Volume.check_internal(path, Keyword.put(ok, :need_bytes, 1 <<< 60))

      assert message =~ "free; this needs"

      assert {:error, message} =
               Volume.check_internal(path, Keyword.put(ok, :reserve_bytes, 1 <<< 60))

      assert message =~ "must stay free on the internal disk"
      refute File.exists?(Path.join(mount, "backups"))
    end

    test "is refused inside any git repository, however git would answer", %{mount: mount, ok: ok} do
      checkout = Path.join(mount, "checkout")
      File.mkdir_p!(checkout)
      {_, 0} = System.cmd("git", ["init", "-q", checkout])

      # A linked worktree whose repository is gone: git itself fails there
      # ("not a git repository"), and the `.git` file still marks a checkout.
      stale = Path.join(mount, "stale-worktree")
      File.mkdir_p!(stale)
      File.write!(Path.join(stale, ".git"), "gitdir: #{mount}/gone/.git/worktrees/stale\n")

      # A bare repository has no `.git` at all, and a dangling `.git` link
      # does not exist as far as File.exists?/1 is concerned.
      bare = Path.join(mount, "bare.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", bare])
      dangling = Path.join(mount, "dangling")
      File.mkdir_p!(dangling)
      File.ln_s!(Path.join(mount, "nowhere"), Path.join(dangling, ".git"))

      # A directory that cannot be searched: whether it holds a `.git` is
      # unknown, so the destination is refused rather than assumed clear.
      sealed = Path.join(mount, "sealed")
      File.mkdir_p!(Path.join(sealed, "inner"))
      File.chmod!(sealed, 0o600)
      on_exit(fn -> File.chmod(sealed, 0o700) end)

      for inside <- [
            Path.join(sealed, "inner/backups/v2"),
            Path.join(checkout, "backups/v2"),
            Path.join(checkout, ".git/backups"),
            Path.join(stale, "backups/v2"),
            Path.join(bare, "backups/v2"),
            Path.join(dangling, "backups/v2")
          ] do
        assert {:error, message} = Volume.check_internal(inside, ok)
        assert message =~ "inside the git repository"
      end

      refute File.exists?(Path.join(checkout, "backups"))
      refute File.exists?(Path.join(stale, "backups"))
    end
  end

  # The bundle being copied, on "another device": the suite has one disk, so
  # the bundle's path is reported on a different one.
  defp apart(bundle) do
    fn path ->
      with {:ok, stat} <- File.stat(path) do
        if path == bundle,
          do: {:ok, %{stat | major_device: stat.major_device + 1}},
          else: {:ok, stat}
      end
    end
  end
end
