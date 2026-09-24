defmodule DevilsDictionary.Discovery.Conformance.WikiquoteFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Wikiquote` (#158
  build 4), over the pages build 4a captured.

  Two hosts answer through the one `Req.Test` stub, told apart the way the
  real ones are: Wikidata (`wbgetentities` for sitelinks by QID, and for QIDs
  by page title) and Wikiquote's Parsoid page endpoint. The page bodies are
  the captured ones, unedited; the Wikidata answers are written here, because
  what they say is the fixture's premise — which page a concept's sitelink
  names, and which item a citation's linked page is.

  The concept QIDs are fixture values (`Q900700` for *grief*); the answer that
  gives them a Wikiquote page is the stub's. Bierce's `Q191050` is his real
  QID, and the catalog seeds him with it.

  The expected ids are literals, computed once from the captured pages, so a
  change to how a line is identified breaks this suite rather than agreeing
  with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  import Plug.Conn, only: [fetch_query_params: 1]

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.WikiquoteFixtures

  # Grief's first six cited lines, in page order (76 of its 79 are cited).
  @grief ~w(4dfa8919b80f06fa5bcd5677dbbb30f5 4e93fb50ef4f84f1791ff6ea7f5a952b
            7d22f7cc0b770d5af86bcaa27f1727d7 39800759d5c24e38cac4ec760e4bbc25
            124fe60464741ad6d251eee7804c370c cc713ca01fc6f08a4f208bf64a7c391a)

  # Nepotism's three: two journalists with no linked page, and Bierce.
  @nepotism_riggio "49a61b6c9bc518fbc5abdff5f41dc17e"
  @nepotism_martin "2b9c126ad9d76a9639b9218240441ce1"
  @nepotism_bierce "00c15e2b80761dc14440673dd923cb33"

  @grief_qid "Q900700"
  @nepotism_qid "Q900701"

  @impl true
  def provider, do: Wikiquote

  @impl true
  def covered_target(context), do: target(context, "grief", @grief_qid)

  @impl true
  def uncovered_target(context) do
    # No `refers_to` on this page, so no QID and no sitelink to ask about.
    context |> word!("peace", ~w(wordnet)) |> as_target()
  end

  @doc "A page whose sense refers to `qid`, as the Met's fixture builds one."
  def target(context, lemma, qid) do
    word = word!(context, lemma, ~w(wordnet))
    sense = sense!(context, word, "wordnet")
    entity = concept!(qid, String.capitalize(lemma))
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})
    as_target(word)
  end

  defp as_target(word) do
    %{object_id: word.object_id, term: word.lemma, language: word.language_tag, relevance: "term"}
  end

  @impl true
  def stub(:empty, _context) do
    # The concept has no Wikiquote page: Wikidata's answer carries no
    # `enwikiquote` sitelink, and the run ends there, one request spent.
    respond(%{})
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    respond(%{@grief_qid => "Grief"})
    # `result_limit: 3` in the suite, and Grief has more behind it; the first
    # page is the first three cited lines.
    %{pages: [Enum.take(@grief, 3)]}
  end

  def stub(:paged, _context) do
    respond(%{@grief_qid => "Grief"})
    %{pages: [Enum.take(@grief, 3), Enum.slice(@grief, 3, 3)]}
  end

  # #164's creator case on Nepotism: Bierce's line links his page, whose
  # sitelink is Q191050 — matched to the seeded Bierce, never by name. The two
  # journalists' lines link no page and stay text.
  @impl true
  def creator_case(context) do
    # The covered target is Grief's; the creator case is asked of the same
    # target, so Grief's QID answers with Nepotism's page here.
    _ = context
    respond(%{@grief_qid => "Nepotism"}, %{"Ambrose Bierce" => "Q191050"})

    %{
      credited: @nepotism_bierce,
      qid: "Q191050",
      text_only: @nepotism_riggio,
      certainty: :candidate
    }
  end

  @doc "Nepotism's ids, for tests beyond the suite."
  def nepotism_ids, do: [@nepotism_riggio, @nepotism_martin, @nepotism_bierce]

  @doc "The concept QID Nepotism's fixture sitelink hangs on."
  def nepotism_qid, do: @nepotism_qid

  @doc """
  Installs the stub. `sitelinks` maps a concept QID to its Wikiquote page
  title; `authors` maps a page title to its Wikidata item (or to `{:redirect,
  title}`). Anything not named has no item. `humans` is the QIDs the query
  service says are people (`P31` = `Q5`): every author's, unless a test says
  otherwise.
  """
  def respond(sitelinks, authors \\ %{}, humans \\ :all) do
    Req.Test.stub(Wikiquote, fn conn -> answer(conn, sitelinks, authors, humans) end)
  end

  @doc "The stub's answer for one request, for tests that wrap it."
  def answer(conn, sitelinks, authors, humans \\ :all) do
    conn = fetch_query_params(conn)

    case {conn.host, conn.params} do
      # The query service: which of the `VALUES` are people.
      {"sparql.test", %{"query" => query}} ->
        people =
          ~r/wd:(Q\d+)/
          |> Regex.scan(query, capture: :all_but_first)
          |> List.flatten()
          |> Enum.filter(&(humans == :all or &1 in humans))

        Req.Test.json(conn, %{
          "results" => %{
            "bindings" =>
              Enum.map(people, &%{"item" => %{"value" => "http://www.wikidata.org/entity/#{&1}"}})
          }
        })

      {"wikidata.test", %{"ids" => ids}} ->
        entities =
          ids
          |> String.split("|", trim: true)
          |> Map.new(fn qid ->
            {qid, entity(qid, Map.get(sitelinks, qid))}
          end)

        Req.Test.json(conn, %{"entities" => entities})

      # Wikiquote's own `prop=pageprops&ppprop=wikibase_item`, formatversion 2.
      # `authors` maps a title to its item's QID, or to `{:redirect, title}`
      # when the page is an alias of another.
      {"wikiquote.test", %{"action" => "query", "titles" => titles}} ->
        asked = String.split(titles, "|", trim: true)

        redirects =
          for title <- asked,
              {:redirect, to} <- [Map.get(authors, title)],
              do: %{"from" => title, "to" => to}

        pages =
          ((asked -- Enum.map(redirects, & &1["from"])) ++ Enum.map(redirects, & &1["to"]))
          |> Enum.uniq()
          |> Enum.map(fn title ->
            case Map.get(authors, title) do
              qid when is_binary(qid) ->
                %{"title" => title, "pageprops" => %{"wikibase_item" => qid}}

              _ ->
                %{"title" => title, "missing" => true}
            end
          end)

        Req.Test.json(conn, %{"query" => %{"redirects" => redirects, "pages" => pages}})

      {"wikiquote.test", _params} ->
        conn.request_path |> page_slug() |> then(&WikiquoteFixtures.respond(conn, &1))
    end
  end

  defp entity(qid, nil), do: %{"type" => "item", "id" => qid, "sitelinks" => %{}}

  defp entity(qid, title),
    do: %{
      "type" => "item",
      "id" => qid,
      "sitelinks" => %{"enwikiquote" => %{"site" => "enwikiquote", "title" => title}}
    }

  # `/api/rest_v1/page/html/Grief` → `grief`; the redirect target
  # `/w/rest.php/v1/page/Banking/html` → `banking`.
  defp page_slug(path) do
    title =
      case String.split(path, "/", trim: true) do
        ["api", "rest_v1", "page", "html", title] -> title
        ["w", "rest.php", "v1", "page", title, "html"] -> title
      end

    title |> URI.decode() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
