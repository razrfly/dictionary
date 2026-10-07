defmodule DevilsDictionary.Curation.Runtime.Provenance do
  @moduledoc """
  Records an installed model as an immutable `local_model_configs` row
  (#195), from what the running service and the external models root say
  about it:

    * `/api/version`: the runtime version;
    * `/api/tags`: the tag's manifest digest;
    * the manifest file under the models root, whose sha256 must be that
      digest, and whose layers give the weights digest;
    * `/api/show`: quantization, parameter size, family and format, the
      license (kept as a digest and a first line) and template (a digest),
      and capabilities.

  Generation settings default to #195's limits. `num_ctx` is 8192 and
  `num_predict` is 1024, and the output limit counts any thinking. `think` is
  `false` where the model reports the `thinking` capability, and absent
  otherwise. Temperature 0 and a fixed seed make repeated samples comparable.

  `register/3` is idempotent by `config_hash`. Registering the same artifact
  under the same settings returns the existing row, and anything that differs
  is a new row. Nothing is pulled here.
  """

  alias DevilsDictionary.Curation.Digest

  alias DevilsDictionary.Curation.Runtime.{
    Contract,
    Endpoint,
    ModelConfig,
    Ollama,
    Packet,
    Readiness
  }

  alias DevilsDictionary.Repo

  @weights_media "application/vnd.ollama.image.model"

  @doc "Generation settings for a model's capabilities."
  def generation(capabilities, overrides \\ %{}) do
    %{
      "num_ctx" => 8192,
      "num_predict" => 1024,
      "temperature" => 0,
      "seed" => 195,
      "keep_alive" => "10m",
      "think" => if("thinking" in capabilities, do: false, else: nil)
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Reads the served artifact and registers it under `slug`. Returns `{:ok,
  config}` (new or existing) or `{:error, reason}`.
  """
  def register(model_name, slug, actor_id, opts \\ []) do
    with {:ok, version} <- Ollama.version(opts),
         {:ok, models} <- Ollama.tags(opts),
         {:ok, digest} <- served_digest(models, model_name),
         {:ok, manifest} <- manifest(model_name, digest, opts),
         {:ok, show} <- Ollama.show(model_name, opts) do
      details = show["details"] || %{}
      capabilities = show["capabilities"] || []
      layers = Enum.map(manifest["layers"] || [], &Map.take(&1, ["mediaType", "digest", "size"]))

      attrs = %{
        runtime: "ollama",
        model_name: model_name,
        manifest_digest: digest,
        layers: layers,
        weights_digest: weights_digest(layers),
        parameter_size: details["parameter_size"],
        quantization: details["quantization_level"],
        family: details["family"],
        format: details["format"],
        license_name: license_name(show["license"]),
        license_digest: show["license"] && Digest.sha256(show["license"]),
        template_digest: show["template"] && Digest.sha256(show["template"]),
        runtime_version: version,
        capabilities: capabilities,
        generation: generation(capabilities, Keyword.get(opts, :generation, %{})),
        instruction_version: Packet.instruction_version(),
        output_contract_version: Contract.version()
      }

      hash = Digest.term(Map.new(attrs, fn {k, v} -> {to_string(k), v} end))

      case Repo.get_by(ModelConfig, config_hash: hash) do
        %ModelConfig{} = existing ->
          {:ok, existing}

        nil ->
          %ModelConfig{}
          |> struct(
            Map.merge(attrs, %{slug: slug, config_hash: hash, created_by_actor_id: actor_id})
          )
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.unique_constraint(:slug)
          |> Repo.insert()
      end
    end
  end

  defp served_digest(models, model_name) do
    case Enum.find(models, &(&1["name"] == model_name or &1["model"] == model_name)) do
      %{"digest" => digest} when is_binary(digest) -> {:ok, digest}
      _ -> {:error, :model_missing}
    end
  end

  defp manifest(model_name, digest, opts) do
    path = Readiness.manifest_path(model_name, opts)

    with {:ok, body} <- Endpoint.system(opts).read_file(path),
         true <- Digest.sha256(body) == digest || {:error, :artifact_not_on_models_root},
         {:ok, manifest} <- Jason.decode(body) do
      {:ok, manifest}
    else
      {:error, :artifact_not_on_models_root} = error -> error
      _ -> {:error, :artifact_not_on_models_root}
    end
  end

  defp weights_digest(layers) do
    case Enum.find(layers, &(&1["mediaType"] == @weights_media)) do
      %{"digest" => "sha256:" <> hex} -> hex
      %{"digest" => hex} -> hex
      _ -> nil
    end
  end

  defp license_name(nil), do: nil

  defp license_name(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.trim()
    |> String.slice(0, 120)
  end
end
