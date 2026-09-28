defmodule DevilsDictionaryWeb.ReadingMode do
  @moduledoc """
  Which pages a reader may see (#219 B1): `:public` or `:internal`, decided
  per request, and again at each navigation of a mounted socket, and used
  for every link and every address the page serves (`Routing.Resolver`,
  `Routing.Links`, `Routing.Subjects`).

  Internal reading comes only from trusted places:

    * configuration — `config :devils_dictionary, :internal_reading, true`,
      set in `config/dev.exs` and `config/test.exs` and refused in the
      production configuration by `ReadingModeConfigTest`;
    * an authenticated internal contributor or reviewer
      (`Claims.Contributions.internal_contributor?/1`, read from the
      database, not from the session's copy of the account).

  Nothing in a request — no parameter, header or path — can switch it.
  Internal reading shows draft pages, marked as drafts; it publishes and
  approves nothing. A development server with the switch on shows drafts to
  whoever reaches it, so it must not be exposed through a tunnel.
  """

  alias DevilsDictionary.Claims.Contributions

  @doc "The reading mode for a scope (nil for an anonymous reader)."
  def mode(scope) do
    if configured?() or Contributions.internal_contributor?(scope),
      do: :internal,
      else: :public
  end

  @doc "Whether this installation's configuration turns internal reading on."
  def configured?, do: Application.get_env(:devils_dictionary, :internal_reading, false) == true

  @doc """
  The `on_mount` for reader LiveViews: the current scope, as
  `UserAuth`'s `:mount_current_scope` gives it, and `:reading_mode`, read
  again before each `handle_params` so a revoked role stops reading
  internally at the next navigation, not at the next page load.
  """
  def on_mount(:default, params, session, socket) do
    {:cont, socket} =
      DevilsDictionaryWeb.UserAuth.on_mount(:mount_current_scope, params, session, socket)

    socket =
      socket
      |> assign_mode()
      |> Phoenix.LiveView.attach_hook(:reading_mode, :handle_params, fn _params, _uri, socket ->
        {:cont, assign_mode(socket)}
      end)

    {:cont, socket}
  end

  defp assign_mode(socket),
    do: Phoenix.Component.assign(socket, :reading_mode, mode(socket.assigns.current_scope))
end
