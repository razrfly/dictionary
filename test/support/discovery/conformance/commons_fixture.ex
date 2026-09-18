defmodule DevilsDictionary.Discovery.Conformance.CommonsFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Commons`.

  GET, MediaWiki `continue` cursors, images — and the second provider after the
  Met that declines targets: its match key is a Wikidata QID the page's senses
  already refer to, so `covered_target/1` writes that `refers_to` claim and
  `uncovered_target/1` is a word without one.

  Two files in every window exist to prove the two gates. One carries the
  `Attribution` licence template and never reaches the entities request; one
  is searched for and hydrated but its own `P180` statements do not name the
  QID, so it is dropped after hydration. The search proposes, the statements
  dispose, and a provider that stopped checking either would fail the suite.

  The bodies are the shapes the 2026-09-18 probe captured
  (`docs/integrations/commons.md`): a `generator=search` answer with
  `imageinfo` and `extmetadata`, a `wbgetentities` answer with
  `statements.P180`, and the empty answer that is `{"batchcomplete": true}`
  and nothing else.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  import Plug.Conn, only: [fetch_query_params: 1]

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery.Providers.Commons

  @qid "Q4991371"
  @label "soldier"

  @impl true
  def provider, do: Commons

  @impl true
  def covered_target(context) do
    word = word!(context, "soldier", ~w(wordnet))
    sense = sense!(context, word, "wordnet")
    entity = concept!(@qid, @label)

    {:ok, _assertion} =
      Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.9})

    target(word)
  end

  @impl true
  def uncovered_target(context) do
    # No `refers_to` anywhere on this page, so there is no QID to search for and
    # no statement a file could be kept by. The provider says so before any run.
    context |> word!("keyboard", ~w(wordnet)) |> target()
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
    # A search that proposes nothing has no `query` key at all.
    respond([])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Three hits against a `result_limit` of three: one page, no `continue`.
    # 1003 is `Attribution`-licensed and is gated out before hydration.
    respond([
      file(1001, "Cheshire Regiment trench Somme 1916", "pd", "Public domain", [@qid, "Q11446"]),
      file(1002, "Bataille Waterloo 1815 reconstitution", "cc-by-sa-3.0", "CC BY-SA 3.0", [@qid]),
      file(1003, "BMP-1 Zlot Darłowo 2009", nil, "Attribution", [@qid])
    ])

    %{pages: [~w(1001 1002)]}
  end

  def stub(:paged, _context) do
    # Two windows of three. 1006 is proposed by the search and hydrated, but
    # its own statements depict something else, so it is not on page two.
    respond([
      file(1001, "Cheshire Regiment trench Somme 1916", "pd", "Public domain", [@qid, "Q11446"]),
      file(1002, "Bataille Waterloo 1815 reconstitution", "cc-by-sa-3.0", "CC BY-SA 3.0", [@qid]),
      file(1003, "BMP-1 Zlot Darłowo 2009", nil, "Attribution", [@qid]),
      file(1004, "Into the Jaws of Death", "pd", "Public domain", [@qid, "Q16470"]),
      file(1005, "Escolta presidencial, Lima", "cc-by-sa-4.0", "CC BY-SA 4.0", [@qid]),
      file(1006, "Napoleon crossing the Alps", "pd", "Public domain", ["Q517"])
    ])

    %{pages: [~w(1001 1002), ~w(1004 1005)]}
  end

  # One stub for both endpoints, told apart by `action` the way the API is.
  # The search honours `gsrlimit` and `gsroffset` and hands back MediaWiki's
  # `continue` object while files remain; the entities call answers exactly
  # the `M`-ids it was asked for.
  defp respond(files) do
    Req.Test.stub(Commons, fn conn ->
      conn = fetch_query_params(conn)

      case conn.params["action"] do
        "query" ->
          limit = String.to_integer(conn.params["gsrlimit"])
          offset = String.to_integer(conn.params["gsroffset"] || "0")
          window = Enum.slice(files, offset, limit)

          body =
            if window == [] do
              %{"batchcomplete" => true}
            else
              %{
                "batchcomplete" => true,
                "query" => %{"pages" => Enum.map(window, &search_page/1)}
              }
            end

          body =
            if offset + limit < length(files),
              do:
                Map.put(body, "continue", %{
                  "gsroffset" => offset + limit,
                  "continue" => "gsroffset||"
                }),
              else: body

          Req.Test.json(conn, body)

        "wbgetentities" ->
          requested = String.split(conn.params["ids"] || "", "|", trim: true)

          entities =
            files
            |> Enum.filter(&("M#{&1.pageid}" in requested))
            |> Map.new(&{"M#{&1.pageid}", entity(&1)})

          Req.Test.json(conn, %{"entities" => entities, "success" => 1})
      end
    end)
  end

  defp file(pageid, title, code, short, depicts) do
    %{pageid: pageid, title: title, code: code, short: short, depicts: depicts}
  end

  defp search_page(file) do
    licence =
      %{
        "LicenseShortName" => %{"value" => file.short, "source" => "commons-desc-page"},
        "Artist" => %{
          "value" => ~s(<a href="//commons.wikimedia.org/wiki/User:Fixture">Fixture</a>),
          "source" => "commons-desc-page"
        },
        "ObjectName" => %{"value" => file.title, "source" => "mediawiki-metadata"},
        "DateTimeOriginal" => %{"value" => "1916-07-01", "source" => "commons-desc-page"}
      }
      |> then(fn m ->
        if file.code,
          do: Map.put(m, "License", %{"value" => file.code, "source" => "commons-templates"}),
          else: m
      end)

    %{
      "pageid" => file.pageid,
      "ns" => 6,
      "title" => "File:#{file.title}.jpg",
      "imageinfo" => [
        %{
          "mime" => "image/jpeg",
          "user" => "Fixture",
          "thumburl" => "https://thumb.commons.test/#{file.pageid}/640px.jpg",
          "url" => "https://upload.commons.test/#{file.pageid}.jpg",
          "descriptionurl" => "https://commons.test/wiki/File:#{file.pageid}.jpg",
          "extmetadata" => licence
        }
      ]
    }
  end

  defp entity(file) do
    %{
      "id" => "M#{file.pageid}",
      "type" => "mediainfo",
      "statements" => %{
        "P180" =>
          Enum.map(file.depicts, fn qid ->
            %{
              "mainsnak" => %{
                "snaktype" => "value",
                "property" => "P180",
                "datavalue" => %{"type" => "wikibase-entityid", "value" => %{"id" => qid}}
              },
              "rank" => "normal"
            }
          end)
      }
    }
  end
end
