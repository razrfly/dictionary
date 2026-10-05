defmodule DevilsDictionary.Installation.FilesTest do
  @moduledoc """
  A transfer resumes from its partial file, renames into place only once
  the whole file has the expected SHA-256, and never overwrites a file that
  is not the one it was asked to produce.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Installation.Files

  setup do
    dir = Path.join(System.tmp_dir!(), "dd-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    source = Path.join(dir, "source.bin")
    File.write!(source, :crypto.strong_rand_bytes(3 * 1024 * 1024 + 17))
    %{dir: dir, source: source, expected: Files.fingerprint(source)}
  end

  test "a fresh copy is verified and renamed into place", %{
    dir: dir,
    source: source,
    expected: expected
  } do
    dest = Path.join(dir, "out/copy.bin")
    assert {:ok, :copied} = Files.copy(source, dest, expected)
    assert Files.check(dest, expected) == :ok
    refute File.exists?(dest <> ".partial")
  end

  test "an interrupted copy resumes from its partial file", %{
    dir: dir,
    source: source,
    expected: expected
  } do
    dest = Path.join(dir, "copy.bin")
    File.write!(dest <> ".partial", binary_part(File.read!(source), 0, 1_000_000))

    assert {:ok, :resumed} = Files.copy(source, dest, expected)
    assert Files.check(dest, expected) == :ok
  end

  test "a partial file that cannot lead to the digest is discarded and the copy starts over",
       %{dir: dir, source: source, expected: expected} do
    dest = Path.join(dir, "copy.bin")
    File.write!(dest <> ".partial", :crypto.strong_rand_bytes(500_000))

    assert {:ok, :copied} = Files.copy(source, dest, expected)
    assert Files.check(dest, expected) == :ok
  end

  test "a destination that is already the file is left alone", %{
    dir: dir,
    source: source,
    expected: expected
  } do
    dest = Path.join(dir, "copy.bin")
    File.cp!(source, dest)
    %{mtime: before} = File.stat!(dest)

    assert {:ok, :present} = Files.copy(source, dest, expected)
    assert File.stat!(dest).mtime == before
  end

  test "a different destination is never overwritten", %{
    dir: dir,
    source: source,
    expected: expected
  } do
    dest = Path.join(dir, "copy.bin")
    File.write!(dest, "someone else's file")

    assert {:error, message} = Files.copy(source, dest, expected)
    assert message =~ "refusing to overwrite"
    assert File.read!(dest) == "someone else's file"
  end

  test "a source that is not the expected file is not copied", %{dir: dir, source: source} do
    dest = Path.join(dir, "copy.bin")
    assert {:error, message} = Files.copy(source, dest, %{"bytes" => 5, "sha256" => "00"})
    assert message =~ "is not the file to copy"
    refute File.exists?(dest)
    refute File.exists?(dest <> ".partial")
  end

  test "a same-size source with other bytes is copied, then refused before the rename",
       %{dir: dir, source: source, expected: expected} do
    dest = Path.join(dir, "copy.bin")
    forged = Map.put(expected, "sha256", String.duplicate("0", 64))

    assert {:error, message} = Files.copy(source, dest, forged)
    assert message =~ "does not reproduce the expected SHA-256"
    refute File.exists?(dest)
  end

  test "check/3 tells missing, truncated and altered files apart", %{
    source: source,
    expected: expected
  } do
    assert Files.check(source <> ".nope", expected) == {:error, :missing}

    assert {:error, {:size, _, _}} =
             Files.check(source, Map.update!(expected, "bytes", &(&1 + 1)))

    assert {:error, {:sha256, _, _}} =
             Files.check(source, Map.put(expected, "sha256", String.duplicate("a", 64)))

    # Size only, and it says so by passing.
    assert Files.check(source, Map.put(expected, "sha256", "x"), deep: false) == :ok
  end
end
