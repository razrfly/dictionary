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
  @swinburne_eve "b36585af05ced49cb4109841bbdbf744"

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
    respond(candidates(6), poems())

    %{
      pages: [
        [@seeger_ode, @seeger_paris],
        [@pope_cecilia, @swinburne_tiresias, @swinburne_eve]
      ]
    }
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
        "author" => "Algernon Charles Swinburne",
        "title" => "The Eve Of Revolution",
        "linecount" => "432"
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
      "Algernon Charles Swinburne" => [
        poem("Algernon Charles Swinburne", "Tiresias", "386", [
          "Which only fate, not force, can bring to nought,",
          "Took then to wife the light of all men's lands,",
          "War's child and love's, most sweet and wise and strong,",
          "Order of things and rule and guiding song.",
          ""
        ]),
        poem("Algernon Charles Swinburne", "The Eve Of Revolution", "432", [
          "The first live light of man",
          "And first-born fire of deeds to burn and leap,",
          "The first war fair as peace",
          "To shine and lighten Greece,",
          "And the first freedom moved upon the deep,"
        ])
      ]
    }
  end

  defp poem(author, title, linecount, lines) do
    %{"author" => author, "title" => title, "linecount" => linecount, "lines" => lines}
  end

  # Two endpoints on one stub, told apart the way the real API tells them apart
  # — by the path segment naming the input fields. `/lines/<word>/...` is the
  # candidate search; `/lines,author/<word>;<poet>/...` is the hydration that
  # can actually return the lines.
  defp respond(candidate_body, poems) do
    Req.Test.stub(Poetrydb, fn conn ->
      case Enum.drop(conn.path_info, 1) do
        ["lines", _word, _fields] ->
          Req.Test.json(conn, candidate_body)

        ["lines,author", query, _fields] ->
          # `path_info` arrives as it was written, so the poet's name is still
          # percent-encoded here — the same encoding the provider applied.
          [_word, author] = query |> URI.decode() |> String.split(";", parts: 2)
          Req.Test.json(conn, Map.get(poems, author, %{"status" => 404, "reason" => "Not found"}))

        _other ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"status" => 404})
      end
    end)
  end
end
