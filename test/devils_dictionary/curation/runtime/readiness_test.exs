defmodule DevilsDictionary.Curation.Runtime.ReadinessTest do
  @moduledoc """
  R1 and R2 of `docs/curation/runtime-stage-a.md`: readiness refuses with a
  stable reason, and never pulls, creates or starts anything. The Ollama
  client's request shape and failure kinds are tested here too.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.Runtime.{
    Authority,
    Contract,
    FakeSystem,
    Gateway,
    Ollama,
    Readiness
  }

  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    config = model_config!() |> ready!()
    key = "ready-#{System.unique_integer([:positive])}"
    %{config: config, opts: bind!(service_key: key), key: key}
  end

  defp refusal(ctx, opts \\ []) do
    case Readiness.check(ctx.config, Keyword.merge(ctx.opts, opts)) do
      {:ok, _report} -> :ok
      {:error, reason, _report} -> reason
    end
  end

  test "a mounted external root, the pinned version and the pinned artifact make it ready", ctx do
    stub_ollama!(ctx.config)

    assert {:ok, %{checks: checks}} = Readiness.check(ctx.config, ctx.opts)

    assert Enum.map(checks, & &1.check) ==
             [
               :slot,
               :volume,
               :models_root,
               :authority,
               :runtime_version,
               :served_digest,
               :manifest_on_root
             ]
  end

  test "a missing or internal drive refuses before anything is asked of the service", ctx do
    stub_ollama!(ctx.config)

    FakeSystem.put(volume: {:ok, %{mounted: false, external: false, device: nil}})
    assert refusal(ctx) == :models_root_unmounted

    FakeSystem.put(volume: {:ok, %{mounted: true, external: false, device: "/dev/disk3s1"}})
    assert refusal(ctx) == :models_root_not_external

    FakeSystem.put(volume: {:ok, %{mounted: true, external: true, device: "/dev/x"}}, dirs: [])
    assert refusal(ctx) == :models_root_missing
  end

  test "an unreachable service, another version or a missing model refuses", ctx do
    Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))
    assert refusal(ctx) == :service_unreachable

    stub_ollama!(ctx.config, version: "0.0.1")
    assert refusal(ctx) == :runtime_version_mismatch

    stub_ollama!(ctx.config, models: [])
    assert refusal(ctx) == :model_missing
  end

  test "a served tag that moved to another artifact refuses, and nothing is pulled", ctx do
    test_pid = self()

    Req.Test.stub(Ollama, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})

      case conn.request_path do
        "/api/version" ->
          Req.Test.json(conn, %{"version" => runtime_version()})

        "/api/tags" ->
          Req.Test.json(conn, %{
            "models" => [
              %{"name" => ctx.config.model_name, "digest" => String.duplicate("a", 64)}
            ]
          })
      end
    end)

    assert refusal(ctx) == :digest_mismatch
    refute_received {:request, _, "/api/pull"}
  end

  test "a served manifest that is not the one on the external root refuses", ctx do
    stub_ollama!(ctx.config)
    FakeSystem.put(files: %{})
    bind!(ctx.opts)
    assert refusal(ctx) == :artifact_not_on_models_root

    FakeSystem.put_file(Readiness.manifest_path(ctx.config.model_name), "{}")
    assert refusal(ctx) == :artifact_not_on_models_root
  end

  test "a quarantined or paused slot refuses", ctx do
    stub_ollama!(ctx.config)
    Gateway.service!(ctx.key)
    {:ok, _} = Gateway.pause(:memory_pressure, ctx.opts)

    assert refusal(ctx) == :paused
    assert refusal(ctx, allow_paused: true) == :ok
  end

  test "a caller of any database but the bound one is refused, before the service is asked",
       ctx do
    # No stub: a refusal here must not reach the service at all.
    marker = fn identity -> FakeSystem.put_file(Authority.path(), Jason.encode!(identity)) end
    mine = Authority.identity(ctx.opts)

    marker.(%{mine | "database" => "devils_dictionary_elsewhere"})
    assert refusal(ctx) == :foreign_authority

    assert {:error, :foreign_authority, %{checks: checks}} = Readiness.check(ctx.config, ctx.opts)

    assert %{check: :authority, detail: %{"database" => "devils_dictionary_elsewhere"}} =
             List.last(checks)

    # The same database name on another PostgreSQL cluster is another database.
    marker.(%{mine | "system_identifier" => "1"})
    assert refusal(ctx) == :foreign_authority

    # A second slot row under another key would be a second slot.
    marker.(%{mine | "service_key" => "another-key"})
    assert refusal(ctx) == :foreign_authority

    FakeSystem.put_file(Authority.path(), "not json")
    assert refusal(ctx) == :authority_unreadable

    FakeSystem.put(files: %{})
    assert refusal(ctx) == :authority_unbound
  end

  describe "binding the service (ServiceProcess.start/1)" do
    @describetag :tmp_dir

    test "binds once, keeps its own binding, and moves only on an explicit rebind", ctx do
      opts = [run_dir: ctx.tmp_dir, system: DevilsDictionary.Curation.Runtime.System]
      path = Authority.path(opts)
      mine = Authority.identity(opts)

      assert {:ok, ^mine} = Authority.bind(opts)
      assert Jason.decode!(File.read!(path)) == mine
      assert {:ok, ^mine} = Authority.check(opts)
      assert {:ok, ^mine} = Authority.bind(opts)

      File.write!(path, Jason.encode!(%{mine | "database" => "devils_dictionary_elsewhere"}))

      assert {:error, {:bound_to_other_database, "devils_dictionary_elsewhere"}} =
               Authority.bind(opts)

      assert Jason.decode!(File.read!(path))["database"] == "devils_dictionary_elsewhere"

      File.write!(path, "not json")
      assert {:error, :authority_unreadable} = Authority.bind(opts)

      assert {:ok, ^mine} = Authority.bind(Keyword.put(opts, :rebind, true))
      assert Jason.decode!(File.read!(path)) == mine
    end
  end

  test "the manifest path is the library layout under the models root" do
    assert Readiness.manifest_path("qwen3.5:4b") ==
             "/Volumes/Test Models/dictionary/ollama/manifests/registry.ollama.ai/library/qwen3.5/4b"

    assert Readiness.manifest_path("someone/model") =~ "/registry.ollama.ai/someone/model/latest"
  end

  describe "the client" do
    test "chat is one nonstreaming call with the schema, the pinned options and no retries",
         ctx do
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:chat, Jason.decode!(body)})
        Req.Test.json(conn, answer(abstain()))
      end)

      assert {:ok, %{"done" => true}} =
               Ollama.chat(ctx.config, [%{role: "user", content: "hi"}], Contract.schema())

      assert_received {:chat, request}
      assert request["stream"] == false
      assert request["think"] == false
      assert request["format"] == Contract.schema()

      assert request["options"] == %{
               "num_ctx" => 8192,
               "num_predict" => 1024,
               "seed" => 195,
               "temperature" => 0
             }

      assert request["keep_alive"] == "10m"
      refute Map.has_key?(request, "tools")
    end

    test "a refused connection was never sent; a timeout is uncertain; an error answer is an answer",
         ctx do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, {:not_sent, :econnrefused}} = Ollama.chat(ctx.config, [], %{})

      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :timeout))
      assert {:error, {:uncertain, :timeout}} = Ollama.chat(ctx.config, [], %{})

      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :closed))
      assert {:error, {:uncertain, :closed}} = Ollama.chat(ctx.config, [], %{})

      Req.Test.stub(Ollama, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "model not found"})
      end)

      assert {:error, {:http, 404, "model not found"}} = Ollama.chat(ctx.config, [], %{})
    end

    test "think is sent only for a model that can think", ctx do
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:chat, Jason.decode!(body)})
        Req.Test.json(conn, answer(abstain()))
      end)

      plain = %{ctx.config | generation: Map.delete(ctx.config.generation, "think")}
      {:ok, _} = Ollama.chat(plain, [], %{})
      assert_received {:chat, request}
      refute Map.has_key?(request, "think")
    end
  end
end
