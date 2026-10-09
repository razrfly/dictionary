defmodule DevilsDictionaryWeb.LiveSocket do
  @moduledoc """
  The LiveView socket, `/live`, with the proxy rule of
  `DevilsDictionaryWeb.ProxyGuard` applied where a plug cannot reach
  (#237 D2, C7).

  `use Phoenix.Endpoint` dispatches its sockets before any plug the
  endpoint names, so `ProxyGuard` never sees a socket's connection. A server
  that reads drafts for everyone and is not the published host refuses a
  socket that came through a proxy here, as the plug refuses its requests
  with 503: otherwise a client with a session token (the development
  secret is in the repository) could mount a reader LiveView over the
  socket and read drafts the page itself would not show. On the published
  host every socket connects, and the operator LiveViews refuse a proxied
  one when they mount (`ProxyGuard.on_mount/4`).
  """

  use Phoenix.LiveView.Socket

  alias DevilsDictionaryWeb.ProxyGuard

  def connect(_params, socket, connect_info) do
    if ProxyGuard.refuse_socket?(connect_info), do: :error, else: {:ok, socket}
  end
end
