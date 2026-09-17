defmodule DevilsDictionary.Discovery.Providers do
  @moduledoc """
  The configured provider registry used by pages, workers and `mix dd.discovery`.

  The list lives in `config :devils_dictionary, :discovery_providers`, so adding
  a provider is one config line and nothing else. Registration is deliberately
  weaker than retrieval: a module may stay in the registry — and therefore in
  the source catalog — while its transport or legal prerequisites are
  unresolved. `server_providers/1` is the gate that separates the two, and it
  admits only modules that can actually be driven through the pipeline.
  """

  def all, do: Application.fetch_env!(:devils_dictionary, :discovery_providers)

  def get(slug) when is_atom(slug), do: get(Atom.to_string(slug))

  def get(slug) when is_binary(slug) do
    Enum.find(all(), &(&1.slug() == slug))
  end

  def source_catalog, do: Enum.map(all(), & &1.source_attrs())

  def capabilities do
    Enum.map(all(), fn provider ->
      provider.capabilities()
      |> Map.put(:slug, provider.slug())
      |> Map.put(:enabled, provider.enabled?())
    end)
  end

  @doc """
  Providers the background pipeline can actually run.

  A declaration of `transport: :server, background: true` is a claim; exporting
  the retrieval callbacks is the proof. Without them the run worker has nothing
  to call, so such a module is registered but never scheduled.
  """
  def server_providers(content_type \\ nil) do
    Enum.filter(all(), fn provider ->
      capabilities = provider.capabilities()

      provider.enabled?() and capabilities.background and capabilities.transport == :server and
        retrievable?(provider) and
        (is_nil(content_type) or content_type in capabilities.content_types)
    end)
  end

  @pipeline_callbacks [retrieve: 4, automatic_mapping: 1, request_options: 1]

  @doc """
  True when the module exports every callback the pipeline drives it through.

  `retrieve/4` alone is not enough: `Discovery` builds the automatic mapping
  with `automatic_mapping/1` and `Transport` builds the request with
  `request_options/1`, so a module exporting one of the three and not the others
  would pass the gate and then raise mid-run. All three, or none.
  """
  def retrievable?(provider) do
    Code.ensure_loaded?(provider) and
      Enum.all?(@pipeline_callbacks, fn {callback, arity} ->
        function_exported?(provider, callback, arity)
      end)
  end

  @doc "The callbacks `retrievable?/1` requires, as `{name, arity}` pairs."
  def pipeline_callbacks, do: @pipeline_callbacks

  def supports?(slug, content_type) do
    case get(slug) do
      nil -> false
      provider -> content_type in provider.capabilities().content_types
    end
  end

  @doc "True when the provider declares any of `content_types`."
  def supports_any?(slug, content_types) do
    Enum.any?(content_types, &supports?(slug, &1))
  end
end
