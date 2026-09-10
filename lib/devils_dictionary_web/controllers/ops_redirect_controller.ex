defmodule DevilsDictionaryWeb.OpsRedirectController do
  @moduledoc """
  The retired paths of the three developer surfaces (#77 §1).

  `/s/:slug`, `/health` and `/admin/imports` were the whole of the site's
  navigation, which is what #77 objects to: one test population and two consoles
  presented as the product's structure. They now live under `/ops`, and these
  three routes are what the old links resolve to.

  **302, not 301.** A permanent redirect is cached by the browser near-forever,
  and `/ops` is a first guess at where a diagnostic surface belongs. These are
  pre-launch paths with no external inbound links; a temporary redirect costs
  nothing and leaves the decision reversible.

  The query string is carried across whole, because every one of these pages
  keeps its entire state there — `?scope=`, `?missing=`, `?state=`, the taxon
  drill and the page number.
  """

  use DevilsDictionaryWeb, :controller

  def scope(conn, %{"slug" => slug}), do: moved(conn, ~p"/ops/scopes/#{slug}")

  def health(conn, _params), do: moved(conn, ~p"/ops/health")

  def imports(conn, _params), do: moved(conn, ~p"/ops/imports")

  defp moved(conn, to) do
    conn
    |> put_status(:found)
    |> redirect(to: with_query(to, conn.query_string))
  end

  defp with_query(to, ""), do: to
  defp with_query(to, query), do: to <> "?" <> query
end
