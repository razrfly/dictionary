defmodule DevilsDictionaryWeb.ReadingStatus do
  @moduledoc """
  The HTTP status of a reader page, decided before its LiveView renders
  (#219 B2).

  A LiveView cannot answer 301, 404 or 410 itself, and raising one would put
  the development server's debug page in front of a reader. So this plug,
  in the reader routes' pipeline, asks the same questions the LiveView will —
  through `Routing.Resolver` and `Lexicon`, in the request's reading mode —
  and either answers a redirect itself or sets the status the LiveView then
  renders under:

  | route | outcome | response |
  |---|---|---|
  | `/<family>/:slug` | canonical, choice | 200 |
  | | equivalent spelling or alias of a page served in the mode | 301 to its canonical |
  | | missing, or not served in the mode | 404 |
  | | a tombstone of a page the public saw | 410 |
  | | malformed (bad encoding, dot segment, NUL) | 400 |
  | | inconsistent ledger state | 500, logged with diagnostics |
  | `/on/:slug` | words for the slug, or an overview served in the mode | 200 |
  | | no words; an equivalent spelling or alias of an overview served in the mode | 301 |
  | | malformed | 400 |
  | | neither | 404 (410 or 500 as its overview's outcome says) |
  | `/words/:id/:slug` | no such lexeme, or not an id at all | 404, never a word found by the slug |

  Live navigation re-runs the same decision in the LiveView, which follows a
  redirect itself; the status only matters to a direct request.
  """

  import Plug.Conn

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Routing.{Address, Resolution, Resolver}
  alias DevilsDictionaryWeb.ReadingMode

  def init(opts), do: opts

  def call(conn, _opts) do
    mode = ReadingMode.mode(conn.assigns[:current_scope])

    case conn.path_info do
      ["on", _slug] -> on(conn, mode)
      ["words", _id, _slug] -> word(conn)
      [family, _slug] -> if family in Address.families(), do: subject(conn, mode), else: conn
      _other -> conn
    end
  end

  defp subject(conn, mode) do
    case Resolver.resolve(conn.request_path, mode: mode) do
      %Resolution{outcome: :redirect, location: location} -> redirect(conn, location)
      %Resolution{outcome: outcome} when outcome in [:canonical, :choice] -> conn
      resolution -> put_status(conn, Resolution.http_status(resolution))
    end
  end

  defp on(conn, mode) do
    resolution = Resolver.resolve(conn.request_path, mode: mode)

    # Words first: an overview's alias never redirects them away.
    cond do
      resolution.outcome == :invalid ->
        put_status(conn, 400)

      Lexicon.lookup(conn.path_params["slug"]).lexemes != [] ->
        conn

      resolution.outcome == :redirect and resolution.page.role == :overview ->
        redirect(conn, resolution.location)

      resolution.outcome == :canonical and resolution.page.role == :overview ->
        conn

      resolution.outcome in [:gone, :corrupt] ->
        put_status(conn, Resolution.http_status(resolution))

      true ->
        put_status(conn, 404)
    end
  end

  defp word(conn) do
    if Lexicon.by_object_id(conn.path_params["id"]), do: conn, else: put_status(conn, 404)
  end

  defp redirect(conn, location) do
    conn
    |> put_status(301)
    |> Phoenix.Controller.redirect(to: Address.encode(location))
    |> halt()
  end
end
