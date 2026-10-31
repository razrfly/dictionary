defmodule DevilsDictionary.SourceViewHelpers do
  @moduledoc "Source-reader regressions explicitly exercise the source-record view after #291."
  import Phoenix.ConnTest
  @endpoint DevilsDictionaryWeb.Endpoint
  import Phoenix.LiveViewTest, only: [live: 2]

  def source_live(conn, path) do
    source_path = source_path(path)

    case live(conn, source_path) do
      {:ok, view, html} ->
        if String.ends_with?(URI.parse(source_path).path, "/materials"),
          do: {:ok, view, Phoenix.LiveViewTest.render(view)},
          else: {:ok, view, html}

      other ->
        other
    end
  end

  def source_path(path) do
    uri = URI.parse(path)

    query = URI.decode_query(uri.query || "")

    if String.starts_with?(uri.path || "", ["/on/", "/words/", "/define/"]) and
         query["layout"] != "current" do
      query = Map.delete(query, "view")

      path =
        if String.ends_with?(uri.path, "/materials"), do: uri.path, else: uri.path <> "/materials"

      URI.to_string(%{
        uri
        | path: path,
          query: if(map_size(query) == 0, do: nil, else: URI.encode_query(query))
      })
    else
      path
    end
  end
end
