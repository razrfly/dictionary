defmodule DevilsDictionaryWeb.LiveReloadSocket do
  @moduledoc """
  The development live-reload socket, `/phoenix/live_reload/socket`, for the
  owner's own machine only (#237 D2, C7).

  `Phoenix.LiveReloader.Socket` accepts every connection, and the endpoint
  dispatches it before any plug, so `DevilsDictionaryWeb.ProxyGuard` never
  sees it: through the tunnel a visitor could join it and receive the
  server's log lines and file paths. This socket is the same channel behind
  a `connect/3` that refuses a connection that came through a proxy or from
  another machine (`ProxyGuard.proxied_connect?/1`), on every server: live
  reload is never anyone's but the owner's. The published host does not
  inject the reloader into its pages either (`config/runtime.exs`).
  """

  use Phoenix.Socket, log: false

  alias DevilsDictionaryWeb.ProxyGuard

  channel "phoenix:live_reload", Phoenix.LiveReloader.Channel

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    if ProxyGuard.proxied_connect?(connect_info), do: :error, else: {:ok, socket}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end
