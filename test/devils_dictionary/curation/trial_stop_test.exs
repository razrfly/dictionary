defmodule DevilsDictionary.Curation.TrialStopTest do
  @moduledoc """
  #298 C6: the parameterised stop guard under `ops/curation/trial-stop/`.
  `trial-stop.sh` is run against a stub `mix` (DD_TRIAL_MIX), so nothing is
  stopped and no database is touched; `render-plist.sh` renders a valid
  plist and loads nothing.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @dir Path.expand("../../../ops/curation/trial-stop", __DIR__)

  setup %{tmp_dir: tmp} do
    run_dir = Path.join(tmp, "run dir")
    checkout = Path.join(tmp, "checkout")
    File.mkdir_p!(run_dir)
    File.mkdir_p!(checkout)
    calls = Path.join(tmp, "calls.log")
    stub = Path.join(tmp, "mix-stub")

    File.write!(stub, """
    #!/bin/zsh
    print -r -- "$PWD|DD_NO_OBAN=$DD_NO_OBAN|PHX_SERVER=${PHX_SERVER-unset}|$*" >> #{inspect(calls)}
    [[ "$*" == *physical-stop.exs* ]] && exit 0
    exit ${STUB_EXIT:-0}
    """)

    File.chmod!(stub, 0o755)
    %{run_dir: run_dir, checkout: checkout, calls: calls, stub: stub}
  end

  defp guard(ctx, args, env \\ []) do
    System.cmd(
      "/bin/zsh",
      [Path.join(@dir, "trial-stop.sh"), "--checkout", ctx.checkout | args],
      env: [{"DD_TRIAL_MIX", ctx.stub}, {"PHX_SERVER", "true"} | env],
      stderr_to_stdout: true
    )
  end

  defp calls(ctx) do
    case File.read(ctx.calls) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp epoch(offset), do: System.os_time(:second) + offset

  test "before the last minute it exits at once and runs nothing", ctx do
    assert {_, 0} = guard(ctx, ["--deadline", "#{epoch(3600)}", "--run-dir", ctx.run_dir])
    assert calls(ctx) == []
  end

  test "at the deadline it runs the stop from the checkout without Oban or a server", ctx do
    assert {_, 0} =
             guard(ctx, [
               "--deadline",
               "#{epoch(-5)}",
               "--run-dir",
               ctx.run_dir,
               "--reason",
               "batch d6 stop"
             ])

    [call] = calls(ctx)
    [pwd, oban, server, args] = String.split(call, "|")
    assert Path.basename(pwd) == "checkout"
    assert oban == "DD_NO_OBAN=1"
    assert server == "PHX_SERVER=unset"
    assert args =~ "run --no-start #{ctx.checkout}/ops/curation/trial-stop/stop.exs"
    assert args =~ "--run-dir #{ctx.run_dir} --reason batch d6 stop"
  end

  test "once STOPPED exists it exits at once, even past the deadline", ctx do
    File.write!(Path.join(ctx.run_dir, "STOPPED"), "done\n")
    assert {_, 0} = guard(ctx, ["--deadline", "#{epoch(-5)}", "--run-dir", ctx.run_dir])
    assert calls(ctx) == []
  end

  test "a failed stop runs the physical fallback and exits 1", ctx do
    assert {_, 1} =
             guard(ctx, ["--deadline", "#{epoch(-5)}", "--run-dir", ctx.run_dir], [
               {"STUB_EXIT", "1"}
             ])

    assert [stop, fallback] = calls(ctx)
    assert stop =~ "stop.exs --run-dir"
    assert fallback =~ "run --no-start #{ctx.checkout}/ops/curation/trial-stop/physical-stop.exs"
  end

  test "the dry run ignores the deadline and asks the stop script for a dry run only", ctx do
    File.write!(Path.join(ctx.run_dir, "STOPPED"), "done\n")

    assert {_, 0} =
             guard(ctx, ["--deadline", "#{epoch(86_400)}", "--run-dir", ctx.run_dir, "--dry-run"])

    [call] = calls(ctx)
    assert call =~ "stop.exs --dry-run --run-dir #{ctx.run_dir}"
    refute call =~ "--reason"
  end

  test "a frozen copy of the stop script can be named", ctx do
    copy = Path.join(ctx.run_dir, "stop.exs")

    assert {_, 0} =
             guard(ctx, [
               "--deadline",
               "#{epoch(-5)}",
               "--run-dir",
               ctx.run_dir,
               "--stop-script",
               copy
             ])

    [call] = calls(ctx)
    assert call =~ "run --no-start #{copy} --run-dir"
  end

  test "bad arguments are refused before anything runs", ctx do
    assert {_, 64} = guard(ctx, ["--deadline", "soon", "--run-dir", ctx.run_dir])
    assert {_, 64} = guard(ctx, ["--run-dir", ctx.run_dir])
    assert {_, 66} = guard(ctx, ["--deadline", "1", "--run-dir", ctx.run_dir <> "-missing"])
    assert calls(ctx) == []
  end

  test "the plist renders with the arguments escaped, and loads nothing", ctx do
    args = [
      "--label",
      "io.wordhoard.d6-batch-stop",
      "--script",
      "/Users/me/Library/Application Support/DictionaryTrial/trial-stop.sh",
      "--deadline",
      "1793800000",
      "--run-dir",
      ctx.run_dir,
      "--log",
      "/Users/me/Library/Application Support/DictionaryTrial/d6-stop.log",
      "--reason",
      "D6 batch <stop> & verify"
    ]

    {plist, 0} = System.cmd("/bin/zsh", [Path.join(@dir, "render-plist.sh") | args])
    assert plist =~ "<string>io.wordhoard.d6-batch-stop</string>"
    assert plist =~ "<string>1793800000</string>"
    assert plist =~ "<string>#{ctx.run_dir}</string>"
    assert plist =~ "D6 batch &lt;stop&gt; &amp; verify"
    refute plist =~ "--dry-run"
    refute plist =~ "__"

    {dry, 0} =
      System.cmd("/bin/zsh", [Path.join(@dir, "render-plist.sh") | args ++ ["--dry-run"]])

    assert dry =~ "<string>--dry-run</string>"

    if plutil = System.find_executable("plutil") do
      path = Path.join(ctx.run_dir, "guard.plist")
      File.write!(path, dry)
      assert {_, 0} = System.cmd(plutil, ["-lint", path])
    end

    assert {_, 64} =
             System.cmd("/bin/zsh", [Path.join(@dir, "render-plist.sh"), "--label", "bad label"],
               stderr_to_stdout: true
             )
  end
end
