defmodule DevilsDictionary.WikiquoteFixtures do
  @moduledoc """
  The Wikiquote pages #158 build 4a captured with `mix dd.fixtures.capture
  --source wikiquote`: metadata in `<slug>.json`, the response body beside it
  as the HTML (or JSON) it was, gzipped only when over 100 kB.
  """

  @dir "test/support/fixtures/wikiquote"

  @doc "`%{status, headers, body, meta}` for one captured page."
  def load(slug) do
    meta = Path.join(@dir, "#{slug}.json") |> File.read!() |> Jason.decode!()
    raw = Path.join(@dir, meta["body_file"]) |> File.read!()
    body = if String.ends_with?(meta["body_file"], ".gz"), do: :zlib.gunzip(raw), else: raw

    %{status: meta["status"], headers: meta["headers"], body: body, meta: meta}
  end

  @doc "The body of one captured page."
  def body(slug), do: load(slug).body

  @doc "Answers a `Plug.Conn` with a captured response, headers included."
  def respond(conn, slug) do
    %{status: status, headers: headers, body: body} = load(slug)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
    |> Plug.Conn.send_resp(status, body)
  end
end
