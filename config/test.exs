import Config

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

# The health page's scorecard cache would leak one test's rows into the next.
config :devils_dictionary, cache_scorecard: false
