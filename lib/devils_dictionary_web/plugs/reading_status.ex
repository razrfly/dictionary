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
  | `/words/:id/:slug` | no such lexeme, or not the exact text of an id | 404, never a word found by the slug; 400 if the slug is not text, whatever the id |
  | `/entities/:id/:slug` | no such entity, or not the exact text of an id | 404 (ADR 0004 §6), never a page found by the slug; 400 if the slug is not text, whatever the id |
  | | on the published host, read publicly: an entity whose subject or edition page is not served there (`Routing.Links.withheld?/2`, #237 D2) | 404, as the page's own address |

  Live navigation re-runs the same decision in the LiveView, which follows a
  redirect itself; the status only matters to a direct request.
  """

  import Plug.Conn

  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Routing.{Address, Input, Links, Resolution, Resolver}
  alias DevilsDictionaryWeb.ReadingMode

  def init(opts), do: opts

  def call(conn, _opts) do
    mode = ReadingMode.mode(conn.assigns[:current_scope])

    case conn.path_info do
      ["on", _slug] -> on(conn, mode)
      ["words", _id, _slug] -> word(conn)
      ["entities", _id, _slug] -> entity(conn, mode)
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

  # A slug that is not text is 400 whatever the id names. A found word with
  # a wrong slug is redirected to its own by the LiveView; a missing one is
  # 404.
  defp word(conn) do
    cond do
      not Input.text?(conn.path_params["slug"]) -> put_status(conn, 400)
      (id = exact_id(conn.path_params["id"])) && Lexicon.by_object_id(id) -> conn
      true -> put_status(conn, 404)
    end
  end

  # An exact identity: the thing page for an entity, a merged identity or a
  # split one; anything else is 404 (#194's follow-up from #224). A slug
  # that is not text is 400 whatever the id names. A wrong slug on a real
  # id is the LiveView's redirect to its own. On the published host, read
  # publicly, an entity whose page is not served there is 404 too, as that
  # page's address is (#237 D2): the route never shows a draft's subject.
  defp entity(conn, mode) do
    cond do
      not Input.text?(conn.path_params["slug"]) ->
        put_status(conn, 400)

      (id = exact_id(conn.path_params["id"])) && EntityPage.exists?(id) &&
          not Links.withheld?(id, mode) ->
        conn

      true ->
        put_status(conn, 404)
    end
  end

  # An id is the exact decimal text of a positive integer, never a spelling
  # of one: `013` and `+13` name nothing, so an address has one form.
  defp exact_id(text) when is_binary(text) do
    case Integer.parse(text) do
      {id, ""} when id > 0 -> if Integer.to_string(id) == text, do: id
      _other -> nil
    end
  end

  defp exact_id(_text), do: nil

  defp redirect(conn, location) do
    conn
    |> put_status(301)
    |> Phoenix.Controller.redirect(to: Address.encode(location))
    |> halt()
  end
end
