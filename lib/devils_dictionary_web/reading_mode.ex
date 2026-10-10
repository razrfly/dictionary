defmodule DevilsDictionaryWeb.ReadingMode do
  @moduledoc """
  Which pages a reader may see (#219 B1): `:public` or `:internal`, decided
  per request, and again at each navigation of a mounted socket, and used
  for every link and every address the page serves (`Routing.Resolver`,
  `Routing.Links`, `Routing.Subjects`).

  Internal reading comes only from trusted places:

    * configuration — `config :devils_dictionary, :internal_reading, true`,
      set in `config/dev.exs` and `config/test.exs` and refused in the
      production configuration by `ReadingModeConfigTest`. On the published
      host (#237 D2, `Routing.PublicRouting`) it applies only to a request
      from the machine itself: one that came through the tunnel
      (`DevilsDictionaryWeb.ProxyGuard`) reads publicly (#250);
    * an authenticated internal contributor or reviewer
      (`Claims.Contributions.internal_contributor?/1`, read from the
      database, not from the session's copy of the account), from anywhere.

  Nothing in a request — no parameter, header or path — can turn it on: a
  request through the tunnel carries the proxy's headers whatever the
  visitor sends. Internal reading shows draft pages, marked as drafts; it
  publishes and approves nothing. A development server that reads drafts
  and is not the published host shows them to whoever reaches it, so
  `ProxyGuard` refuses it through a tunnel.
  """

  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Routing.PublicRouting
  alias DevilsDictionaryWeb.ProxyGuard

  @doc """
  The reading mode for a request: its scope (nil for an anonymous reader),
  and whether it came through a proxy or from another machine
  (`ProxyGuard.proxied?/1` for a request, `ProxyGuard.proxied_connect?/1`
  for a socket).
  """
  def mode(scope, proxied?) do
    if configured_for?(proxied?) or Contributions.internal_contributor?(scope),
      do: :internal,
      else: :public
  end

  @doc """
  Whether this installation's configuration turns internal reading on for
  everyone: never on the published host, which reads internally only for
  the machine itself (`mode/2`).
  """
  def configured? do
    internal_reading?() and not PublicRouting.published_host?()
  end

  defp configured_for?(proxied?),
    do: internal_reading?() and not (proxied? and PublicRouting.published_host?())

  defp internal_reading?,
    do: Application.get_env(:devils_dictionary, :internal_reading, false) == true

  @doc """
  The `on_mount` for reader LiveViews: the current scope, as
  `UserAuth`'s `:mount_current_scope` gives it, and `:reading_mode`, read
  again before each `handle_params` so a revoked role stops reading
  internally at the next navigation, not at the next page load.

  Whether the connection came through a proxy is read once, at mount: the
  request's own answer (`ProxyGuard` assigns it) for the first render, the
  socket's connect info once connected.
  """
  def on_mount(:default, params, session, socket) do
    {:cont, socket} =
      DevilsDictionaryWeb.UserAuth.on_mount(:mount_current_scope, params, session, socket)

    socket =
      Phoenix.Component.assign_new(socket, :proxied?, fn -> ProxyGuard.proxied_socket?(socket) end)

    socket =
      socket
      |> assign_mode()
      |> Phoenix.LiveView.attach_hook(:reading_mode, :handle_params, fn _params, _uri, socket ->
        {:cont, assign_mode(socket)}
      end)

    {:cont, socket}
  end

  defp assign_mode(socket) do
    mode = mode(socket.assigns.current_scope, socket.assigns.proxied?)
    Phoenix.Component.assign(socket, :reading_mode, mode)
  end
end
