defmodule DevilsDictionary.FakePartialDiscoveryProvider do
  @moduledoc """
  A provider that exports `retrieve/4` and nothing else the pipeline calls.

  `retrieve/4` is the callback the run worker reaches last, not the only one it
  reaches: `Discovery` builds the automatic mapping with `automatic_mapping/1`
  and `Transport` builds the request with `request_options/1`, both before a run
  ever executes. A gate that asks only for `retrieve/4` would admit this module
  and let it raise `UndefinedFunctionError` inside a queued run, where nothing
  can recover it. This fixture is that shape, and it has to be rejected.
  """

  @behaviour DevilsDictionary.Discovery.Provider

  @impl true
  def slug, do: "partial-fixture"

  @impl true
  def adapter_version, do: "partial.fixture.v1"

  @impl true
  def enabled?, do: true

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Partial fixture",
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

  @impl true
  def retrieve(_operation, _mapping, _request, _request_fun) do
    raise "the gate should have rejected this provider long before a run executed"
  end
end
