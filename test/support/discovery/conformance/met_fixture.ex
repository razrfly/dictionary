defmodule DevilsDictionary.Discovery.Conformance.MetFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Met`.

  GET, offset paging, artworks — and the only provider in the set that declines
  targets. Its match key is a Wikidata QID the page's senses already refer to,
  so `covered_target/1` has to write that `refers_to` claim and
  `uncovered_target/1` is simply a word without one.

  Two entities on purpose. `automatic_mapping/1` puts their labels ahead of the
  headword and `uniq_by(&String.downcase/1)` folds “war” into “War”, so the
  recipe holds exactly two search terms — which is what makes the round-robin
  cursor (`"0:0"` → `"1:0"` → done) observable in the pagination case.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  import Plug.Conn, only: [fetch_query_params: 1, send_resp: 3]

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery.Providers.Met

  @exact_term "War"
  @broader_term "World War I"

  @impl true
  def provider, do: Met

  @impl true
  def covered_target(context) do
    word = word!(context, "war", ~w(wordnet))
    sense = sense!(context, word, "wordnet")

    for {qid, label, confidence} <- [
          {"Q198", @exact_term, 0.95},
          {"Q361", @broader_term, 0.9}
        ] do
      entity = concept!(qid, label)

      {:ok, _assertion} =
        Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: confidence})
    end

    target(word)
  end

  @impl true
  def uncovered_target(context) do
    # No `refers_to` anywhere on this page, so there is no QID to search for and
    # no tag a result could be kept by. The provider says so before any run.
    context |> word!("peace", ~w(wordnet)) |> target()
  end

  defp target(word) do
    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # The Met answers a search with no matches with `total` and a null
    # `objectIDs`, which is an empty page rather than a malformed body.
    respond(%{@exact_term => [], @broader_term => []}, %{})
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    respond(
      %{@exact_term => [1001, 1002]},
      %{
        1001 => object(1001, "A Cavalry Charge", "Q198"),
        1002 => object(1002, "The Siege", "Q198")
      }
    )

    %{pages: [~w(1001 1002)]}
  end

  def stub(:paged, _context) do
    respond(
      %{@exact_term => [1001], @broader_term => [1003]},
      %{
        1001 => object(1001, "A Cavalry Charge", "Q198"),
        1003 => object(1003, "In the Trenches", "Q361")
      }
    )

    %{pages: [~w(1001), ~w(1003)]}
  end

  # #164 C6. The Met publishes the artist's own authority record on the
  # object: `artistWikidata_URL` for 1001 (a QID the kit mints from), and only
  # `artistULAN_URL` for 1002 — ULAN is not a namespace the registry holds, so
  # that artist keeps a text line and is credited to nobody.
  @impl true
  def creator_case(_context) do
    respond(
      %{@exact_term => [1001, 1002]},
      %{
        1001 =>
          object(1001, "A Cavalry Charge", "Q198")
          |> Map.merge(%{
            "artistDisplayName" => "Pablo Picasso",
            "artistWikidata_URL" => "https://www.wikidata.org/wiki/Q5593",
            "artistULAN_URL" => "http://vocab.getty.edu/page/ulan/500009666"
          }),
        1002 =>
          object(1002, "The Siege", "Q198")
          |> Map.merge(%{
            "artistDisplayName" => "Utagawa Kuniyoshi",
            "artistWikidata_URL" => "",
            "artistULAN_URL" => "http://vocab.getty.edu/page/ulan/500060498"
          })
      }
    )

    # The Met's own stub answers the tag walk; this one also knows Picasso.
    Req.Test.stub(Clients, fn conn ->
      conn = fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(fn
          "Q5593" ->
            {"Q5593",
             DevilsDictionary.Discovery.Conformance.human("Q5593", "Pablo Picasso",
               born: ~D[1881-10-25],
               died: ~D[1973-04-08],
               description: "Spanish painter and sculptor (1881–1973)"
             )}

          qid ->
            {qid, %{"id" => qid, "claims" => %{"P279" => []}}}
        end)

      Req.Test.json(conn, %{"entities" => entities})
    end)

    %{credited: "1001", qid: "Q5593", text_only: "1002"}
  end

  # One stub for both endpoints: `/v1.1/search` is recognised by its `q`
  # parameter, `/v1/objects/{id}` by its path.
  defp respond(searches, objects) do
    stub_wikidata()

    Req.Test.stub(Met, fn conn ->
      conn = fetch_query_params(conn)

      case conn.params["q"] do
        nil ->
          id = conn.request_path |> Path.basename() |> String.to_integer()

          case Map.fetch(objects, id) do
            {:ok, object} -> Req.Test.json(conn, object)
            :error -> send_resp(conn, 404, "not found")
          end

        term ->
          case Map.get(searches, term, []) do
            [] -> Req.Test.json(conn, %{"total" => 0, "objectIDs" => nil})
            ids -> Req.Test.json(conn, %{"total" => length(ids), "objectIDs" => ids})
          end
      end
    end)
  end

  # The broader walk fetches nothing when every tag matches a target exactly,
  # which is this fixture's case — but it is stubbed anyway, because an
  # unstubbed Req call raises rather than reaching the network and a fixture
  # that depended on the walk staying quiet would be brittle.
  defp stub_wikidata do
    Req.Test.stub(Clients, fn conn ->
      conn = fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(&{&1, %{"id" => &1, "claims" => %{"P279" => []}}})

      Req.Test.json(conn, %{"entities" => entities})
    end)
  end

  defp object(id, title, qid) do
    %{
      "objectID" => id,
      "title" => title,
      "objectDate" => "ca. 1780",
      "isPublicDomain" => true,
      "primaryImageSmall" => "https://images.metmuseum.org/CRDImages/#{id}.jpg",
      "objectURL" => "https://www.metmuseum.org/art/collection/search/#{id}",
      "creditLine" => "Gift of a fixture, 1917",
      "artistDisplayName" => "Anonymous",
      "objectWikidata_URL" => "",
      "tags" => [
        %{
          "term" => if(qid == "Q198", do: "War", else: "World War I"),
          "Wikidata_URL" => "https://www.wikidata.org/wiki/#{qid}"
        }
      ]
    }
  end
end
