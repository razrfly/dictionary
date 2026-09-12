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
  pool_size: System.schedulers_online() * 2

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

config :devils_dictionary, :discovery_req_options,
  plug: {Req.Test, DevilsDictionary.Discovery.Providers.CineGraph}

config :devils_dictionary, :discovery,
  result_limit: 3,
  max_pages_per_context: 5,
  queue_cap: 10,
  request_budget_per_minute: 30,
  refresh_seconds: 3_600,
  refresh_cooldown_seconds: 60,
  hard_expiry_seconds: 7_200,
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
