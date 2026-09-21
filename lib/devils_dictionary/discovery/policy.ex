defmodule DevilsDictionary.Discovery.Policy do
  @moduledoc """
  Validated cache-freshness and outbound-request policy for discovery sources.

  Defaults apply to every server-side provider. A source may override only the
  documented keys, which keeps cache policy separate from provider transport
  and lets operators change intervals without a deploy-time code change.
  """

  @keys [
    :positive_refresh_seconds,
    :empty_refresh_seconds,
    :request_budget_limit,
    :request_budget_window_seconds,
    # How long this source's disposable cache may be held at all (#142). The
    # shipped default is the shared seven days; a source whose licence names a
    # shorter window overrides it here and `Discovery.cleanup/0` enforces it,
    # including against runs that are currently on display — which the general
    # sweep deliberately protects. The Guardian's Open Platform terms say 24
    # hours, "whether or not published on Your Website".
    :retention_seconds
  ]

  @doc "Returns the validated policy for a provider slug."
  def for!(source_slug) when is_binary(source_slug) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)

    defaults = Keyword.take(config, @keys)
    overrides = config |> Keyword.get(:source_policies, %{}) |> Map.get(source_slug, [])
    policy = Keyword.merge(defaults, overrides)

    validate_keys!(source_slug, defaults, overrides)

    Map.new(@keys, fn key ->
      value = Keyword.fetch!(policy, key)

      valid? =
        if key in [:positive_refresh_seconds, :empty_refresh_seconds],
          do: is_integer(value) and value >= 0,
          else: is_integer(value) and value > 0

      unless valid? do
        raise ArgumentError,
              "discovery policy #{inspect(key)} for #{inspect(source_slug)} has an invalid duration or limit"
      end

      {key, value}
    end)
  end

  @doc """
  The sources whose licence gives them a retention window of their own.

  `[{slug, seconds}]`, from the `retention_seconds` overrides in
  `:source_policies` — the sources `Discovery.cleanup/0` sweeps separately,
  ahead of and more strictly than the shared window. A source that names none
  is not in this list and is swept only by the shared rules.
  """
  def source_retentions do
    :devils_dictionary
    |> Application.fetch_env!(:discovery)
    |> Keyword.get(:source_policies, %{})
    |> Enum.flat_map(fn {slug, overrides} ->
      # Through `for!/1`, so a window that is not a positive integer raises
      # here — at the sweep, loudly — rather than being dropped from the list
      # and leaving the source swept only by the shared seven days.
      if Keyword.has_key?(overrides, :retention_seconds),
        do: [{slug, for!(slug).retention_seconds}],
        else: []
    end)
    |> Enum.sort()
  end

  @doc "Selects the refresh interval for a successful provider response."
  def refresh_seconds(source_slug, result_count) when is_integer(result_count) do
    policy = for!(source_slug)

    if result_count == 0,
      do: policy.empty_refresh_seconds,
      else: policy.positive_refresh_seconds
  end

  defp validate_keys!(source_slug, defaults, overrides) do
    missing = @keys -- Keyword.keys(defaults)
    unknown = Keyword.keys(overrides) -- @keys

    if missing != [] do
      raise ArgumentError, "missing discovery policy defaults: #{inspect(missing)}"
    end

    if unknown != [] do
      raise ArgumentError,
            "unknown discovery policy overrides for #{inspect(source_slug)}: #{inspect(unknown)}"
    end
  end
end
