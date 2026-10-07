defmodule DevilsDictionary.Curation.Runtime.Ollama do
  @moduledoc """
  The narrow HTTP client for the private Ollama service (#195), built on Req.

  It makes no decisions and holds no slot. `Runtime.Gateway` does both, and
  this module only speaks the API:

    * `version/1`, `tags/1`, `show/2`: what is served, for readiness and
      provenance;
    * `chat/4`: one **nonstreaming** `/api/chat` call with a JSON-schema
      `format`, the pinned generation options, and `think` only where the
      model reports it can think;
    * `pull/2`: explicit acquisition, used only by `mix dd.runtime.setup`.
      Readiness, requests and retries never pull.

  Req's own retries are off (`retry: false`). Failures fall into three kinds,
  because the gateway treats them differently:

    * `{:error, {:not_sent, reason}}`: the connection was refused, so the
      request was provably never written. This is the only retryable kind;
    * `{:error, {:uncertain, reason}}`: a timeout or broken connection after
      sending. The model may still be generating;
    * `{:error, {:http, status, detail}}`: the runtime answered, with an error.
  """

  alias DevilsDictionary.Curation.Runtime.{Endpoint, ModelConfig}

  @generation_options ~w(num_ctx num_predict temperature top_p top_k min_p seed repeat_penalty)

  @doc "The runtime's version string."
  def version(opts \\ []) do
    with {:ok, %{"version" => version}} <- get("/api/version", opts), do: {:ok, version}
  end

  @doc "The installed models, each with its name and manifest digest."
  def tags(opts \\ []) do
    with {:ok, %{"models" => models}} when is_list(models) <- get("/api/tags", opts),
         do: {:ok, models}
  end

  @doc "A model's details: template, license, parameters, capabilities, quantization."
  def show(model, opts \\ []), do: post("/api/show", %{model: model}, opts)

  @doc """
  One nonstreaming chat call under a pinned model config. `messages` are
  already rendered; `format` is the output JSON schema.
  """
  def chat(%ModelConfig{} = config, messages, format, opts \\ []) do
    generation = config.generation || %{}

    body =
      %{
        model: config.model_name,
        messages: messages,
        stream: false,
        format: format,
        options: Map.take(generation, @generation_options),
        keep_alive: Map.get(generation, "keep_alive", "10m")
      }
      |> maybe_put(:think, Map.get(generation, "think"))

    case request(:post, "/api/chat", body, Endpoint.get(:deadline_ms, opts), opts) do
      {:ok, %Req.Response{status: 200, body: %{} = response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: detail}} ->
        {:error, {:http, status, safe_detail(detail)}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, {:not_sent, :econnrefused}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:uncertain, reason}}

      {:error, exception} ->
        {:error, {:uncertain, exception.__struct__}}
    end
  end

  @doc """
  Pulls a model. **Explicit operator setup only**: `mix dd.runtime.setup
  --pull`. Nonstreaming, so it returns when the pull ends.
  """
  def pull(model, opts \\ []) do
    case request(:post, "/api/pull", %{model: model, stream: false}, :timer.hours(2), opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: detail}} ->
        {:error, {:http, status, safe_detail(detail)}}

      {:error, exception} ->
        {:error, {:unreachable, transport_reason(exception)}}
    end
  end

  defp get(path, opts) do
    case request(:get, path, nil, 10_000, opts) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, transport_reason(exception)}}
    end
  end

  defp post(path, body, opts) do
    case request(:post, path, body, 30_000, opts) do
      {:ok, %Req.Response{status: 200, body: %{} = response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: detail}} ->
        {:error, {:http, status, safe_detail(detail)}}

      {:error, exception} ->
        {:error, {:unreachable, transport_reason(exception)}}
    end
  end

  defp request(method, path, body, receive_timeout, opts) do
    [
      method: method,
      url: Endpoint.get(:base_url, opts) <> path,
      retry: false,
      receive_timeout: receive_timeout,
      connect_options: [timeout: 5_000]
    ]
    |> then(fn base -> if body, do: Keyword.put(base, :json, body), else: base end)
    |> Keyword.merge(Endpoint.req_options())
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.request()
  end

  defp transport_reason(%Req.TransportError{reason: reason}), do: reason
  defp transport_reason(exception), do: exception.__struct__

  # An error body is kept short and is never a prompt echo: the error
  # string only.
  defp safe_detail(%{"error" => error}) when is_binary(error), do: String.slice(error, 0, 200)
  defp safe_detail(_detail), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
