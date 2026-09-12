defmodule DevilsDictionary.Artsy.Availability do
  @moduledoc """
  One operational gate for every Artsy entry point.

  Configuration can disable the integration before the database is available;
  once the source catalog exists, a withdrawn source also disables it. Callers
  that write provider data must use `with_active_source/1`, which locks the
  source row so withdrawal and publication cannot cross in flight.
  """

  import Ecto.Query

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @slug "artsy"

  @doc "Whether credentials, configuration, source lifecycle and coordinator permit access."
  def enabled? do
    configured?() and source_active?() and coordinator_enabled?()
  rescue
    DBConnection.OwnershipError -> configured?() and coordinator_enabled?()
  end

  @doc "Whether the server configuration contains both credentials without exposing them."
  def configured? do
    config = config()

    config[:enabled] != false and present?(config[:client_id]) and
      present?(config[:client_secret])
  end

  @doc "Returns a stable, scrubbed reason when the provider cannot be used."
  def status do
    config = config()

    status_with_credentials(
      config[:client_id],
      config[:client_secret],
      Keyword.get(config, :coordinator, DevilsDictionary.Artsy.RequestCoordinator)
    )
  end

  @doc "The lifecycle check for a client carrying explicit server-side credentials."
  def status_with_credentials(client_id, client_secret) do
    status_with_credentials(client_id, client_secret, DevilsDictionary.Artsy.RequestCoordinator)
  end

  def status_with_credentials(client_id, client_secret, coordinator) do
    cond do
      config()[:enabled] == false -> {:error, :configured_off}
      not (present?(client_id) and present?(client_secret)) -> {:error, :credentials_missing}
      not source_active?() -> {:error, :source_withdrawn}
      not coordinator_enabled?(coordinator) -> {:error, :source_withdrawn}
      true -> :ok
    end
  rescue
    DBConnection.OwnershipError ->
      if(present?(client_id) and present?(client_secret),
        do: :ok,
        else: {:error, :credentials_missing}
      )
  end

  @doc "Runs a provider-data write while holding the same source lock as withdrawal."
  def with_active_source(fun) when is_function(fun, 1) do
    Repo.transaction(fn ->
      source =
        Repo.one(from source in Source, where: source.slug == @slug, lock: "FOR UPDATE")

      if source && source.active && config()[:enabled] != false && coordinator_enabled?() do
        fun.(source)
      else
        Repo.rollback(:provider_disabled)
      end
    end)
  end

  defp source_active? do
    case Repo.get_by(Source, slug: @slug) do
      nil -> true
      source -> source.active
    end
  end

  defp coordinator_enabled? do
    coordinator =
      Keyword.get(config(), :coordinator, DevilsDictionary.Artsy.RequestCoordinator)

    coordinator_enabled?(coordinator)
  end

  defp coordinator_enabled?(nil), do: true

  defp coordinator_enabled?(coordinator) do
    case Process.whereis(coordinator) do
      nil -> true
      _pid -> DevilsDictionary.Artsy.RequestCoordinator.enabled?(coordinator)
    end
  end

  defp config, do: Application.get_env(:devils_dictionary, :artsy, [])
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
