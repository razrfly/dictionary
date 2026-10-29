defmodule DevilsDictionaryWeb.LocalCurator do
  @moduledoc """
  Password-free curation on the owner's development machine or SSH forward.
  Only exact curation paths on localhost/loopback without proxy headers may
  use the global configuration activator's existing reviewer identity. No role,
  account or login token is created. Public ngrok can never acquire this identity.
  Other operator surfaces and existing account sessions are unchanged.
  """
  import Plug.Conn
  import Ecto.Query
  alias DevilsDictionary.Accounts.{Scope, User}
  alias DevilsDictionary.Curation.{Configuration, ConfigurationActivation}
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.Repo
  alias DevilsDictionaryWeb.ProxyGuard

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      if get_session(conn, :local_curator_user_id),
        do: delete_session(conn, :local_curator_user_id),
        else: conn

    if enabled?() and curation?(conn.path_info) and
         conn.host in ["localhost", "127.0.0.1", "::1"] and
         not ProxyGuard.proxied?(conn) and is_nil(conn.assigns.current_scope) do
      case owner() do
        %User{} = user ->
          conn
          |> assign(:current_scope, Scope.for_user(user))
          |> put_session(:local_curator_user_id, user.id)

        nil ->
          conn
      end
    else
      conn
    end
  end

  @doc "Restore the same owner only on a locally connected curation socket."
  def mount(socket, session) do
    local? = not Phoenix.LiveView.connected?(socket) or not ProxyGuard.proxied_socket?(socket)
    owner_id = session["local_curator_user_id"]

    if enabled?() and local? and is_integer(owner_id) and
         socket.view in [
           DevilsDictionaryWeb.CurationLive,
           DevilsDictionaryWeb.CurationLive.Editor,
           DevilsDictionaryWeb.CurationLive.Attempt
         ] do
      case owner() do
        %User{id: id} = user when id == owner_id ->
          Phoenix.Component.assign(socket, :current_scope, Scope.for_user(user))

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp owner do
    Repo.one(
      from c in Configuration,
        join: activation in ConfigurationActivation,
        on:
          activation.configuration_id == c.id and
            activation.configuration_version_id == c.current_version_id and
            activation.id ==
              fragment(
                "(SELECT max(id) FROM curation_configuration_activations WHERE configuration_id = ? AND action = 'activate')",
                c.id
              ),
        join: a in Actor,
        on: a.id == activation.actor_id,
        join: u in User,
        on: u.id == a.user_id,
        where: c.role == :global_default and c.state == :enabled and u.reviewer == true,
        select: u
    )
  end

  defp enabled?, do: Application.get_env(:devils_dictionary, :dev_routes, false)
  defp curation?(["ops", "curation"]), do: true
  defp curation?(["ops", "curation", "on", _]), do: true
  defp curation?(["ops", "curation", "attempts", _]), do: true
  defp curation?(_), do: false
end
