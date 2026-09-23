defmodule DevilsDictionary.Discovery.Providers do
  @moduledoc """
  The configured provider registry used by pages, workers and `mix dd.discovery`.

  The list lives in `config :devils_dictionary, :discovery_providers`, so adding
  a provider is one config line and nothing else. Registration is deliberately
  weaker than retrieval: a module may stay in the registry — and therefore in
  the source catalog — while its transport or legal prerequisites are
  unresolved. `server_providers/1` is the gate that separates the two, and it
  admits only modules that can actually be driven through the pipeline.

  Weaker is not unchecked: `validate!/0` runs at boot and refuses to start a
  node whose registry holds a module that cannot be read as a provider at all
  (#144 Phase 0).
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

  @doc """
  Providers the **reader's browser** drives, for a target it has.

  The mirror of `server_providers/1`: a declaration of `transport: :browser` is
  a claim and `browser_config/1` returning a map is the proof — the provider is
  enabled, its key is present and its source row is active, all of which only
  it can answer. Returns `{provider, config}` pairs in registry order, and a
  provider that declines a target is simply absent (#144 Phase 3).

  Every registered provider is one of these two or neither-and-inert;
  `conformance_coverage_test.exs` asserts there is no third state.
  """
  def browser_providers(target) do
    Enum.flat_map(all(), fn provider ->
      # The config's content type must be one the provider declared — and
      # `validate!/0` has already checked that every declared one is a row
      # `ContentTypes` can present — so the shelf's `fetch!/1` cannot raise on
      # a type the provider made up at runtime.
      with true <- browser?(provider),
           %{content_types: declared} <- provider.capabilities(),
           config when is_map(config) <- provider.browser_config(target),
           true <- Map.get(config, :content_type) in declared do
        [{provider, config}]
      else
        _other -> []
      end
    end)
  end

  @doc """
  True when this provider declares the browser transport **and** exports the
  `browser_config/1` that makes the declaration usable.

  Both, because `browser_providers/1` requires both: a module that declared
  the transport without the callback passed this gate, passed the coverage
  check, and then had no shelf at runtime — the silent third state the check
  exists to refuse.
  """
  def browser?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) and
      function_exported?(provider, :browser_config, 1) and
      provider.capabilities().transport == :browser
  end

  @pipeline_callbacks [
    retrieve: 4,
    automatic_mapping: 1,
    request_options: 1,
    validate_mapping: 2
  ]

  @doc """
  True when the module exports every callback the pipeline drives it through.

  `retrieve/4` alone is not enough: `Discovery` builds the automatic mapping
  with `automatic_mapping/1`, `Transport` builds the request with
  `request_options/1`, and both `execute_owned_run/1` and
  `eligible_provider_for_mapping/1` call `validate_mapping/2` **unconditionally**
  — on every render, not only mid-run. All four, or none.

  `validate_mapping/2` joined the list in #144 Phase 0. The contract documented
  it as optional while the pipeline called it without a probe, so a registered
  provider without it passed this gate and then raised on the first page that
  asked for it. The documentation was the thing that was wrong: it is not
  optional, and this list is now the whole truth about what the pipeline drives.
  """
  def retrievable?(provider) do
    Code.ensure_loaded?(provider) and
      Enum.all?(@pipeline_callbacks, fn {callback, arity} ->
        function_exported?(provider, callback, arity)
      end)
  end

  @doc "The callbacks `retrievable?/1` requires, as `{name, arity}` pairs."
  def pipeline_callbacks, do: @pipeline_callbacks

  @registration_callbacks [
    slug: 0,
    source_attrs: 0,
    adapter_version: 0,
    capabilities: 0,
    enabled?: 0
  ]

  @required_capabilities [
    :background,
    :transport,
    :persistence,
    :pagination,
    :operations,
    :content_types
  ]

  @pacing_keys [:min_retry_interval_ms, :request_interval_ms]

  @tiers [:aristocracy, :middle, :plebs]

  @doc """
  Checks every registered provider's declaration, and refuses to boot on a bad one.

  Called from `DevilsDictionary.Application.start/2`, before the supervisor, for
  the same reason `DevilsDictionary.Discovery.ContentTypes` raises at compile
  time on a bad row: a capability map is read by bare `Map.fetch!/2` deep inside
  `admit/5`, so a missing key was a `KeyError` on the first page that happened to
  reach that provider, in production, with a stack trace naming the pipeline
  rather than the provider that lied to it (#144 Phase 0).

  What it checks, per registered module:

    * it is loadable and exports the five registration callbacks
    * `source_attrs/0` is a map whose `:slug` is `slug/0`, with a name, an
      attribution and a tier a shelf can rank — the row the catalog seeds
    * `capabilities/0` carries the six documented keys with the documented
      types, declares at least one operation and one content type, and every
      content type is one `ContentTypes` can present
    * the optional pacing keys, where declared, are non-negative integers
    * a module declaring the background pipeline exports all of
      `pipeline_callbacks/0`

  and once, across the registry:

    * every `:source_policies` key in `config :devils_dictionary, :discovery`
      names a registered slug, so a renamed provider cannot leave a dead
      override that silently stops applying

  Every failure is collected before any is raised: a bad registry should print
  everything wrong with it, not the first thing.
  """
  def validate! do
    providers = all()

    errors =
      Enum.flat_map(providers, &validate_provider/1) ++ validate_source_policies(providers)

    if errors != [] do
      raise ArgumentError,
            "the discovery provider registry is invalid:\n\n  " <> Enum.join(errors, "\n  ")
    end

    :ok
  end

  defp validate_provider(provider) do
    if Code.ensure_loaded?(provider) do
      missing =
        Enum.reject(@registration_callbacks, fn {callback, arity} ->
          function_exported?(provider, callback, arity)
        end)

      if missing == [],
        do: validate_attrs(provider) ++ validate_capabilities(provider),
        else: ["#{inspect(provider)} does not export #{inspect(missing)}"]
    else
      ["#{inspect(provider)} is registered but cannot be loaded"]
    end
  end

  defp validate_attrs(provider) do
    attrs = provider.source_attrs()
    slug = provider.slug()

    cond do
      not is_map(attrs) ->
        ["#{slug}: source_attrs/0 returned #{inspect(attrs)}, not a map"]

      attrs[:slug] != slug ->
        ["#{slug}: source_attrs/0 names slug #{inspect(attrs[:slug])}"]

      not present?(attrs[:name]) ->
        ["#{slug}: source_attrs/0 has no name"]

      not present?(attrs[:attribution]) ->
        ["#{slug}: source_attrs/0 has no attribution"]

      attrs[:tier] not in @tiers ->
        [
          "#{slug}: source_attrs/0 declares tier #{inspect(attrs[:tier])}, not one of #{inspect(@tiers)}"
        ]

      not present?(provider.adapter_version()) ->
        ["#{slug}: adapter_version/0 is empty"]

      true ->
        []
    end
  end

  defp validate_capabilities(provider) do
    slug = provider.slug()
    capabilities = provider.capabilities()

    if is_map(capabilities) do
      missing = Enum.reject(@required_capabilities, &Map.has_key?(capabilities, &1))

      if missing == [],
        do:
          capability_values(slug, capabilities) ++
            pacing(slug, capabilities) ++ pipeline(provider, capabilities),
        else: ["#{slug}: capabilities/0 is missing #{inspect(missing)}"]
    else
      ["#{slug}: capabilities/0 returned #{inspect(capabilities)}, not a map"]
    end
  end

  defp capability_values(slug, capabilities) do
    unknown_types =
      capabilities.content_types
      |> List.wrap()
      |> Enum.reject(&(&1 in DevilsDictionary.Discovery.ContentTypes.known()))

    [
      {is_boolean(capabilities.background), "background is #{inspect(capabilities.background)}"},
      {capabilities.transport in [:server, :browser],
       "transport is #{inspect(capabilities.transport)}"},
      {capabilities.persistence in [:persistent, :transient],
       "persistence is #{inspect(capabilities.persistence)}"},
      {capabilities.pagination in [:none, :offset, :cursor],
       "pagination is #{inspect(capabilities.pagination)}"},
      {is_list(capabilities.operations) and capabilities.operations != [] and
         Enum.all?(capabilities.operations, &is_binary/1),
       "operations is #{inspect(capabilities.operations)}"},
      {is_list(capabilities.content_types) and capabilities.content_types != [],
       "content_types is #{inspect(capabilities.content_types)}"},
      {unknown_types == [],
       "declares #{inspect(unknown_types)}, which DevilsDictionary.Discovery.ContentTypes cannot present"}
    ]
    |> Enum.reject(&elem(&1, 0))
    |> Enum.map(fn {_ok, message} -> "#{slug}: #{message}" end)
  end

  # Absent is the only thing that may be skipped. A declared key the transport
  # cannot read is normalised to unpaced, which is a rate the provider did not
  # ask for and would not notice losing.
  defp pacing(slug, capabilities) do
    Enum.flat_map(@pacing_keys, fn key ->
      case Map.fetch(capabilities, key) do
        :error -> []
        {:ok, ms} when is_integer(ms) and ms >= 0 -> []
        {:ok, other} -> ["#{slug}: #{key} is #{inspect(other)}, not non-negative milliseconds"]
      end
    end)
  end

  defp pipeline(provider, %{background: true, transport: :server}) do
    if retrievable?(provider),
      do: [],
      else: [
        "#{provider.slug()}: declares the background pipeline but does not export " <>
          inspect(@pipeline_callbacks)
      ]
  end

  defp pipeline(provider, %{transport: :browser}) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :browser_config, 1),
      do: [],
      else: [
        "#{provider.slug()}: declares the browser transport but does not export browser_config/1"
      ]
  end

  defp pipeline(_provider, _capabilities), do: []

  defp validate_source_policies(providers) do
    slugs = Enum.map(providers, & &1.slug()) ++ DevilsDictionary.Discovery.Policy.shared_budgets()

    :devils_dictionary
    |> Application.get_env(:discovery, [])
    |> Keyword.get(:source_policies, %{})
    |> Map.keys()
    |> Enum.reject(&(&1 in slugs))
    |> Enum.map(&"source_policies names #{inspect(&1)}, which is not a registered provider slug")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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
