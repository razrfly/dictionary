defmodule DevilsDictionary.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DevilsDictionaryWeb.Telemetry,
      DevilsDictionary.Repo,
      {DNSCluster, query: Application.get_env(:devils_dictionary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DevilsDictionary.PubSub},
      {Oban, Application.fetch_env!(:devils_dictionary, Oban)},
      # Health figures that are seconds of queries (the scorecard) are cached
      # here so a page can show them without recomputing them on every mount.
      {Cachex, name: :health},
      # The Spotify Client Credentials token, cached for its hour (#143). It
      # holds a token and nothing else — no credential — and the refresh is
      # made by whichever run found the cache cold, through the shared
      # transport, so it is a ledger row and a budgeted request like any
      # other.
      DevilsDictionary.Discovery.Providers.Spotify.Token,
      # Start to serve requests, typically the last entry
      DevilsDictionaryWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DevilsDictionary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DevilsDictionaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
