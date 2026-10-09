defmodule DevilsDictionaryWeb.SitemapController do
  @moduledoc """
  `/sitemap.xml`, the index, and `/sitemaps/:file`, each sitemap it names
  (#237 C5): `Routing.Sitemaps` builds them from the published canonical
  pages and caches them per publication receipt and route change. With the
  switch off (D5) the index is empty. Every response says `noindex` in its
  `X-Robots-Tag`: a sitemap is for crawling, never a page to index. A file
  the index does not name is 404.
  """

  use DevilsDictionaryWeb, :controller

  alias DevilsDictionary.Routing.Sitemaps

  def index(conn, _params), do: xml(conn, Sitemaps.index())

  def show(conn, %{"file" => file}) do
    case Sitemaps.sitemap(file) do
      {:ok, body} -> xml(conn, body)
      :error -> send_resp(conn, 404, "no such sitemap\n")
    end
  end

  defp xml(conn, body) do
    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("x-robots-tag", "noindex")
    |> send_resp(200, body)
  end
end
