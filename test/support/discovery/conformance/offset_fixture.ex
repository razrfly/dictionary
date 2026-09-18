defmodule DevilsDictionary.Discovery.Conformance.OffsetFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.FakeOffsetDiscoveryProvider`.

  The controlled counter-example: plain GET, offset paging, a bare JSON array
  for a body and a `:text` content type with no image slot. It is in the
  conformance set for the same reason it exists at all — everything the shared
  pipeline does was written against CineGraph's GraphQL-over-POST shape, and a
  suite that only ever drove that shape would prove nothing about the next
  provider.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.FakeOffsetDiscoveryProvider

  @impl true
  def provider, do: FakeOffsetDiscoveryProvider

  @impl true
  def covered_target(context) do
    word = word!(context, "elegy", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    respond([])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Two rows against a `result_limit` of three: a short page, so the provider
    # ends pagination rather than handing back an offset with nothing behind it.
    respond(rows(2))
    %{pages: [~w(1 2)]}
  end

  def stub(:paged, _context) do
    respond(rows(5))
    %{pages: [~w(1 2 3), ~w(4 5)]}
  end

  defp rows(count) do
    Enum.map(
      1..count//1,
      &%{
        "id" => &1,
        "title" => "Elegy #{&1}",
        "year" => "1751",
        "page" => &1 * 3,
        "text" => "an elegy, line #{&1}"
      }
    )
  end

  defp respond(rows) do
    Req.Test.stub(FakeOffsetDiscoveryProvider, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      offset = String.to_integer(conn.params["offset"])
      limit = String.to_integer(conn.params["limit"])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(Enum.slice(rows, offset, limit)))
    end)
  end
end
