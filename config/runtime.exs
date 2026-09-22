import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/devils_dictionary start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :devils_dictionary, DevilsDictionaryWeb.Endpoint, server: true
end

config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4007"))]

# The existing CineGraph server-to-server Bearer key never reaches LiveView
# assigns or browser code. A missing key disables the provider cleanly; it does
# not stop definitions or the rest of the application from starting.
# Load provider settings from a local .env only in development.
# Exported environment variables take precedence. Values are literal: no shell
# expansion or evaluation, and secrets never appear in parsing errors.
# The per-provider policy variables are derived from the same registry the
# override loop below reads, so a provider added to the registry cannot have its
# .env overrides silently discarded by an allowlist nobody remembered to edit.
# A slug's environment-variable prefix. Hyphens become underscores because a
# shell cannot export `OPEN-LIBRARY_DISCOVERY_POSITIVE_REFRESH_SECONDS` —
# `bash` and `zsh` both refuse a name with a hyphen in it — so the
# hyphenated form this used to build was an override no deployment could set.
# `bing-news` reads `BING_NEWS_…` (#135), and `open-library` `OPEN_LIBRARY_…`.
env_prefix = fn slug -> slug |> String.upcase() |> String.replace("-", "_") end

# The policy keys an operator may override, as `{key, environment suffix}`.
# One list, read three times below — the allowlist, the global defaults and the
# per-source overrides — so a key added to `Discovery.Policy` is one line here
# and cannot end up settable in one place and silently ignored in another.
# #144 Phase 2 added retention and the failure backoff, which is what made one
# list worth having.
discovery_policy_env = [
  {:positive_refresh_seconds, "DISCOVERY_POSITIVE_REFRESH_SECONDS"},
  {:empty_refresh_seconds, "DISCOVERY_EMPTY_REFRESH_SECONDS"},
  {:retention_seconds, "DISCOVERY_RETENTION_SECONDS"},
  {:failure_backoff_seconds, "DISCOVERY_FAILURE_BACKOFF_SECONDS"}
]

discovery_policy_env_suffixes = Enum.map(discovery_policy_env, &elem(&1, 1))

discovery_provider_policy_env =
  :devils_dictionary
  |> Application.get_env(:discovery_providers, [])
  |> Enum.flat_map(fn provider ->
    prefix = env_prefix.(provider.slug())

    Enum.map(discovery_policy_env_suffixes, &"#{prefix}_#{&1}")
  end)

# Credentials stay an explicit list: each one is a deliberate decision about a
# secret, and no naming rule should be able to widen it.
allowed_provider_env =
  [
    "CINEGRAPH_API_KEY",
    "CINEGRAPH_GRAPHQL_URL",
    "GIPHY_API_KEY",
    # Not a secret, but `.env` is where the owner's switches live in dev and
    # the reader only admits names on this list.
    "BING_NEWS_ENABLED",
    "ARTSY_CLIENT_ID",
    "ARTSY_CLIENT_SECRET",
    "UNSPLASH_ACCESS_KEY",
    "PEXELS_API_KEY",
    "GUARDIAN_API_KEY",
    "SPOTIFY_CLIENT_ID",
    "SPOTIFY_CLIENT_SECRET",
    # Not a secret, like `BING_NEWS_ENABLED`: the owner's switch for a shelf
    # whose terms question was decided rather than settled (#143).
    "SPOTIFY_ENABLED"
  ] ++ discovery_policy_env_suffixes ++ discovery_provider_policy_env

local_provider_env =
  if config_env() == :dev do
    case File.read(Path.expand("../.env", __DIR__)) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, values ->
          case String.split(String.trim(line), "=", parts: 2) do
            [name, value] when name != "" ->
              if name in allowed_provider_env do
                value = String.trim(value)

                value =
                  if String.length(value) >= 2 and
                       ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
                          (String.starts_with?(value, "'") and String.ends_with?(value, "'"))) do
                    String.slice(value, 1, String.length(value) - 2)
                  else
                    value
                  end

                Map.put(values, name, value)
              else
                values
              end

            _ ->
              values
          end
        end)

      {:error, :enoent} ->
        %{}

      {:error, _} ->
        raise "Could not read the development .env file"
    end
  else
    %{}
  end

if cinegraph_api_key =
     System.get_env("CINEGRAPH_API_KEY") || local_provider_env["CINEGRAPH_API_KEY"] do
  config :devils_dictionary, :cinegraph,
    api_key: cinegraph_api_key,
    endpoint:
      System.get_env("CINEGRAPH_GRAPHQL_URL") ||
        local_provider_env["CINEGRAPH_GRAPHQL_URL"] || "https://cinegraph.org/api/graphql"
end

# Dedicated public Web API key; only eligible GIF shelves receive it.
if giphy_api_key = System.get_env("GIPHY_API_KEY") || local_provider_env["GIPHY_API_KEY"] do
  config :devils_dictionary, :giphy, api_key: giphy_api_key
end

# Bing News (#135) is **on** by the owner's decision, made knowing the feed's
# `<copyright>` (`docs/integrations/bing-news.md`). This is the switch that
# turns the News shelf's first provider off again without a deploy; it reads
# the shell environment and the local `.env`, like the provider keys do.
if (System.get_env("BING_NEWS_ENABLED") || local_provider_env["BING_NEWS_ENABLED"]) in ~w(false 0 no off) do
  config :devils_dictionary, :bing_news, enabled: false
end

# Urban Dictionary's kill switch (#136), and the only one of the two that needs
# a deploy — `active: false` on the source row is the other and needs none.
# Default **true**: the variable has to say `false` to turn the card off, so a
# host that has never heard of it behaves the way config.exs says. There is no
# key: the endpoint is keyless, the request is the reader's browser's, and
# nothing secret is ever put in the assign.
if System.get_env("URBAN_DICTIONARY_ENABLED") in ~w(false 0 no off) do
  config :devils_dictionary, :urban_dictionary, enabled: false
end

# Artsy credentials remain server-only. They are read from the ignored local
# development file or exported environment and are never placed in LiveView
# assigns, URLs, logs, manifests, or source records.
artsy_client_id = System.get_env("ARTSY_CLIENT_ID") || local_provider_env["ARTSY_CLIENT_ID"]

artsy_client_secret =
  System.get_env("ARTSY_CLIENT_SECRET") || local_provider_env["ARTSY_CLIENT_SECRET"]

if artsy_client_id && artsy_client_secret do
  config :devils_dictionary, :artsy,
    client_id: artsy_client_id,
    client_secret: artsy_client_secret
end

# Unsplash and Pexels are server-only keys (#116 Phase 3). Without one the
# provider's `enabled?/0` is false and it never runs, which is the behaviour a
# deployment without the key should have: no keyless calls, no half-configured
# source in the registry. `UNSPLASH_ACCESS_KEY` is the name the code reads and
# the name the environment sets — the sister project's `.env.example` and its
# code disagreed on this, and that was worth not repeating.
if unsplash_access_key =
     System.get_env("UNSPLASH_ACCESS_KEY") || local_provider_env["UNSPLASH_ACCESS_KEY"] do
  config :devils_dictionary, :unsplash, access_key: unsplash_access_key
end

if pexels_api_key = System.get_env("PEXELS_API_KEY") || local_provider_env["PEXELS_API_KEY"] do
  config :devils_dictionary, :pexels, api_key: pexels_api_key
end

# The Guardian (#142) is the same server-only shape, and the key is the whole
# switch: without it `Guardian.enabled?/0` is false, the provider registers,
# and the News shelf is Bing alone. The Open Platform terms make the key
# personal to one registered website (clause 1(c)) and forbid sharing it
# (clause 3(b)(iii)), so it is read here and passed to `request_options/1`
# alone — never into an assign, a reader-visible URL, a log line, a ledger
# row or a fixture.
if guardian_api_key =
     System.get_env("GUARDIAN_API_KEY") || local_provider_env["GUARDIAN_API_KEY"] do
  config :devils_dictionary, :guardian, api_key: guardian_api_key
end

# Spotify (#143) needs both halves of one credential: the id and the secret
# are exchanged for a bearer token at `token_endpoint`, so either one alone is
# no more use than neither. Without both, `enabled?/0` is false, the provider
# stays registered and the Music shelf never renders — which is what a host
# without the credentials should do.
#
# Server-only, both of them. Neither reaches a LiveView assign, a URL, a log
# line or a `discovery_request_attempts` row; the token process holds the
# minted token and never the secret that minted it.
spotify_client_id = System.get_env("SPOTIFY_CLIENT_ID") || local_provider_env["SPOTIFY_CLIENT_ID"]

spotify_client_secret =
  System.get_env("SPOTIFY_CLIENT_SECRET") || local_provider_env["SPOTIFY_CLIENT_SECRET"]

if spotify_client_id && spotify_client_secret do
  config :devils_dictionary, :spotify,
    client_id: spotify_client_id,
    client_secret: spotify_client_secret
end

# The kill switch the owner's decision comes with: the Music shelf is on by
# default and `SPOTIFY_ENABLED=false` turns it off without a deploy, as
# `BING_NEWS_ENABLED` does for the News shelf.
if (System.get_env("SPOTIFY_ENABLED") || local_provider_env["SPOTIFY_ENABLED"]) in ~w(false 0 no off) do
  config :devils_dictionary, :spotify, enabled: false
end

parse_policy_integer = fn name ->
  case System.get_env(name) || local_provider_env[name] do
    value when value in [nil, ""] ->
      nil

    value ->
      case Integer.parse(value) do
        {integer, ""} when integer >= 0 -> integer
        _ -> raise "#{name} must be a non-negative integer number of seconds"
      end
  end
end

discovery_config = Application.fetch_env!(:devils_dictionary, :discovery)

discovery_config =
  discovery_policy_env
  |> Enum.map(fn {key, suffix} -> {key, parse_policy_integer.(suffix)} end)
  |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  |> then(&Keyword.merge(discovery_config, &1))

source_policies = Keyword.fetch!(discovery_config, :source_policies)

source_policies =
  :devils_dictionary
  |> Application.get_env(:discovery_providers, [])
  |> Enum.map(& &1.slug())
  |> Enum.reduce(source_policies, fn slug, policies ->
    prefix = env_prefix.(slug)

    overrides =
      discovery_policy_env
      |> Enum.map(fn {key, suffix} -> {key, parse_policy_integer.("#{prefix}_#{suffix}")} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if overrides == [],
      do: policies,
      else: Map.update(policies, slug, overrides, &Keyword.merge(&1, overrides))
  end)

config :devils_dictionary,
       :discovery,
       Keyword.put(discovery_config, :source_policies, source_policies)

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/devils_dictionary_web/router\.ex$",
        ~r"lib/devils_dictionary_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :devils_dictionary, DevilsDictionary.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :devils_dictionary, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :devils_dictionary, DevilsDictionaryWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
