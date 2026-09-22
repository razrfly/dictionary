import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :devils_dictionary, DevilsDictionary.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "devils_dictionary_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # DBConnection cancels a statement that runs past `timeout`, and Postgres
  # reports the cancel as `57014 query_canceled: canceling statement due to
  # user request`. The default is 15 s, which a seed or a truncate exceeds
  # when several suites share the machine (load average 29 was measured while
  # the suite failed this way). Nothing in the suite is faster for being
  # cancelled; it is simply slow that day.
  timeout: 60_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NDr0xrjf8WqeDKA+uRZeAREgdwX1OjLGz/NOpp6BsBrsfmXmxVEWtJ342GuHsNXC",
  server: false

# Jobs are asserted on, never run, and no queue or plugin starts. The mix tasks
# are synchronous by design, so nothing in the suite waits on Oban.
config :devils_dictionary, Oban, testing: :manual

config :devils_dictionary, :cinegraph,
  api_key: "cinegraph-test-key",
  endpoint: "https://cinegraph.test/api/graphql",
  enabled: true

config :devils_dictionary, :giphy,
  endpoint: "https://api.giphy.test/v1/gifs/search",
  rating: "g",
  enabled: false

# No pacing in the suite: the interval is a live-rate concern and 25 hydrations
# would otherwise cost 25 seconds of wall clock per test.
config :devils_dictionary, :met, enabled: true, request_interval_ms: 0

config :devils_dictionary, :discovery_req_options,
  plug: {Req.Test, DevilsDictionary.Discovery.Providers.CineGraph}

config :devils_dictionary, :discovery,
  result_limit: 3,
  max_pages_per_context: 5,
  queue_cap: 10,
  positive_refresh_seconds: 3_600,
  empty_refresh_seconds: 1_800,
  request_budget_limit: 30,
  request_budget_window_seconds: 60,
  # This map *replaces* `config.exs`'s rather than merging with it, so a
  # source whose policy the suite asserts has to be named here too.
  source_policies: %{
    "giphy" => [request_budget_limit: 100, request_budget_window_seconds: 3_600],
    "met" => [request_budget_limit: 1_000, request_budget_window_seconds: 3_600],
    # The Guardian's shipped policy (#142), repeated because the retention
    # decision is proved by a test and a policy the suite cannot see is a
    # decision the suite cannot check.
    "guardian" => [
      request_budget_limit: 400,
      request_budget_window_seconds: 86_400,
      positive_refresh_seconds: 86_400,
      retention_seconds: 82_800
    ],
    # Spotify's (#143), repeated for the same reason: the window is a term of
    # the licence and the suite asserts it.
    "spotify" => [
      request_budget_limit: 500,
      request_budget_window_seconds: 3_600,
      positive_refresh_seconds: 24 * 60 * 60,
      retention_seconds: 7 * 24 * 60 * 60
    ]
  },
  refresh_cooldown_seconds: 60,
  failure_backoff_seconds: 60,
  retention_seconds: 7_200,
  retained_attempts_per_position: 3,
  timeout_ms: 1_000,
  max_retries: 2,
  retry_delay_ms: 0,
  task_wait_ms: 250,
  report_sample: 3

# Every HTTP call goes through a `Req.Test` stub in the suite. An unstubbed call
# raises rather than reaching the network, which is what keeps O3 honest.
config :devils_dictionary, :req_options, plug: {Req.Test, DevilsDictionary.Absorb.Clients}

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The dev-only routes are routed in test too, so /kit and the dashboard can be
# tested. Production is gated at compile time in the router and has neither.
config :devils_dictionary, dev_routes: true

# Fake-data mode (#71 §2.8, U3). `?demo=1` does nothing at all unless this is
# set, and it is set here and in `test.exs` only: `prod.exs` and `runtime.exs`
# never mention the key, which is the same gate `dev_routes` uses for `/kit`.
# `demo_inert_test.exs` reads `prod.exs` back and fails if it ever grows one.
config :devils_dictionary, demo_mode: true

# The health page's scorecard cache would leak one test's rows into the next.
config :devils_dictionary, cache_scorecard: false

# Mail goes nowhere in tests; assert on it with Swoosh.TestAssertions.
config :devils_dictionary, DevilsDictionary.Mailer, adapter: Swoosh.Adapters.Test

# Scaffolded by `mix dd.provider.new poetrydb`. Every request in the
# suite goes through the `Req.Test` stub named after the provider module.
# No pacing in the suite, for the same reason the Met declares none above: the
# intervals are a live-rate courtesy to a free public service, and a suite that
# paid them would spend a second per stubbed request and five more per stubbed
# refusal.
config :devils_dictionary, :poetrydb,
  endpoint: "https://poetrydb.test/api",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Every Commons request in the suite goes through the `Req.Test` stub named
# after the provider module. No pacing, for the same reason as the Met and
# PoetryDB above: the intervals are a live-rate courtesy, not a suite's cost.
config :devils_dictionary, :commons,
  endpoint: "https://commons.test/w/api.php",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Scaffolded by `mix dd.provider.new open-library`. Every request in the
# suite goes through the `Req.Test` stub named after the provider module.
config :devils_dictionary, :open_library,
  endpoint: "https://open-library.test",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Scaffolded by `mix dd.provider.new openverse`. Every request in the
# suite goes through the `Req.Test` stub named after the provider module.
config :devils_dictionary, :openverse,
  endpoint: "https://openverse.test/v1/images/",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Scaffolded by `mix dd.provider.new unsplash`. Every request in the
# suite goes through the `Req.Test` stub named after the provider module.
# The key is a literal because `enabled?/0` requires one: a keyed provider
# with no key is a disabled provider, and the suite needs it enabled.
config :devils_dictionary, :unsplash,
  endpoint: "https://api.unsplash.test/search/photos",
  access_key: "unsplash-test-key",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Scaffolded by `mix dd.provider.new pexels`. Every request in the
# suite goes through the `Req.Test` stub named after the provider module.
config :devils_dictionary, :pexels,
  endpoint: "https://api.pexels.test/v1/search",
  api_key: "pexels-test-key",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Every request in the suite goes through the `Req.Test` stub named after the
# provider module. `now` is the clock the freshness gate reads: the conformance
# fixture is a real capture whose items ran between 15 and 20 September 2026,
# and a gate read against the wall clock would pass that week and fail the
# next. Pinned to the day of the capture, so the 30-day window is a property of
# the fixture and not of the date the suite happens to run.
config :devils_dictionary, :bing_news,
  endpoint: "https://bing-news.test/news/search",
  enabled: true,
  now: ~U[2026-09-21 12:00:00Z],
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# The Guardian (#142). The key is a literal here and not a secret: the suite
# never reaches the network, every request goes through the `Req.Test` stub
# named after the provider module, and `enabled?/0` needs *some* key to be
# true at all. The clock is pinned to the day the fixture was captured —
# `Guardian.now/0` reads it — because the fixture holds real September 2026
# publication dates and a freshness gate read against the wall clock would
# pass this week and fail next.
config :devils_dictionary, :guardian,
  endpoint: "https://guardian.test/search",
  enabled: true,
  api_key: "test-key-not-a-secret",
  max_age_days: 30,
  now: ~U[2026-09-21 12:00:00Z],
  request_interval_ms: 0,
  min_retry_interval_ms: 0

# Both Spotify endpoints on one `.test` host, so the fixture's stub answers
# the token request and the search from the same plug and the pair is captured
# together (#143). The credentials are the literals the suite needs
# `enabled?/0` to be true for; nothing is minted and nothing leaves the node.
config :devils_dictionary, :spotify,
  endpoint: "https://spotify.test/v1/search",
  token_endpoint: "https://spotify.test/api/token",
  client_id: "test-client-id",
  client_secret: "test-client-secret",
  market: "US",
  enabled: true,
  request_interval_ms: 0,
  min_retry_interval_ms: 0
