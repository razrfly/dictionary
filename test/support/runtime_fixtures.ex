defmodule DevilsDictionary.RuntimeFixtures do
  @moduledoc """
  A controlled local fake of the private Ollama service, and the rows the
  curation runtime (#195) runs against. No test reaches a real model.

    * `model_config!/1` inserts a pinned model config whose manifest body
      hashes to its digest, as a real one does.
    * `ready!/1` puts that manifest on the fake external root, and `bind!/1`
      binds the fake service's slot to the test database.
    * `stub_ollama!/1` answers `/api/version`, `/api/tags`, `/api/show` and
      `/api/chat` through `Req.Test`. `:chat` is a function of the decoded
      request, so a test chooses the model's answer, or a transport error.
    * `answer/2` builds an `/api/chat` response around some content.
  """

  import DevilsDictionary.CurationFixtures, only: [actor!: 1]

  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.{Authority, FakeSystem, ModelConfig, Ollama, Readiness}
  alias DevilsDictionary.Repo

  @runtime_version "0.21.0"

  def runtime_version, do: @runtime_version

  @doc "A manifest body and the digest it hashes to."
  def manifest(tag \\ "4b") do
    body =
      Jason.encode!(%{
        "schemaVersion" => 2,
        "layers" => [
          %{
            "mediaType" => "application/vnd.ollama.image.model",
            "digest" => "sha256:" <> Digest.sha256("weights-#{tag}"),
            "size" => 1
          }
        ]
      })

    {body, Digest.sha256(body)}
  end

  @doc "A pinned model config row (`qwen3.5:4b` unless told otherwise)."
  def model_config!(attrs \\ %{}) do
    {_body, digest} = manifest(Map.get(attrs, :tag, "4b"))
    actor = actor!(DevilsDictionary.CurationFixtures.account([:reviewer]))
    model = Map.get(attrs, :model_name, "qwen3.5:#{Map.get(attrs, :tag, "4b")}")

    Repo.insert!(%ModelConfig{
      slug: Map.get(attrs, :slug, "test-#{System.unique_integer([:positive])}"),
      runtime: "ollama",
      model_name: model,
      manifest_digest: Map.get(attrs, :manifest_digest, digest),
      layers: [],
      weights_digest: Digest.sha256("weights"),
      quantization: "Q4_K_M",
      runtime_version: Map.get(attrs, :runtime_version, @runtime_version),
      capabilities: ["completion", "thinking"],
      generation: %{
        "num_ctx" => 8192,
        "num_predict" => 1024,
        "temperature" => 0,
        "seed" => 195,
        "think" => false,
        "keep_alive" => "10m"
      },
      instruction_version: "generic-editor-v1",
      output_contract_version: "selection-output-v1",
      config_hash: Digest.sha256("config-#{System.unique_integer([:positive])}"),
      created_by_actor_id: actor.id
    })
  end

  @doc """
  Binds the fake service to this test's database and `opts`' service key, as
  `ServiceProcess.start/1` binds the real one (`Runtime.Authority`). Returns
  `opts`.
  """
  def bind!(opts \\ []) do
    FakeSystem.put_file(Authority.path(opts), Jason.encode!(Authority.identity(opts)))
    opts
  end

  @doc "Puts the config's manifest on the fake external models root."
  def ready!(%ModelConfig{} = config) do
    tag = config.model_name |> String.split(":") |> List.last()
    {body, _digest} = manifest(tag)
    FakeSystem.put_file(Readiness.manifest_path(config.model_name), body)
    config
  end

  @doc """
  The fake service. `opts`:

    * `:version`: what `/api/version` says;
    * `:models`: what `/api/tags` lists;
    * `:chat`: a function of the decoded chat request, returning `{:json,
      body}`, `{:status, code, body}` or `{:transport, reason}`.
  """
  def stub_ollama!(config, opts \\ []) do
    models =
      Keyword.get(opts, :models, [
        %{
          "name" => config.model_name,
          "model" => config.model_name,
          "digest" => config.manifest_digest
        }
      ])

    version = Keyword.get(opts, :version, @runtime_version)
    chat = Keyword.get(opts, :chat, fn _request -> {:json, answer(abstain())} end)
    # What `/api/ps` lists as loaded: nothing, unless a test says the model
    # will not unload.
    loaded = Keyword.get(opts, :loaded, [])

    Req.Test.stub(Ollama, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/version"} ->
          Req.Test.json(conn, %{"version" => version})

        {"POST", "/api/generate"} ->
          Req.Test.json(conn, %{"done" => true})

        {"GET", "/api/ps"} ->
          Req.Test.json(conn, %{"models" => Enum.map(loaded, &%{"name" => &1})})

        {"GET", "/api/tags"} ->
          Req.Test.json(conn, %{"models" => models})

        {"POST", "/api/show"} ->
          Req.Test.json(conn, %{
            "details" => %{"quantization_level" => "Q4_K_M", "parameter_size" => "4B"},
            "capabilities" => ["completion", "thinking"],
            "license" => "Apache License\nVersion 2.0",
            "template" => "{{ .Prompt }}"
          })

        {"POST", "/api/chat"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          case chat.(Jason.decode!(body)) do
            {:json, response} ->
              Req.Test.json(conn, response)

            {:status, code, response} ->
              conn |> Plug.Conn.put_status(code) |> Req.Test.json(response)

            {:transport, reason} ->
              Req.Test.transport_error(conn, reason)
          end
      end
    end)

    :ok
  end

  @doc "An `/api/chat` response carrying `content` (a map is encoded)."
  def answer(content, extra \\ %{}) do
    content = if is_binary(content), do: content, else: Jason.encode!(content)

    Map.merge(
      %{
        "model" => "qwen3.5:4b",
        "message" => %{"role" => "assistant", "content" => content},
        "done" => true,
        "done_reason" => "stop",
        "total_duration" => 2_000_000_000,
        "load_duration" => 500_000_000,
        "prompt_eval_count" => 900,
        "prompt_eval_duration" => 700_000_000,
        "eval_count" => 120,
        "eval_duration" => 800_000_000
      },
      extra
    )
  end

  @doc "A valid abstention."
  def abstain,
    do: %{
      "decision" => "abstain",
      "lead" => nil,
      "highlights" => [],
      "abstain_reason" => "Nothing fits."
    }

  @doc "A selection of a lead and highlights, as `{candidate_id, meaning_id, quote}`."
  def selection(lead, highlights \\ []) do
    %{
      "decision" => "select",
      "lead" =>
        lead &&
          %{
            "candidate_id" => elem(lead, 0),
            "meaning_id" => elem(lead, 1),
            "reason" => "It defines the word."
          },
      "highlights" =>
        Enum.map(highlights, fn {c, m, q} ->
          %{
            "candidate_id" => c,
            "meaning_id" => m,
            "quote" => q,
            "reason" => "It shows the meaning."
          }
        end),
      "abstain_reason" => nil
    }
  end

  @doc "The candidate of a packet with the given object id."
  def candidate(frozen_or_packet, object_id) do
    packet = Map.get(frozen_or_packet, :packet, frozen_or_packet)
    Enum.find(packet["candidates"], &(&1["object_id"] == object_id))
  end
end
