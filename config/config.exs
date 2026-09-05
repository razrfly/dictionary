# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :devils_dictionary,
  ecto_repos: [DevilsDictionary.Repo],
  generators: [timestamp_type: :utc_datetime]

# Migration conventions for the whole schema (#69 §4): bigint identity ids and
# microsecond UTC timestamps, set once here instead of on every table.
config :devils_dictionary, DevilsDictionary.Repo,
  migration_primary_key: [name: :id, type: :identity],
  migration_foreign_key: [type: :bigint],
  migration_timestamps: [type: :utc_datetime_usec]

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

# Oban (#69 §5). `absorb: 1` because a dump absorb is a single long stream.
# `enrich` is **1**, not the spec's 3: `EnrichWorker` paces with a per-process
# `Process.sleep(rate_limit_ms)`, so three concurrent jobs would triple the rate
# against a single API — 15 req/s where #69 §2 promises 5. Raise it back to 3
# once a limiter shared across the queue exists (or one queue per source).
config :devils_dictionary, Oban,
  repo: DevilsDictionary.Repo,
  queues: [absorb: 1, enrich: 1, link: 2, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
