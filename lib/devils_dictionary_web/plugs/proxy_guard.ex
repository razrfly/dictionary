defmodule DevilsDictionaryWeb.ProxyGuard do
  @moduledoc """
  What a request that came through a proxy may reach (#237 D2, C7).

  The published host is the owner's development server, reached through a
  tunnel (`Routing.PublicRouting`). A request through the tunnel carries the
  proxy's headers (`X-Forwarded-For`, `Forwarded`, `X-Forwarded-Host` or
  `X-Forwarded-Proto`) or arrives from an address that is not the loopback;
  a request from the owner's own machine carries none and arrives on
  127.0.0.1. Two rules, decided before the router:

    * **On the published host, the operator surfaces do not exist to a
      proxied request**: `/dev/*` (the mailbox, whose login links would hand
      an anonymous visitor the reviewer's account, and the dashboard),
      `/kit`, `/ops/*` (whose imports page starts an import), and the retired
      paths that redirect to them (`/s/*`, `/health`, `/admin/*`). They
      answer 404, as anything else that is not there. The owner still
      reaches them on the machine itself.
    * **A server that reads drafts for everyone and is not the published
      host refuses every proxied request** (503), so a development server
      started without `DD_PUBLISHED_HOST` while the tunnel runs shows the
      tunnel nothing, instead of every draft. That is the failure the
      published host's configuration cannot cover by itself: it exists only
      when the launch script names it.

  A request cannot claim to be local: the proxy adds its headers whatever
  the visitor sends, and the remote address is the socket's.

  A plug cannot reach the LiveView socket, which the endpoint dispatches
  before its plugs, nor a live navigation, which never makes a request. So
  the same two rules are applied there too:

    * `DevilsDictionaryWeb.LiveSocket` refuses a proxied socket on a server
      that reads drafts and is not the published host (`refuse_socket?/1`);
    * the operator LiveViews mount under `on_mount({ProxyGuard, :operator})`
      in their own live sessions, so a reader page cannot live-navigate to
      them without a request, and a proxied socket that reaches one on the
      published host is sent to `/` before it mounts.

  At the socket only the `X-Forwarded-*` headers and the peer are visible
  (`connect_info`'s `:x_headers` and `:peer_data`); the tunnel sets
  `X-Forwarded-For`, so a request through it is still known.
  """

  import Plug.Conn

  alias DevilsDictionary.Routing.PublicRouting
  alias DevilsDictionaryWeb.ReadingMode

  @proxy_headers ~w(x-forwarded-for forwarded x-forwarded-host x-forwarded-proto)
  @socket_proxy_headers ~w(x-forwarded-for x-forwarded-host x-forwarded-proto)
  @operator_prefixes ~w(dev ops kit s health admin)

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not proxied?(conn) ->
        conn

      PublicRouting.published_host?() and operator_surface?(conn.path_info) ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found\n") |> halt()

      ReadingMode.configured?() ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          503,
          "This development server reads drafts and is not the published host: " <>
            "it does not answer through a proxy.\n"
        )
        |> halt()

      true ->
        conn
    end
  end

  @doc "Whether a request came through a proxy or from another machine."
  def proxied?(conn) do
    Enum.any?(@proxy_headers, &(get_req_header(conn, &1) != [])) or not loopback?(conn.remote_ip)
  end

  @doc """
  Whether the LiveView socket refuses a connection: it came through a proxy
  or from another machine (`connect_info` with `:x_headers` and
  `:peer_data`; a connection whose peer is unknown counts as remote), and
  this server reads drafts for everyone and is not the published host.
  """
  def refuse_socket?(connect_info) when is_map(connect_info),
    do: proxied_connect?(connect_info) and ReadingMode.configured?()

  @doc "Whether a socket's connect info says it came through a proxy or from another machine."
  def proxied_connect?(connect_info) when is_map(connect_info) do
    headers = Map.get(connect_info, :x_headers) || []

    Enum.any?(headers, fn {name, _value} -> String.downcase(name) in @socket_proxy_headers end) or
      not loopback?(get_in(connect_info, [:peer_data, :address]))
  end

  @doc """
  The operator LiveViews' mount hook: on the published host, a LiveView
  reached through a proxy is not mounted, and the socket goes to `/`. The
  dead render never gets here through a proxy (`call/2` answers 404 first);
  this is for a socket that arrives by live navigation or with a token of
  its own.
  """
  def on_mount(:operator, _params, _session, socket) do
    if PublicRouting.published_host?() and proxied_socket?(socket),
      do: {:halt, Phoenix.LiveView.redirect(socket, to: "/")},
      else: {:cont, socket}
  end

  defp proxied_socket?(socket) do
    proxied_connect?(%{
      x_headers: Phoenix.LiveView.get_connect_info(socket, :x_headers),
      peer_data: Phoenix.LiveView.get_connect_info(socket, :peer_data)
    })
  end

  @doc "Whether a path is one of the operator surfaces a published host hides."
  def operator_surface?([first | _rest]), do: first in @operator_prefixes
  def operator_surface?(_path_info), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_ip), do: false
end
