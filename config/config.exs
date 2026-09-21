# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :devils_dictionary, :scopes,
  user: [
    default: true,
    module: DevilsDictionary.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: DevilsDictionary.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

# Swoosh's local adapter keeps mail in memory; `/dev/mailbox` renders it.
# Production is deliberately not configured -- see DevilsDictionary.Mailer.
config :devils_dictionary, DevilsDictionary.Mailer, adapter: Swoosh.Adapters.Local

# No API client: the Local and Test adapters never make an HTTP request, and
# leaving this unset makes Swoosh demand hackney at boot. If a remote adapter is
# ever configured, point this at Req rather than adding a second HTTP client --
# AGENTS.md is explicit that Req is the one.
config :swoosh, :api_client, false

config :devils_dictionary,
  ecto_repos: [DevilsDictionary.Repo],
  generators: [timestamp_type: :utc_datetime]

# Migration conventions for the whole schema (#69 §4): bigint identity ids and
# microsecond UTC timestamps, set once here instead of on every table.
config :devils_dictionary, DevilsDictionary.Repo,
  migration_primary_key: [name: :id, type: :identity],
  migration_foreign_key: [type: :bigint],
  migration_timestamps: [type: :utc_datetime_usec],
  migration_lock: :pg_advisory_lock

# Configure the endpoint
config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DevilsDictionaryWeb.ErrorHTML, json: DevilsDictionaryWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DevilsDictionary.PubSub,
  live_view: [signing_salt: "df7nUVYI"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  devils_dictionary: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  devils_dictionary: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The line every Wikimedia endpoint sees. One string, shared by every client and
# by `mix dd.scope.categories`, so a polite absorb is never one module's habit.
config :devils_dictionary,
       :user_agent,
       "wordhoard/0.1 (https://github.com/razrfly/dictionary; holden.thomas@gmail.com)"

# The registry. Adding a provider is this list plus its module: the source
# catalog, `mix dd.discovery`, the freshness overrides in runtime.exs and the
# page all read it, and none of them names a provider itself.
config :devils_dictionary, :discovery_providers, [
  DevilsDictionary.Discovery.Providers.Artsy,
  DevilsDictionary.Discovery.Providers.BingNews,
  DevilsDictionary.Discovery.Providers.CineGraph,
  DevilsDictionary.Discovery.Providers.Commons,
  DevilsDictionary.Discovery.Providers.Giphy,
  DevilsDictionary.Discovery.Providers.Guardian,
  DevilsDictionary.Discovery.Providers.Met,
  DevilsDictionary.Discovery.Providers.OpenLibrary,
  DevilsDictionary.Discovery.Providers.Openverse,
  DevilsDictionary.Discovery.Providers.Pexels,
  DevilsDictionary.Discovery.Providers.Poetrydb,
  DevilsDictionary.Discovery.Providers.Unsplash
]

# Culture discovery is visit-driven and bounded. Provider modules own their
# capability differences; these are operating limits for the shared lifecycle.
config :devils_dictionary, :discovery,
  result_limit: 12,
  max_pages_per_context: 5,
  queue_cap: 100,
  provider_concurrency: 2,
  capacity_retry_seconds: 5,
  execution_lease_seconds: 30 * 60,
  cleanup_batch_size: 500,
  positive_refresh_seconds: 30 * 24 * 60 * 60,
  empty_refresh_seconds: 24 * 60 * 60,
  request_budget_limit: 30,
  request_budget_window_seconds: 60,
  source_policies: %{
    "giphy" => [request_budget_limit: 100, request_budget_window_seconds: 60 * 60],
    # One Met page is a search plus up to `Met.scan_window/0` hydrations, and the
    # probe put the sustainable rate near 1 req/s rather than the documented 80.
    "met" => [request_budget_limit: 1_000, request_budget_window_seconds: 3_600],
    # A News shelf cached for the shipped 30 days would be frozen at whatever
    # was in the news the day a reader first opened the page. A day is what
    # "current" costs (#135). The empty refresh is already 24 h and stays
    # there. `BING_NEWS_DISCOVERY_POSITIVE_REFRESH_SECONDS` overrides this at
    # runtime, as it does every provider's.
    "bing-news" => [positive_refresh_seconds: 24 * 60 * 60],
    # The Guardian (#142). Clause 5 of the Open Platform terms: OP Content
    # must be re-requested or deleted at least every 24 hours, and may not be
    # kept longer than that "whether or not published on Your Website". So the
    # refresh is a day (the *replace* half, for a page somebody opens) and
    # `retention_seconds` is the *delete* half, for one nobody does — the only
    # source that names one, and the reason `Policy` admits the key at all.
    # It is an hour under the day, not the day: the sweep runs every fifteen
    # minutes, so a window of exactly 86_400 lets a record live up to 24h15m,
    # and the clause says twenty-four. The budget is 400 of the key's 500, so
    # the app's own ledger refuses before the API does and tomorrow's probe
    # still has room.
    "guardian" => [
      request_budget_limit: 400,
      request_budget_window_seconds: 86_400,
      positive_refresh_seconds: 86_400,
      retention_seconds: 82_800
    ]
  },
  refresh_cooldown_seconds: 60,
  failure_backoff_seconds: 5 * 60,
  retention_seconds: 7 * 24 * 60 * 60,
  retained_attempts_per_position: 3,
  timeout_ms: 10_000,
  max_retries: 2,
  retry_delay_ms: 250,
  task_wait_ms: 30_000,
  report_sample: 5

# The Met is keyless. `request_interval_ms` is the sustained pace the shared
# transport keeps between *every* request this provider makes — the measured
# rate at which none of 2,600 requests were refused, where 1 req/s refused 44%.
# `min_retry_interval_ms` is the separate, shorter gap after one refusal.
# Both reach the transport through `Met.capabilities/0`; this is its override.
config :devils_dictionary, :met,
  enabled: true,
  request_interval_ms: 3_000

config :devils_dictionary, :cinegraph,
  endpoint: "https://cinegraph.org/api/graphql",
  image_base_url: "https://image.tmdb.org/t/p/w342",
  enabled: true

# Direct-browser automatic discovery uses the dedicated public Web API key.
config :devils_dictionary, :giphy,
  endpoint: "https://api.giphy.com/v1/gifs/search",
  rating: "g",
  enabled: true

# Urban Dictionary (#136): an on-demand *definition* source, not a discovery
# provider. Keyless and CORS-open, so `endpoint` is the only setting the hook
# needs and `enabled` is one of the two kill switches — `runtime.exs` reads
# URBAN_DICTIONARY_ENABLED into it, and `active` on the source row is the
# other. `permission_requested_on` is the date the owner's email asking Urban
# Dictionary for API permission went; it is `"pending"` until it has, and it is
# written onto the source row's config so the posture is readable in the
# database rather than only in docs/integrations/urban-dictionary.md.
config :devils_dictionary, :urban_dictionary,
  endpoint: "https://api.urbandictionary.com/v0/define",
  enabled: true,
  permission_requested_on: "pending"

# Artsy is registry-only: its 43 pilot works are catalog rows and no request is
# ever made. The private client, its coordinator and the availability check
# were retired in #109 Phase 3a; `enabled` is read by the registry gate alone.
config :devils_dictionary, :artsy, enabled: true

# Oban (#69 §5). `absorb: 1` because a dump absorb is a single long stream.
# `enrich` is **1**, not the spec's 3: `EnrichWorker` paces with a per-process
# `Process.sleep(rate_limit_ms)`, so three concurrent jobs would triple the rate
# against a single API — 15 req/s where #69 §2 promises 5. Raise it back to 3
# once a limiter shared across the queue exists (or one queue per source).
config :devils_dictionary, Oban,
  repo: DevilsDictionary.Repo,
  queues: [absorb: 1, enrich: 1, link: 2, discovery: 2, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", DevilsDictionary.Discovery.CleanupWorker}
     ]}
  ]

# PoetryDB is keyless and public. `request_interval_ms` is an override for the
# measured default in the provider, not a second declaration of it.
config :devils_dictionary, :poetrydb,
  endpoint: "https://poetrydb.org",
  enabled: true

# Wikimedia Commons is keyless and public. The interval keys are overrides for
# the measured defaults in the provider (1 s between requests, 5 s after a lag
# refusal), not a second declaration of them; `maxlag=5` rides on every request.
config :devils_dictionary, :commons,
  endpoint: "https://commons.wikimedia.org/w/api.php",
  enabled: true

config :devils_dictionary, :open_library,
  endpoint: "https://openlibrary.org",
  enabled: true

config :devils_dictionary, :openverse,
  endpoint: "https://api.openverse.org/v1/images/",
  enabled: true

# Unsplash needs `UNSPLASH_ACCESS_KEY`, read in `runtime.exs` from the
# environment and never from a file that is committed. Without it `enabled?/0`
# is false and the provider never runs. Pacing is declared in the provider's
# `capabilities/0`; there is no override here.
config :devils_dictionary, :unsplash,
  endpoint: "https://api.unsplash.com/search/photos",
  enabled: true

# Pexels needs `PEXELS_API_KEY`, on the same terms.
config :devils_dictionary, :pexels,
  endpoint: "https://api.pexels.com/v1/search",
  enabled: true

# Bing's news RSS feed is keyless and undocumented (#135, from #134's live
# shootout). `mkt` is a request parameter and not a preference: the feed infers
# a market from the caller's address, and the probe's inferred Poland — the
# channel came back titled *BingWiadomości* and `/define/war` answered with
# Polish games-site pages about *War Thunder*. `max_age_days` is what makes
# this a News shelf rather than a search shelf; the feed will happily answer a
# word with 2023.
#
# **On, by the owner's decision (2026-09-21).** The feed's own `<copyright>`
# element restricts its results to "rendering Bing results within an RSS
# aggregator for your personal, non-commercial use" and reserves any other use
# to Microsoft's express written permission (quoted in full in
# `docs/integrations/bing-news.md`). #140 merged with `enabled: false` for that
# reason; the owner then chose to run it and accept that risk, so the default
# is `true` and `BING_NEWS_ENABLED=false` (read in `runtime.exs`) turns it off
# again without a deploy.
config :devils_dictionary, :bing_news,
  endpoint: "https://www.bing.com/news/search",
  enabled: true,
  market: "en-US",
  max_age_days: 30

# The Guardian's Content API (#142), the News shelf's second source and its
# first with published terms. Keyed: `GUARDIAN_API_KEY` is read in
# `runtime.exs` and `enabled?/0` is false without it, so a host with no key
# registers the provider and makes no call. `max_age_days` is Bing's, shared
# deliberately — one shelf, one idea of what "current" means.
config :devils_dictionary, :guardian,
  endpoint: "https://content.guardianapis.com/search",
  enabled: true,
  max_age_days: 30

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
