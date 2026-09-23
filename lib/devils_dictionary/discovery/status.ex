defmodule DevilsDictionary.Discovery.Status do
  @moduledoc """
  The operator's two questions about discovery, answered once (#144 Phase 4).

  **Is it configured?** `preflight/0` reads the registry, each provider's own
  `enabled?/0`, its configuration stanza and its policy, and says per provider
  whether it is ready, switched off, or waiting for a credential.

  **What has it done?** `rows/0` reads the ledger — `discovery_runs`,
  `discovery_results`, `discovery_request_attempts` and the source row's
  provider-wide backoff — and says per provider how much was spent, what is
  held, what is stale and what retention is about to take.

  Both are derived from `Providers.all()` and the database, so a provider
  registered tomorrow has a row in both without an edit here, in either task,
  or on the page. `mix dd.discovery.check`, `mix dd.discovery.status` and
  `/ops/discovery` are three renderings of these two functions and hold no
  numbers of their own — the arrangement `Health.records/1` already has with
  `mix dd.health` and `/ops/imports`.

  ## What is never in here

  No credential value, in any field, at any point. `preflight/0` reports a
  credential as `:present` or `:missing` and never reads the value to say so:
  the presence map is built in `config/runtime.exs`, where the value is in
  scope, and only the boolean leaves that scope. An endpoint is not a secret —
  it is in `config/config.exs` in the open — so it is printed, after the same
  validation the CineGraph preflight has always applied: `http(s)`, a host, and
  no userinfo, query or fragment, which is where a credential would hide in a
  URL.
  """

  import Ecto.Query

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Mapping, Policy, Providers, RequestAttempt, Result, Run}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @doc """
  One configuration row per registered provider, in registry order.

  Each row carries:

    * `:slug`, `:provider`, `:kind` — `:server`, `:browser`, or `:inert` for a
      module that can neither be run nor rendered (`conformance_coverage_test`
      refuses one, and this reports it rather than assuming it cannot happen)
    * `:enabled` — the provider's own `enabled?/0`, which is the only authority
      on whether it is ready to be driven
    * `:switch` — `:on`, `:off` or `:unset`, from `:enabled` in its stanza. The
      difference between `enabled?/0` being false because an operator turned
      the shelf off and it being false because a credential never arrived
    * `:credentials` — `{name, :present | :missing}` for every environment
      variable `allowed_provider_env` admits under this provider's prefix
    * `:endpoints` — `{key, url, :ok | :invalid}` for every `*endpoint` key in
      its stanza
    * `:policy` — the validated policy, or the `ArgumentError` message
    * `:problems` — the sentences a preflight fails on: an unreadable endpoint,
      an invalid policy, a module that is neither runnable nor renderable

  A missing credential is **not** a problem: a keyless checkout is a legitimate
  deployment, it is what `enabled?/0` is for, and `mix dd.discovery.status` has
  to run there (#144 acceptance 5).
  """
  def preflight do
    credentials = credential_env()

    Enum.map(Providers.all(), fn provider ->
      slug = provider.slug()
      stanza = stanza(slug)
      endpoints = endpoints(stanza)
      policy = policy(slug)
      kind = kind(provider)

      %{
        slug: slug,
        provider: provider,
        kind: kind,
        enabled: provider.enabled?(),
        switch: switch(stanza),
        stanza: stanza_key(slug),
        credentials: Map.get(credentials, slug, []),
        endpoints: endpoints,
        policy: policy,
        problems: problems(slug, kind, endpoints, policy)
      }
    end)
  end

  @doc """
  One ledger row per registered provider, in registry order.

  Each row carries `:enabled` and `:switch` as `preflight/0` does — the four
  reasons a shelf is not there are told apart in one place — then `:runs`,
  `:failed`, `:last_success`, `:results` (held now),
  `:roots` and `:stale` (display roots, and how many of them are past their
  `refresh_after`), `:retention_due`, `:budget` with `:used` and `:limit` in
  the source's current window, `:backoff` when the provider is under a
  `Retry-After`, and the source row's `:active`.

  A provider with no source row — registered, never asked for anything — is a
  row of zeroes rather than an absence, because "this provider has never run"
  is the answer an operator came here for.

  `:retention_due` is counted from `Discovery.retention_due/1`, which is
  bounded: it answers for the next `limit` runs due, oldest first. The count is
  therefore "at least this many" on a database that has been holding things for
  a month, which is the same bound `Discovery.cleanup/0` sweeps under.
  """
  def rows(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    retention_limit = Keyword.get(opts, :retention_limit, 500)

    sources = sources()
    runs = runs_by_source()
    results = results_by_source()
    roots = roots_by_source(now)
    budgets = budget_by_source(sources, now)
    due = retention_due_by_slug(retention_limit)

    Enum.map(Providers.all(), fn provider ->
      slug = provider.slug()
      source = Map.get(sources, slug)
      id = source && source.id
      run = Map.get(runs, id, %{runs: 0, failed: 0, last_success: nil})
      root = Map.get(roots, id, %{roots: 0, stale: 0})

      %{
        slug: slug,
        provider: provider,
        kind: kind(provider),
        enabled: provider.enabled?(),
        switch: switch(stanza(slug)),
        active: source && source.active,
        runs: run.runs,
        failed: run.failed,
        last_success: run.last_success,
        results: Map.get(results, id, 0),
        roots: root.roots,
        stale: root.stale,
        retention_due: Map.get(due, slug, 0),
        budget: budget(slug, Map.get(budgets, id, 0)),
        backoff: backoff(source, now)
      }
    end)
  end

  @doc """
  What creator identity has done (#164): per provider, how many creator
  entries the held results carry in each state, plus the shared `wikidata`
  budget minting spends and the open `unresolved_creator` cases.

  The states are the hint `preview_metadata["creators"]` records at
  publication — `matched`, `minted`, `overridden`, `deferred`, `unresolved` —
  so this is a count of what runs *said*, which is what an operator asks
  ("is Open Library crosswalking anything?"). Whether a card links is decided
  from the assertions at render; the two can differ after a curator acts, and
  `overridden` is where that shows up.
  """
  def creator_identity(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{rows: rows} =
      Repo.query!("""
      SELECT source.slug, creator->>'state', count(*)
        FROM discovery_results AS result
        JOIN discovery_runs AS run ON run.id = result.run_id
        JOIN discovery_mappings AS mapping ON mapping.id = run.mapping_id
        JOIN sources AS source ON source.id = mapping.source_id
        CROSS JOIN LATERAL jsonb_array_elements(
          CASE jsonb_typeof(result.preview_metadata->'creators')
            WHEN 'array' THEN result.preview_metadata->'creators'
            ELSE '[]'::jsonb
          END
        ) AS creator
       GROUP BY source.slug, creator->>'state'
      """)

    by_provider =
      Enum.reduce(rows, %{}, fn [slug, state, count], acc ->
        Map.update(acc, slug, %{state => count}, &Map.put(&1, state, count))
      end)

    source = Repo.get_by(Source, slug: "wikidata")

    used =
      if source do
        cutoff = DateTime.add(now, -window("wikidata"), :second)

        Repo.aggregate(
          from(attempt in RequestAttempt,
            where: attempt.source_id == ^source.id and attempt.attempted_at > ^cutoff
          ),
          :count
        )
      else
        0
      end

    open_cases =
      Repo.aggregate(
        from(kase in DevilsDictionary.Sources.ReconciliationCase,
          where:
            kase.kind == ^DevilsDictionary.SourceIdentity.Creators.case_kind() and
              kase.status == :open
        ),
        :count
      )

    minted =
      Repo.aggregate(
        from(entity in DevilsDictionary.Registry.Entity,
          where: fragment("jsonb_exists(?, 'minted_by')", entity.metadata)
        ),
        :count
      )

    %{
      states: ~w(matched minted overridden deferred unresolved),
      providers:
        by_provider
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {slug, counts} -> %{slug: slug, counts: counts} end),
      budget: budget("wikidata", used),
      open_cases: open_cases,
      minted: minted
    }
  end

  @doc """
  Environment names `allowed_provider_env` admits that no registered provider
  claims, with whether each one is set.

  Artsy is why this is printed rather than dropped: it left the registry in
  #144 Phase 3 and `ARTSY_CLIENT_ID` and `ARTSY_CLIENT_SECRET` stayed on the
  list deliberately, for whoever revisits the decision. A name here is not an
  error — it is a credential nothing currently reads, which is worth an
  operator's glance and nothing more.
  """
  def unclaimed_credentials do
    claimed =
      credential_env()
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(fn {name, _status} -> name end)

    for {name, present} <- presence(), name not in claimed, do: {name, status(present)}
  end

  @doc """
  The environment-variable prefix for a slug: upper case, hyphens as
  underscores.

  The same rule `config/runtime.exs` derives the per-provider policy variables
  with — `bing-news` reads `BING_NEWS_…`, `open-library` `OPEN_LIBRARY_…` —
  because a shell cannot export a name with a hyphen in it.
  """
  def env_prefix(slug), do: slug |> String.upcase() |> String.replace("-", "_")

  # Which admitted environment names belong to which provider, by that prefix.
  # The list is `allowed_provider_env`'s credential half and the presence is
  # computed where the values are, in `config/runtime.exs`; nothing here has
  # ever seen a value.
  defp credential_env do
    slugs = Enum.map(Providers.all(), & &1.slug())

    Enum.reduce(presence(), %{}, fn {name, present}, claimed ->
      case Enum.filter(slugs, &String.starts_with?(name, env_prefix(&1) <> "_")) do
        [] ->
          claimed

        matches ->
          # Longest prefix wins, so a `BING_NEWS_…` name is not claimed by a
          # hypothetical `bing`.
          slug = Enum.max_by(matches, &String.length/1)
          Map.update(claimed, slug, [{name, status(present)}], &(&1 ++ [{name, status(present)}]))
      end
    end)
  end

  defp presence do
    :devils_dictionary
    |> Application.get_env(:provider_credentials, %{})
    |> Enum.sort()
  end

  defp status(true), do: :present
  defp status(_), do: :missing

  @doc """
  A provider's configuration stanza, as a keyword list.

  Read by the convention every registered provider follows: the slug, with
  hyphens as underscores, is the key under `:devils_dictionary`. A provider
  whose stanza is somewhere else has an empty one here, which the preflight
  prints as *no configuration* rather than treating as a failure — it is the
  provider's `enabled?/0` that decides whether that matters.
  """
  def stanza(slug) do
    case stanza_key(slug) do
      nil -> []
      key -> Application.get_env(:devils_dictionary, key, [])
    end
  end

  defp stanza_key(slug) do
    String.to_existing_atom(String.replace(slug, "-", "_"))
  rescue
    ArgumentError -> nil
  end

  defp switch(stanza) do
    case Keyword.fetch(stanza, :enabled) do
      {:ok, false} -> :off
      {:ok, _} -> :on
      :error -> :unset
    end
  end

  defp endpoints(stanza) do
    stanza
    |> Enum.filter(fn {key, value} ->
      is_binary(value) and String.ends_with?(Atom.to_string(key), "endpoint")
    end)
    |> Enum.map(fn {key, url} -> {key, url, if(sane_endpoint?(url), do: :ok, else: :invalid)} end)
  end

  @doc """
  An endpoint a preflight will pass: `http(s)`, a host, and nothing else.

  Userinfo, a query string and a fragment are refused for the reason the
  CineGraph check refused them since #88 — they are where a credential ends up
  when an endpoint is pasted whole out of a provider's dashboard, and an
  endpoint is the one configuration value this module prints.
  """
  def sane_endpoint?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def sane_endpoint?(_), do: false

  defp policy(slug) do
    {:ok, Policy.for!(slug)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp problems(slug, kind, endpoints, policy) do
    Enum.concat([
      for({key, _url, :invalid} <- endpoints, do: "#{slug}: #{key} is not an http(s) endpoint"),
      case policy do
        {:error, message} -> ["#{slug}: #{message}"]
        _ -> []
      end,
      if(kind == :inert,
        do: ["#{slug}: registered, but can neither be run by the pipeline nor rendered"],
        else: []
      )
    ])
  end

  defp kind(provider) do
    cond do
      Providers.retrievable?(provider) -> :server
      Providers.browser?(provider) -> :browser
      true -> :inert
    end
  end

  defp sources do
    from(source in Source,
      select: %{
        id: source.id,
        slug: source.slug,
        active: source.active,
        retry_after: source.discovery_retry_after,
        retry_reason: source.discovery_retry_reason
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.slug, &1})
  end

  defp runs_by_source do
    from(run in Run,
      join: mapping in Mapping,
      on: mapping.id == run.mapping_id,
      group_by: mapping.source_id,
      select:
        {mapping.source_id,
         %{
           runs: count(run.id),
           failed: filter(count(run.id), run.status == :failed),
           last_success: filter(max(run.completed_at), run.status == :succeeded)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  # What is held right now: rows in `discovery_results`, which retention and
  # the sweep both delete. A run whose results were withdrawn still counts its
  # spend above and holds nothing here, which is the pair of numbers that says
  # retention ran.
  defp results_by_source do
    from(result in Result,
      join: run in Run,
      on: run.id == result.run_id,
      join: mapping in Mapping,
      on: mapping.id == run.mapping_id,
      group_by: mapping.source_id,
      select: {mapping.source_id, count(result.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The display roots a reader would be served, and how many are past their
  # refresh clock. The `DISTINCT ON` is the one `Discovery.cleanup/0` protects
  # by and `latest_display_root/2` reads by, so the three agree on what a root
  # is: newest succeeded page-0 run per mapping and page context, still allowed
  # on display, under an enabled mapping.
  defp roots_by_source(now) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH roots AS (
          SELECT DISTINCT ON (runs.mapping_id, runs.page_context)
                 mappings.source_id, runs.refresh_after
            FROM discovery_runs AS runs
            JOIN discovery_mappings AS mappings ON mappings.id = runs.mapping_id
           WHERE mappings.enabled AND runs.page = 0 AND runs.status = 'succeeded'
             AND runs.display_allowed
           ORDER BY runs.mapping_id, runs.page_context, runs.completed_at DESC NULLS LAST,
                    runs.id DESC
        )
        SELECT source_id, count(*), count(*) FILTER (WHERE refresh_after <= $1)
          FROM roots
         GROUP BY source_id
        """,
        [now]
      )

    Map.new(rows, fn [source_id, roots, stale] -> {source_id, %{roots: roots, stale: stale}} end)
  end

  # Every source's window is its own — `request_budget_window_seconds` is a
  # policy key — so the cutoff differs per source and the query is one `OR` per
  # source rather than one cutoff for all of them.
  defp budget_by_source(sources, now) do
    conditions =
      Enum.reduce(sources, false, fn {slug, source}, acc ->
        cutoff = DateTime.add(now, -window(slug), :second)

        dynamic(
          [attempt],
          ^acc or (attempt.source_id == ^source.id and attempt.attempted_at > ^cutoff)
        )
      end)

    if sources == %{} do
      %{}
    else
      from(attempt in RequestAttempt,
        where: ^conditions,
        group_by: attempt.source_id,
        select: {attempt.source_id, count(attempt.id)}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp window(slug) do
    case policy(slug) do
      {:ok, policy} -> policy.request_budget_window_seconds
      {:error, _} -> 0
    end
  end

  defp budget(slug, used) do
    case policy(slug) do
      {:ok, policy} ->
        %{
          used: used,
          limit: policy.request_budget_limit,
          window_seconds: policy.request_budget_window_seconds,
          retention_seconds: policy.retention_seconds,
          positive_refresh_seconds: policy.positive_refresh_seconds
        }

      {:error, _} ->
        %{
          used: used,
          limit: nil,
          window_seconds: nil,
          retention_seconds: nil,
          positive_refresh_seconds: nil
        }
    end
  end

  defp retention_due_by_slug(limit) do
    limit
    |> Discovery.retention_due()
    |> Enum.frequencies_by(& &1.slug)
  end

  defp backoff(nil, _now), do: nil

  defp backoff(%{retry_after: nil}, _now), do: nil

  defp backoff(%{retry_after: retry_after, retry_reason: reason}, now) do
    if DateTime.compare(retry_after, now) == :gt,
      do: %{seconds: DateTime.diff(retry_after, now), reason: reason, until: retry_after},
      else: nil
  end
end
