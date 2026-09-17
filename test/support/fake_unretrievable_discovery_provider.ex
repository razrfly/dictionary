defmodule DevilsDictionary.FakeUnretrievableDiscoveryProvider do
  @moduledoc """
  A provider that claims the pipeline but cannot be driven by it.

  `transport: :server, background: true` is a declaration; `retrieve/4` is the
  only thing the run worker can actually call. This fixture declares the first
  without the second, which is the shape `server_providers/1` has to reject —
  otherwise the registry hands the worker a module with nothing to invoke.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  @impl true
  def slug, do: "unretrievable-fixture"

  @impl true
  def adapter_version, do: "unretrievable.fixture.v1"

  @impl true
  def enabled?, do: true

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Unretrievable fixture",
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      license: "Test fixture only",
      homepage: "https://fixture.invalid/",
      url_template: "https://fixture.invalid/",
      attribution: "Controlled fixture; not a live provider",
      active: true,
      config: %{}
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :persistent,
      pagination: :none,
      operations: ["search"],
      content_types: [:text]
    }
  end
end
