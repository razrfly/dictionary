defmodule DevilsDictionaryWeb.RobotsController do
  @moduledoc """
  `robots.txt` (#237 C5), generated from the launch switch, the registry's
  reserved prefixes and the launch manifest, never a static file:

    * **on**: the eight families and the On pages the manifest lists as
      lexical entries are allowed, by name; the sitemap index is named;
    * **off** (D5): the eight families are disallowed, and no sitemap is
      named;
    * always: the surfaces that are not for reading are disallowed
      (`DevilsDictionaryWeb.Indexing.kept_out/0`: operations, evidence,
      claims and their review, accounts, development, `/search`) and so is
      every query variant (`/*?`). The static assets a page renders with
      are allowed by name, since a longer rule wins over `/*?`.

  Reader surfaces that are noindex (an unlisted On page, an exact word, the
  exact-identity route, a source page) are not disallowed: a crawler must
  fetch them to read the instruction (ADR 0004 §7).
  """

  use DevilsDictionaryWeb, :controller

  alias DevilsDictionary.Routing.{Address, PublicRouting}
  alias DevilsDictionaryWeb.Indexing

  @statics ~w(assets fonts images)

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body())
  end

  @doc "The file's text, as the switch and the manifest stand now."
  def body do
    on? = PublicRouting.enabled?()

    lines =
      ["User-agent: *"] ++
        if(on?, do: Enum.map(Address.families(), &"Allow: /#{&1}/"), else: []) ++
        if(on?, do: Enum.map(lexical_paths(), &"Allow: #{&1}$"), else: []) ++
        Enum.map(@statics, &"Allow: /#{&1}/") ++
        if(on?, do: [], else: Enum.map(Address.families(), &"Disallow: /#{&1}/")) ++
        Enum.map(Indexing.kept_out(), &"Disallow: /#{&1}") ++
        ["Disallow: /*?"] ++
        if(on?, do: ["", "Sitemap: #{PublicRouting.origin()}/sitemap.xml"], else: [])

    Enum.join(lines, "\n") <> "\n"
  end

  defp lexical_paths do
    Indexing.lexical_entries()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&Address.encode/1)
  end
end
