defmodule DevilsDictionary.Discovery.Conformance.PoetrydbFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Poetrydb`.

  The responses here are real ones, trimmed: the candidate list is the head of
  what `/lines/war/title,author,linecount` answered on 2026-09-18, and each
  poem is a five-line window around its first use of *war*, from that poet's
  own `/lines,author/war;<poet>` response the same day.

  The first candidate is kept deliberately. *An Exile's Farewell* is in
  PoetryDB's answer for `war` and contains no such word — the search matches
  substrings, and this one is matching *warm*. It is in this fixture so that a
  provider which stopped verifying the hydrated lines would fail here rather
  than on a word page, and the expected ids below say so by leaving it out.

  Byron is here for the opposite reason. `/lines,author/war;<poet>` answers
  `503` for him however long you wait — his collected works cannot be
  serialized in one response — so the stub refuses that route for him exactly
  as PoetryDB does, and answers the three-axis route that names one poem. He is
  in the expected ids, so a provider that dropped the straggler pass would lose
  him and fail here rather than leaving two of PoetryDB's poets permanently
  invisible.

  The external ids are written as literals rather than computed from the
  provider, so that changing how a poem is identified breaks this suite instead
  of quietly agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Poetrydb

  # The five attested poems, in candidate order. The sixth candidate — Gordon's
  # — has no id here because the attestation gate drops it.
  @seeger_ode "4d1c4e808909f55b5b8b179df90d8f2c"
  @seeger_paris "119e4a6e84e566620ed9ae85b4eb13f8"
  @pope_cecilia "3c87d8c91055c41e2aa07a542e661c21"
  @swinburne_tiresias "aaf035b023859e5b086dcf9520632802"
  @byron_prayer "7ff5b0eee309f2a35a3eb1e04919edfe"

  @impl true
  def provider, do: Poetrydb

  @impl true
  def covered_target(context) do
    word = word!(context, "war", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # PoetryDB's own dialect for "no poem uses this word": HTTP 200 carrying a
    # 404 in the body. A negative cache, not a failure.
    respond(%{"status" => 404, "reason" => "Not found"}, [])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Three candidates against a `result_limit` of three, with nothing behind
    # them, so pagination ends rather than promising a page that is not there.
    # Two poets in the window, so the page costs one candidate request and two
    # hydrations — and the first candidate is dropped by the gate.
    respond(candidates(3), poems())
    %{pages: [[@seeger_ode, @seeger_paris]]}
  end

  def stub(:paged, _context) do
    # Six candidates, three to a page. The first page carries the unattested
    # Gordon candidate, which is why it yields two items and not three: the
    # window is a window of candidates, and the gate decides what survives it.
    # The second closes on Byron, who is reachable only through the straggler
    # pass — the poet route refuses him and the page has him anyway.
    respond(candidates(6), poems())

    %{
      pages: [
        [@seeger_ode, @seeger_paris],
        [@pope_cecilia, @swinburne_tiresias, @byron_prayer]
      ]
    }
  end

  # #164 C6: Alan Seeger has `author_qid` Q1849302 in `poetrydb-v1.json`;
  # "George Gordon, Lord Byron" matches no Wikidata label or alias and the
  # manifest names no QID for him, so his poem keeps a text line. Both come
  # from the manifest as committed — the fixture does not invent either fact.
  @impl true
  def creator_case(_context) do
    [_gordon, seeger_ode, _paris, _pope, _swinburne, byron] = candidates(6)
    respond([seeger_ode, byron], poems())

    %{credited: @seeger_ode, qid: "Q1849302", text_only: @byron_prayer}
  end

  # The candidate list, in the order PoetryDB returned it — the poet who does
  # not attest the word first, exactly as the live answer had it.
  defp candidates(count) do
    [
      %{"author" => "Adam Lindsay Gordon", "title" => "An Exile's Farewell", "linecount" => "56"},
      %{
        "author" => "Alan Seeger",
        "title" => "Ode in Memory of the American Volunteers Fallen for France",
        "linecount" => "104"
      },
      %{"author" => "Alan Seeger", "title" => "Paris", "linecount" => "174"},
      %{
        "author" => "Alexander Pope",
        "title" => "Ode on St Cecilia's Day,",
        "linecount" => "134"
      },
      %{"author" => "Algernon Charles Swinburne", "title" => "Tiresias", "linecount" => "386"},
      %{
        "author" => "George Gordon, Lord Byron",
        "title" => "The Prayer of Nature",
        "linecount" => "64"
      }
    ]
    |> Enum.take(count)
  end

  defp poems do
    %{
      "Adam Lindsay Gordon" => [
        poem("Adam Lindsay Gordon", "An Exile's Farewell", "56", [
          "The ocean heaves around us still",
          "With long and measured swell,",
          "The autumn gales our canvas fill,",
          "Our ship rides smooth and well.",
          "The broad Atlantic's bed of foam"
        ])
      ],
      "Alan Seeger" => [
        poem(
          "Alan Seeger",
          "Ode in Memory of the American Volunteers Fallen for France",
          "104",
          [
            "Has been achieved, nor wholly unreplied",
            "Can sneerers triumph in the charge they make",
            "That from a war where Freedom was at stake",
            "America withheld and, daunted, stood aside.",
            ""
          ]
        ),
        poem("Alan Seeger", "Paris", "174", [
          "",
          "And in the brilliant-lighted door of cinemas the barker calls,",
          "And lurid posters paint the walls with scenes of Love and crime and war.",
          "",
          ""
        ])
      ],
      "Alexander Pope" => [
        poem("Alexander Pope", "Ode on St Cecilia's Day,", "134", [
          "      Sloth unfolds her arms and wakes,",
          "      Listening Envy drops her snakes;",
          "  Intestine war no more our passions wage,",
          "  And giddy factions hear away their rage.",
          ""
        ])
      ],
      "George Gordon, Lord Byron" => [
        poem("George Gordon, Lord Byron", "The Prayer of Nature", "64", [
          "Thou, who canst guide the wandering star,",
          "  Through trackless realms of aether's space;",
          "Who calm'st the elemental war,",
          "  Whose hand from pole to pole I trace:",
          ""
        ])
      ],
      "Algernon Charles Swinburne" => [
        poem("Algernon Charles Swinburne", "Tiresias", "386", [
          "Which only fate, not force, can bring to nought,",
          "Took then to wife the light of all men's lands,",
          "War's child and love's, most sweet and wise and strong,",
          "Order of things and rule and guiding song.",
          ""
        ])
      ]
    }
  end

  defp poem(author, title, linecount, lines) do
    %{"author" => author, "title" => title, "linecount" => linecount, "lines" => lines}
  end

  # The poet whose collected works PoetryDB cannot serialize. Measured: every
  # `/lines,author/<word>;<poet>` for him is a 503 at about sixteen seconds.
  @unserializable "George Gordon, Lord Byron"

  # Three routes on one stub, told apart the way the real API tells them apart
  # — by the path segment naming the input fields. `/lines/<word>/...` is the
  # candidate search; `/lines,author/<word>;<poet>/...` is the hydration that
  # usually returns the lines; `/lines,author,linecount/<word>;<poet>;<n>/...`
  # is the one that returns them for anybody.
  defp respond(candidate_body, poems) do
    Req.Test.stub(Poetrydb, fn conn ->
      case Enum.drop(conn.path_info, 1) do
        ["lines", _word, _fields] ->
          Req.Test.json(conn, candidate_body)

        ["lines,author", query, _fields] ->
          case author(query) do
            @unserializable -> Plug.Conn.send_resp(conn, 503, "Application Error")
            author -> Req.Test.json(conn, poems_for(poems, author))
          end

        ["lines,author,linecount", query, _fields] ->
          {author, linecount} = author_and_linecount(query)

          poems
          |> poems_for(author)
          |> narrow(linecount)
          |> then(&Req.Test.json(conn, &1))

        _other ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"status" => 404})
      end
    end)
  end

  # `path_info` arrives as it was written, so the poet's name is still
  # percent-encoded here — the same encoding the provider applied.
  defp author(query) do
    [_word, author | _rest] = query |> URI.decode() |> String.split(";")
    author
  end

  defp author_and_linecount(query) do
    [_word, author, linecount | _rest] = query |> URI.decode() |> String.split(";")
    {author, linecount}
  end

  defp poems_for(poems, author),
    do: Map.get(poems, author, %{"status" => 404, "reason" => "Not found"})

  # The third axis really does narrow: asking for one poet and one length is
  # answered with the poems of that length and nothing else.
  defp narrow(rows, linecount) when is_list(rows),
    do: Enum.filter(rows, &(&1["linecount"] == linecount))

  defp narrow(body, _linecount), do: body
end
