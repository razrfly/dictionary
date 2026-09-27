defmodule DevilsDictionary.Curation.Runtime.Readiness do
  @moduledoc """
  Whether the runtime may take work under a model config (#195, R1, R2). It
  answers `{:ok, report}` or `{:error, reason, report}`, with a stable
  reason:

  | Reason | Meaning |
  |---|---|
  | `:quarantined`, `:paused` | the slot is held back (`Runtime.Gateway`) |
  | `:models_root_unmounted` | the model volume is not mounted |
  | `:models_root_not_external` | the "volume" is the internal disk |
  | `:models_root_missing` | the cache directory is absent |
  | `:service_unreachable` | nothing answers on the private endpoint |
  | `:runtime_version_mismatch` | the runtime is not the pinned version |
  | `:model_missing` | the pinned model is not installed |
  | `:digest_mismatch` | the served tag now points at another artifact |
  | `:artifact_not_on_models_root` | the served manifest is not the one on the external root |

  It never downloads, pulls, creates a directory or starts a process, so a
  missing drive, model or service is a refusal and never a repair. The
  structured-output smoke call is separate (`Runtime.smoke/2`), because it
  occupies the slot and is charged to the budget like any other call.
  """

  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.{Endpoint, Gateway, ModelConfig, Ollama}

  @doc "Checks everything, in order, and stops at the first refusal."
  def check(%ModelConfig{} = config, opts \\ []) do
    steps = [
      &slot/2,
      &volume/2,
      &root/2,
      &runtime_version/2,
      &served_digest/2,
      &manifest_on_root/2
    ]

    Enum.reduce_while(steps, {:ok, %{checks: []}}, fn step, {:ok, report} ->
      case step.(config, opts) do
        {:ok, name, detail} ->
          {:cont, {:ok, add(report, name, :ok, detail)}}

        {:error, name, reason, detail} ->
          {:halt, {:error, reason, add(report, name, reason, detail)}}
      end
    end)
  end

  defp add(report, name, status, detail),
    do: %{report | checks: report.checks ++ [%{check: name, status: status, detail: detail}]}

  defp slot(_config, opts) do
    service = Gateway.service!(Keyword.get(opts, :service_key))

    # `allow_paused:` is how resuming a paused service checks readiness first.
    case service.state do
      :quarantined ->
        {:error, :slot, :quarantined, service.quarantine_reason}

      :paused ->
        if opts[:allow_paused],
          do: {:ok, :slot, :paused},
          else: {:error, :slot, :paused, service.paused_reason}

      state ->
        {:ok, :slot, state}
    end
  end

  defp volume(_config, opts) do
    mount = Endpoint.get(:mount_point, opts)

    case Endpoint.system(opts).volume(mount) do
      {:ok, %{mounted: true, external: true} = v} ->
        {:ok, :volume, %{mount_point: mount, device: v.device}}

      {:ok, %{mounted: true}} ->
        {:error, :volume, :models_root_not_external, mount}

      _ ->
        {:error, :volume, :models_root_unmounted, mount}
    end
  end

  defp root(_config, opts) do
    root = Endpoint.get(:models_root, opts)

    if Endpoint.system(opts).dir?(root),
      do: {:ok, :models_root, root},
      else: {:error, :models_root, :models_root_missing, root}
  end

  defp runtime_version(config, opts) do
    case Ollama.version(opts) do
      {:ok, version} when version == config.runtime_version ->
        {:ok, :runtime_version, version}

      {:ok, version} ->
        {:error, :runtime_version, :runtime_version_mismatch, version}

      {:error, _} ->
        {:error, :runtime_version, :service_unreachable, Endpoint.get(:base_url, opts)}
    end
  end

  defp served_digest(config, opts) do
    case Ollama.tags(opts) do
      {:ok, models} ->
        case Enum.find(
               models,
               &(&1["name"] == config.model_name or &1["model"] == config.model_name)
             ) do
          nil ->
            {:error, :served_digest, :model_missing, config.model_name}

          %{"digest" => digest} when digest == config.manifest_digest ->
            {:ok, :served_digest, digest}

          %{"digest" => digest} ->
            {:error, :served_digest, :digest_mismatch, digest}
        end

      {:error, _} ->
        {:error, :served_digest, :service_unreachable, Endpoint.get(:base_url, opts)}
    end
  end

  defp manifest_on_root(config, opts) do
    path = manifest_path(config.model_name, opts)

    case Endpoint.system(opts).read_file(path) do
      {:ok, body} ->
        if Digest.sha256(body) == config.manifest_digest,
          do: {:ok, :manifest_on_root, path},
          else: {:error, :manifest_on_root, :artifact_not_on_models_root, path}

      {:error, _} ->
        {:error, :manifest_on_root, :artifact_not_on_models_root, path}
    end
  end

  @doc """
  Where Ollama keeps a library model's manifest under the models root:
  `qwen3.5:4b` → `manifests/registry.ollama.ai/library/qwen3.5/4b`.
  """
  def manifest_path(model_name, opts \\ []) do
    {name, tag} =
      case String.split(model_name, ":", parts: 2) do
        [name, tag] -> {name, tag}
        [name] -> {name, "latest"}
      end

    {namespace, name} =
      case String.split(name, "/", parts: 2) do
        [ns, n] -> {ns, n}
        [n] -> {"library", n}
      end

    Path.join([
      Endpoint.get(:models_root, opts),
      "manifests",
      "registry.ollama.ai",
      namespace,
      name,
      tag
    ])
  end
end
