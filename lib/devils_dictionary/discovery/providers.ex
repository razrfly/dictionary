defmodule DevilsDictionary.Discovery.Providers do
  @moduledoc "The configured provider registry used by pages, workers and `mix dd.discovery`."

  alias DevilsDictionary.Discovery.Providers.CineGraph

  @default [CineGraph]

  def all do
    Application.get_env(:devils_dictionary, :discovery_providers, @default)
  end

  def get(slug) when is_atom(slug), do: get(Atom.to_string(slug))

  def get(slug) when is_binary(slug) do
    Enum.find(all(), &(&1.slug() == slug))
  end

  def source_catalog, do: Enum.map(@default, & &1.source_attrs())

  def capabilities do
    Enum.map(all(), fn provider ->
      provider.capabilities()
      |> Map.put(:slug, provider.slug())
      |> Map.put(:enabled, provider.enabled?())
    end)
  end

  def server_providers do
    Enum.filter(all(), fn provider ->
      capabilities = provider.capabilities()
      provider.enabled?() and capabilities.background and capabilities.transport == :server
    end)
  end
end
