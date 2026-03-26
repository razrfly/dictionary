defmodule DevilsDictionaryWeb.PageController do
  use DevilsDictionaryWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
