defmodule DevilsDictionaryWeb.LocalDevelopment do
  @moduledoc """
  The development server's live reloader, code reloader and repository
  check, for a request from the machine itself (#250).

  The endpoint plugs this where a generated one plugs the three directly,
  when it is compiled with the code reloader. They answer before any other
  plug: `Phoenix.CodeReloader` sends the compiler's output when the checkout
  does not compile, and `Phoenix.LiveReloader` puts its reloader in every
  page. The published host is this development server reached through a
  tunnel (#237 D2), so a request that came through a proxy
  (`ProxyGuard.proxied?/1`) skips all three: it never compiles the checkout
  and is never shown the compiler's output, and its pages carry no
  reloader. Nor does a socket compile (the endpoint's `code_reloader: false`
  on each). The owner's own requests reload as on any development server.
  While the checkout does not compile, the modules Mix removed to recompile
  are missing for every request, so a page that needs one answers 500
  through the tunnel too, without the trace. Stack traces and the
  pending-migration page are `debug_errors`'s, which the published host is
  compiled without (`config/dev.exs`).
  """

  @behaviour Plug

  alias DevilsDictionaryWeb.ProxyGuard

  @tools [
    {Phoenix.LiveReloader, []},
    {Phoenix.CodeReloader, []},
    {Phoenix.Ecto.CheckRepoStatus, otp_app: :devils_dictionary}
  ]

  @impl Plug
  def init(opts), do: Keyword.get(opts, :tools, @tools)

  @impl Plug
  def call(conn, tools) do
    if ProxyGuard.proxied?(conn), do: conn, else: Plug.run(conn, tools)
  end
end
