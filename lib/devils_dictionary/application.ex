defmodule DevilsDictionary.Application do
  # See https://hexdocs.pm/elixir/Application.html
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
      # Oban for background job processing
      {Oban, Application.fetch_env!(:devils_dictionary, Oban)},
      # Cachex for in-memory caching of API responses
      {Cachex, name: :api_cache, limit: 1000},
      # Start to serve requests, typically the last entry
      DevilsDictionaryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
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
