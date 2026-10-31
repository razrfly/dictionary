defmodule DevilsDictionary.SourceViewHelpers do
  @moduledoc "Source-reader regressions explicitly exercise the source-record view after #291."
  import Phoenix.ConnTest
  @endpoint DevilsDictionaryWeb.Endpoint
  import Phoenix.LiveViewTest, only: [live: 2]

  def source_live(conn, path) do
    live(conn, source_path(path))
  end

  def source_path(path) do
    uri = URI.parse(path)

    query = URI.decode_query(uri.query || "")

    if String.starts_with?(uri.path || "", ["/on/", "/words/", "/define/"]) and
         query["layout"] != "current" do
      query = Map.put(query, "view", "records")
      URI.to_string(%{uri | query: URI.encode_query(query)})
    else
      path
    end
  end
end
