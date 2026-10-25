defmodule DevilsDictionary.Curation.Runtime.ServiceProcessTest do
  @moduledoc """
  The service's pid file is only a claim. After a reboot its pid can belong
  to another program, and signalling that program, or calling its death the
  confirmed stop recovery settles on, would both be wrong. These run on the
  fake host with a temporary run directory. The port check is the real
  `lsof`, pointed at a port nothing listens on.

  A stop is confirmed only when the server and every runner it started are
  gone (#221 S1): a runner holds the loaded weights, and one that outlives
  its server would be loaded again beside it on restart.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.Runtime.{Endpoint, FakeSystem, ServiceProcess}

  @moduletag :tmp_dir

  setup ctx do
    opts = [
      run_dir: ctx.tmp_dir,
      base_url: "http://127.0.0.1:9",
      stop_wait_ms: 0,
      kill_wait_ms: 0
    ]

    pid_file = Path.join(ctx.tmp_dir, "ollama.pid")
    runner = Path.join(Path.dirname(Endpoint.get(:binary)), "llama-server")
    %{opts: opts, pid_file: pid_file, runner: runner}
  end

  # A server (`ollama serve`) at `server` with one runner at `runner_pid`.
  defp server_with_runner(ctx, server, runner_pid, row \\ %{}) do
    File.write!(ctx.pid_file, Integer.to_string(server))

    FakeSystem.put(
      alive: MapSet.new([server, runner_pid]),
      processes: [
        %{pid: server, ppid: 1, command: Endpoint.get(:binary)},
        Map.merge(%{pid: runner_pid, ppid: server, command: ctx.runner}, row)
      ]
    )
  end

  test "no pid file is no recorded service", ctx do
    assert {:error, :no_recorded_service} = ServiceProcess.stop(ctx.opts)
    assert %{pid: nil, alive: false} = ServiceProcess.status(ctx.opts)
  end

  test "a recorded pid now running another program is stale: never signalled", ctx do
    File.write!(ctx.pid_file, "424242")
    FakeSystem.put(alive: MapSet.new([424_242]), commands: %{424_242 => "/usr/bin/other"})

    assert %{pid: 424_242, alive: false} = ServiceProcess.status(ctx.opts)

    assert {:ok, %{evidence: %{"method" => "not_running", "stopped_pid" => 424_242}}} =
             ServiceProcess.stop(ctx.opts)

    refute File.exists?(ctx.pid_file)
    assert FakeSystem.signals() == []
  end

  test "a recorded pid that is gone is stale too", ctx do
    File.write!(ctx.pid_file, "424243")

    assert {:ok, %{evidence: %{"method" => "not_running"}}} = ServiceProcess.stop(ctx.opts)
    refute File.exists?(ctx.pid_file)
  end

  test "the recorded pid is the service only while it runs the configured binary", ctx do
    File.write!(ctx.pid_file, "424244")
    FakeSystem.put(alive: MapSet.new([424_244]))
    assert %{alive: true} = ServiceProcess.status(ctx.opts)

    FakeSystem.put(commands: %{424_244 => Endpoint.get(:binary) <> "-other"})
    assert %{alive: false} = ServiceProcess.status(ctx.opts)
  end

  describe "runners (#221 S1)" do
    test "a server that shuts its runner down is stopped with one signal", ctx do
      server_with_runner(ctx, 424_250, 424_251, %{dies_with_parent: true})

      assert {:ok, %{stopped_at: %DateTime{}, evidence: evidence}} = ServiceProcess.stop(ctx.opts)
      assert evidence["method"] == "sigterm"
      assert evidence["runners"] == [%{"pid" => 424_251, "command" => "llama-server"}]
      assert FakeSystem.signals() == [{424_250, :term}]
    end

    # #221's scenario: a hung server needs SIGKILL, which leaves its runner
    # orphaned under launchd with the weights loaded.
    test "a runner a killed server left behind is ended before the stop is confirmed", ctx do
      server_with_runner(ctx, 424_252, 424_253)
      FakeSystem.put(survives: %{424_252 => [:term]})

      assert {:ok, %{evidence: evidence}} = ServiceProcess.stop(ctx.opts)
      assert evidence["runners"] == [%{"pid" => 424_253, "command" => "llama-server"}]

      assert FakeSystem.signals() == [{424_252, :term}, {424_252, :kill}, {424_253, :term}]
      refute File.exists?(ctx.pid_file)
    end

    test "a runner that will not end means no confirmed stop", ctx do
      server_with_runner(ctx, 424_254, 424_255)
      FakeSystem.put(survives: %{424_255 => [:term, :kill]})

      assert {:error, {:runners_still_running, [424_255]}} = ServiceProcess.stop(ctx.opts)
      assert {424_255, :kill} in FakeSystem.signals()

      # Nothing for recovery to settle on: the pid file stays, and so does the
      # quarantine.
      assert File.exists?(ctx.pid_file)
    end

    test "after a server died on its own, its leftover runner is found under launchd", ctx do
      File.write!(ctx.pid_file, "424256")

      FakeSystem.put(
        alive: MapSet.new([424_257, 424_258]),
        processes: [
          %{pid: 424_257, ppid: 1, command: ctx.runner},
          %{pid: 424_258, ppid: 1, command: "/usr/libexec/elsewhere/llama-server"}
        ]
      )

      assert {:ok, %{evidence: evidence}} = ServiceProcess.stop(ctx.opts)
      assert evidence["method"] == "not_running"
      assert evidence["runners"] == [%{"pid" => 424_257, "command" => "llama-server"}]

      # Only the runtime's own directory is the service's. Another program's
      # server is never signalled.
      assert FakeSystem.signals() == [{424_257, :term}]
    end

    test "without the process table nothing is signalled and nothing is confirmed", ctx do
      server_with_runner(ctx, 424_259, 424_260)
      FakeSystem.put(processes: :unavailable)

      assert {:error, :process_table_unavailable} = ServiceProcess.stop(ctx.opts)
      assert FakeSystem.signals() == []
      assert File.exists?(ctx.pid_file)
    end
  end
end
