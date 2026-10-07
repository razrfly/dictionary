defmodule Mix.Tasks.Dd.BundleTest do
  @moduledoc """
  The command line around the second copy (#211 D14): `--internal` is only
  for `--transfer`, only of an approved bundle, never with `--volume`, and
  its floor is changed only by `--reserve-gib`, given with it. Each is
  refused before anything is read or written.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Dd.Bundle

  @digest String.duplicate("a", 64)

  setup do
    dir = Path.join(System.tmp_dir!(), "dd-bundle-task-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, from: Path.join(dir, "bundle"), out: Path.join(dir, "copy")}
  end

  test "the second copy's flags are refused out of place", %{dir: dir, from: from, out: out} do
    refusals = [
      {["--verify", from, "--internal"], ~r/--internal is for --transfer only/},
      {["--source", "x", "--out", out, "--volume", dir, "--internal"],
       ~r/--internal is for --transfer only/},
      {["--transfer", from, "--out", out, "--internal"], ~r/needs --expect-manifest-sha256/},
      {[
         "--transfer",
         from,
         "--out",
         out,
         "--internal",
         "--volume",
         dir,
         "--expect-manifest-sha256",
         @digest
       ], ~r/cannot be given with --volume/},
      {["--transfer", from, "--out", out, "--volume", dir, "--reserve-gib", "5"],
       ~r/--reserve-gib is for --internal only/},
      {[
         "--transfer",
         from,
         "--out",
         out,
         "--internal",
         "--reserve-gib",
         "-1",
         "--expect-manifest-sha256",
         @digest
       ], ~r/must not be negative/},
      {["--transfer", from, "--out", out], ~r/--volume is required with --transfer/}
    ]

    for {args, expected} <- refusals do
      assert_raise Mix.Error, expected, fn -> Bundle.run(args) end
    end

    refute File.exists?(out)
  end
end
