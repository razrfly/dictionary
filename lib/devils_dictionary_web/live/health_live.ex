defmodule DevilsDictionaryWeb.HealthLive do
  @moduledoc false
  use DevilsDictionaryWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <p>HealthLive</p>
    </Layouts.app>
    """
  end
end
