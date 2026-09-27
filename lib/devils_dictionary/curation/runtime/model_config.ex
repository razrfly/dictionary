defmodule DevilsDictionary.Curation.Runtime.ModelConfig do
  @moduledoc """
  One immutable model configuration (#195, `local_model_configs`): exactly
  which artifact, served by exactly which runtime, generating under exactly
  which settings.

  An attempt names one, so a mutable tag like `qwen3.5:4b` can never silently
  change what an attempt ran. Before each dispatch, readiness verifies that
  the served digest is `manifest_digest`. A new artifact, template, license,
  runtime version or generation setting is a new row with a new
  `config_hash`, never an edit.

  `generation` holds what is sent as Ollama `options`, plus `think` and
  `keep_alive`. `capabilities` is what `/api/show` reported, for example
  whether the model thinks and whether thinking can be turned off.
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  schema "local_model_configs" do
    field :slug, :string
    field :runtime, :string, default: "ollama"
    field :model_name, :string
    field :manifest_digest, :string
    field :layers, JsonValue, default: []
    field :weights_digest, :string
    field :parameter_size, :string
    field :quantization, :string
    field :family, :string
    field :format, :string
    field :license_name, :string
    field :license_digest, :string
    field :template_digest, :string
    field :runtime_version, :string
    field :capabilities, JsonValue, default: []
    field :generation, :map
    field :instruction_version, :string
    field :output_contract_version, :string
    field :config_hash, :string
    field :created_by_actor_id, :id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
