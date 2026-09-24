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
    # How long this source's disposable cache may be held at all. The shipped
    # default is the shared seven days; a source whose licence names a shorter
    # window overrides it and `Discovery.cleanup/0` enforces it, including
    # against runs that are currently on display — which the bounded sweep
    # deliberately protects. The Guardian's Open Platform terms say 24 hours,
    # "whether or not published on Your Website" (#142); Spotify's say *do not
    # store indefinitely* (#143).
    :retention_seconds,
    :failure_backoff_seconds,
    :request_budget_limit,
    :request_budget_window_seconds
  ]

  # Refresh is how long a cached answer may be *reused*; retention is how long
  # it may be *held*. They were the same number until #144 Phase 2, which is
  # why the kit could refresh well and forget nothing: a source's terms may say
  # "not retained longer than 24 hours" (the Guardian, #142) or "removed on
  # termination" (Artsy), and neither is a statement about caching.
  # A duration of zero is a duration: "refresh on every visit", "hold nothing",
  # "retry at once". A budget of zero is a provider that can never run, which
  # is what `enabled?/0` and the source row are for.
  @durations [
    :positive_refresh_seconds,
    :empty_refresh_seconds,
    :retention_seconds,
    :failure_backoff_seconds
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
        if key in @durations,
          do: is_integer(value) and value >= 0,
          else: is_integer(value) and value > 0

      unless valid? do
        raise ArgumentError,
              "discovery policy #{inspect(key)} for #{inspect(source_slug)} has an invalid duration or limit"
      end

      {key, value}
    end)
  end

  # Budgets that belong to a source which is not a discovery provider but is
  # spent from inside a provider's run. Wikidata is the one: creator identity
  # fetches the QIDs a result credits and the registry lacks (#164 C1).
  # Since #158 build 5, the quotation verifier's checkers too: they are spent
  # from verification runs, never from a provider's.
  @shared_budgets ~w(wikidata gutenberg wikisource internet-archive quote-investigator google-books)

  @doc """
  Source slugs that carry a `source_policies` row without being providers.

  `Providers.validate!/0` refuses a policy naming an unregistered slug, so a
  renamed provider cannot leave a dead override behind. These are the
  exceptions it admits, each named here rather than let through by a pattern.
  """
  def shared_budgets, do: @shared_budgets

  @doc """
  The longest `request_budget_window_seconds` any source could be asked about:
  the global default or the largest per-source override. The attempts ledger
  may prune nothing younger than this, or a budget would count fewer requests
  than were made (CodeRabbit on #166, applied in #167).
  """
  def longest_budget_window_seconds do
    config = Application.fetch_env!(:devils_dictionary, :discovery)

    config
    |> Keyword.get(:source_policies, %{})
    |> Map.values()
    |> Enum.map(&Keyword.get(&1, :request_budget_window_seconds, 0))
    |> Enum.max(fn -> 0 end)
    |> max(Keyword.fetch!(config, :request_budget_window_seconds))
  end

  @doc "Every policy key, in the order `for!/1` returns them."
  def keys, do: @keys

  @doc """
  How long this source's results may be **held**, in seconds.

  Read by `Discovery.cleanup/0` and written onto every run as `expires_at`, so
  a held result carries its own deadline rather than depending on a sweep
  reading the policy that was in force when the sweep ran.
  """
  def retention_seconds(source_slug), do: for!(source_slug).retention_seconds

  @doc """
  How long a failed run waits before it may be attempted again, in seconds.

  Per source since #144 Phase 2. A shared five minutes is wrong in both
  directions: GDELT's one 429 closes its gate for a minute (#134) and a source
  that answered a malformed body will answer the same one in five.
  """
  def failure_backoff_seconds(source_slug), do: for!(source_slug).failure_backoff_seconds

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
