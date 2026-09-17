defmodule DevilsDictionary.Discovery.ProvidersTest do
  @moduledoc """
  The registry is config, and a capability claim has to be backed by a callback.

  These are the two halves of the Phase 1 contract: registration is a one-line
  config change, and declaring `transport: :server, background: true` without
  exporting `retrieve/4` does not get a module scheduled.
  """

  use ExUnit.Case, async: false

  alias DevilsDictionary.Discovery.Providers
  alias DevilsDictionary.Discovery.Providers.{Artsy, CineGraph, Giphy}
  alias DevilsDictionary.FakeOffsetDiscoveryProvider
  alias DevilsDictionary.FakeUnretrievableDiscoveryProvider

  setup do
    configured = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery_providers, configured) end)
    %{configured: configured}
  end

  defp register(providers),
    do: Application.put_env(:devils_dictionary, :discovery_providers, providers)

  test "the shipped registry is the configured one, not a literal in the module", ctx do
    assert ctx.configured == [Artsy, CineGraph, Giphy]
    assert Providers.all() == ctx.configured
  end

  test "adding a module to the config list is the whole registration" do
    refute Enum.member?(Providers.all(), FakeOffsetDiscoveryProvider)

    register(
      Application.fetch_env!(:devils_dictionary, :discovery_providers) ++
        [FakeOffsetDiscoveryProvider]
    )

    assert Providers.get("offset-fixture") == FakeOffsetDiscoveryProvider
    assert FakeOffsetDiscoveryProvider in Providers.server_providers()
    assert FakeOffsetDiscoveryProvider in Providers.server_providers(:text)
    assert Providers.supports?("offset-fixture", :text)
    assert Providers.supports_any?("offset-fixture", [:film, :text])
    refute Providers.supports_any?("offset-fixture", [:film, :gif])

    assert %{slug: "offset-fixture", name: "Offset fixture"} =
             Enum.find(Providers.source_catalog(), &(&1.slug == "offset-fixture"))

    assert %{slug: "offset-fixture", enabled: true, content_types: [:text]} =
             Enum.find(Providers.capabilities(), &(&1.slug == "offset-fixture"))
  end

  test "a module that declares the pipeline but cannot retrieve is never scheduled" do
    register([FakeUnretrievableDiscoveryProvider])

    capabilities = FakeUnretrievableDiscoveryProvider.capabilities()
    assert capabilities.transport == :server
    assert capabilities.background
    assert FakeUnretrievableDiscoveryProvider.enabled?()

    refute Providers.retrievable?(FakeUnretrievableDiscoveryProvider)
    assert Providers.server_providers() == []

    # It stays registered, so its source row and catalog entry survive.
    assert Providers.get("unretrievable-fixture") == FakeUnretrievableDiscoveryProvider
    assert [%{slug: "unretrievable-fixture"}] = Providers.source_catalog()
  end

  test "every registered provider that claims the pipeline exports its callbacks", ctx do
    pipeline_providers =
      Enum.filter(ctx.configured, fn provider ->
        capabilities = provider.capabilities()
        capabilities.transport == :server and capabilities.background
      end)

    assert pipeline_providers != []

    for provider <- pipeline_providers do
      assert Code.ensure_loaded?(provider)

      for {callback, arity} <- [retrieve: 4, automatic_mapping: 1, request_options: 1] do
        assert function_exported?(provider, callback, arity),
               "#{inspect(provider)} declares transport: :server, background: true " <>
                 "but does not export #{callback}/#{arity}"
      end
    end
  end

  test "no provider may narrow the default retryable statuses", ctx do
    overriding =
      Enum.filter(ctx.configured ++ [FakeOffsetDiscoveryProvider], fn provider ->
        Code.ensure_loaded?(provider) and function_exported?(provider, :retryable_status?, 1)
      end)

    assert FakeOffsetDiscoveryProvider in overriding

    for provider <- overriding, status <- [429, 500, 502, 503, 504] do
      assert provider.retryable_status?(status),
             "#{inspect(provider)} stopped retrying #{status}; widening " <>
               "retryable_status?/1 must not drop the default cases"
    end
  end

  test "registration without the pipeline claim stays legal", ctx do
    for provider <- ctx.configured, not Providers.retrievable?(provider) do
      capabilities = provider.capabilities()

      refute capabilities.transport == :server and capabilities.background,
             "#{inspect(provider)} claims the pipeline without exporting retrieve/4"
    end

    # Artsy and GIPHY are registered so their source rows exist; neither is a
    # pipeline provider today, and Phase 1 does not change that.
    assert Providers.get("artsy") == Artsy
    assert Providers.get("giphy") == Giphy
    assert Enum.map(Providers.server_providers(), & &1.slug()) == ["cinegraph"]
  end
end
