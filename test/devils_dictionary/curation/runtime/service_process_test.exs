defmodule DevilsDictionary.Curation.Runtime.ServiceProcessTest do
  @moduledoc """
  The service's pid file is only a claim. After a reboot its pid can belong
  to another program, and signalling that program, or calling its death the
  confirmed stop recovery settles on, would both be wrong. These run on the
  fake host with a temporary run directory. The port check is the real
  `lsof`, pointed at a port nothing listens on.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.Runtime.{Endpoint, FakeSystem, ServiceProcess}

  @moduletag :tmp_dir

  setup ctx do
    opts = [run_dir: ctx.tmp_dir, base_url: "http://127.0.0.1:9"]
    pid_file = Path.join(ctx.tmp_dir, "ollama.pid")
    %{opts: opts, pid_file: pid_file}
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
end
