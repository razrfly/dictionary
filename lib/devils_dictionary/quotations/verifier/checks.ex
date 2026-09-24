defmodule DevilsDictionary.Quotations.Verifier.Checks do
  @moduledoc """
  The three checks the spike kept (#158 build 5, `docs/integrations/verifier.md`),
  each reaching its evidence by an identifier:

    * **the author's own Wikiquote page** — the person's QID → its
      `enwikiquote` sitelink → the page, read by build 4a's parser. A line on
      it under a cited work or year *supports* the credit; a line in its
      *Misattributed* / *Disputed* / *Unsourced* register *contradicts* it.
    * ***Misquotations*** — one Wikiquote page for every line; a row there
      *contradicts*.
    * **Gutenberg** — the person's QID → the works Wikidata says they wrote
      (`P50`) that carry a Gutenberg ebook id (`P2034`) → each text, fetched
      once. The line inside one of them is a *primary* agreement, at a line.

  A line matches an item when their fingerprints are equal (ADR 0003), or when
  the line, normalised, is **contained** in the item — "So it goes" inside a
  longer passage Wikiquote cites to *Slaughterhouse-Five*. Containment is
  asked only of lines of three words or more and only on the credited author's
  own page or text, never across the web. No name is compared anywhere.

  Fetching goes through `Verifier.Fetch` (budgeted, ledgered, cached);
  matching is pure.
  """

  alias DevilsDictionary.Absorb.Clients.Wikidata, as: WikidataClient
  alias DevilsDictionary.Discovery.Providers.Wikiquote.Parser
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Quotations.Verifier.Fetch

  @site "enwikiquote"
  @day 86_400
  @min_words 3

  # ── fetching ────────────────────────────────────────────────────────────

  @doc "The person's own Wikiquote page, parsed, or `{:ok, nil}` when they have none."
  def author_page(run, qid, max_age) do
    with {:ok, %{"title" => title}, _rev} when is_binary(title) <- sitelink(run, qid, max_age) do
      page(run, title, max_age)
    else
      {:ok, _no_title, _rev} -> {:ok, nil}
      other -> other
    end
  end

  @doc """
  The *Misquotations* page, parsed — every row of it register. Its sections are
  *Misquoted or misattributed*, *Commonly misquoted* and *Unsourced*, and only
  the last starts with a word the parser reads as register; on this page a
  row's being there at all is the finding, so none of them may support a line.
  """
  def misquotations(run, max_age) do
    with {:ok, page} <- page(run, "Misquotations", max_age) do
      {:ok,
       Map.update(page, "items", [], fn items ->
         Enum.map(items, &Map.put(&1, "register", &1["register"] || "misquoted"))
       end)}
    end
  end

  defp sitelink(run, qid, max_age) do
    Fetch.cached(
      "wikidata",
      "enwikiquote-sitelink:#{qid}",
      max_age,
      "https://www.wikidata.org/wiki/#{qid}",
      fn ->
        case Fetch.get(run, "wikidata", "verifier:sitelink",
               url: wikidata_api(),
               params: WikidataClient.sitelink_params([qid], @site)
             ) do
          {:ok, body} when is_map(body) ->
            {:ok,
             %{"qid" => qid, "title" => Map.get(WikidataClient.sitelink_titles(body, @site), qid)}}

          {:ok, _other} ->
            {:ok, %{"qid" => qid, "title" => nil}}

          other ->
            other
        end
      end
    )
  end

  defp page(run, title, max_age) do
    path = title |> String.replace(" ", "_") |> URI.encode(&URI.char_unreserved?/1)

    result =
      Fetch.cached(
        "wikiquote",
        "verifier-page:#{title}",
        max_age,
        "https://en.wikiquote.org/wiki/#{path}",
        fn ->
          case Fetch.get(run, "wikiquote", "verifier:page",
                 url: wikiquote_endpoint() <> path,
                 decode_body: false
               ) do
            {:ok, :absent} -> {:ok, %{"title" => title, "absent" => true, "items" => []}}
            {:ok, html} when is_binary(html) -> {:ok, compact(Parser.parse(html), title)}
            other -> other
          end
        end
      )

    case result do
      {:ok, payload, revision_id} -> {:ok, Map.put(payload, "record_revision_id", revision_id)}
      other -> other
    end
  end

  # What a check reads of a page, and nothing more: the words, the citation,
  # where it sits and whether it is register.
  defp compact(page, title) do
    %{
      "title" => page.title || title,
      "revision_id" => page.revision_id,
      "items" =>
        Enum.map(page.quotations ++ page.register, fn item ->
          %{
            "text" => item.text,
            "citation" => item.citation,
            "work" => item.work,
            "year" => item.year,
            "section" => item.section,
            "subsection" => item.subsection,
            "position" => item.position,
            "register" => item.register && Atom.to_string(item.register)
          }
        end)
    }
  end

  @doc "The Gutenberg texts of the works Wikidata says this person wrote."
  def gutenberg_texts(run, qid, max_age) do
    with {:ok, %{"works" => works}, _rev} <- gutenberg_works(run, qid, max_age) do
      Enum.reduce_while(works, {:ok, []}, fn work, {:ok, acc} ->
        case gutenberg_text(run, work) do
          {:ok, text} -> {:cont, {:ok, [text | acc]}}
          other -> {:halt, other}
        end
      end)
      |> case do
        {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.reject(&is_nil/1)}
        other -> other
      end
    end
  end

  defp gutenberg_works(run, qid, max_age) do
    query = """
    SELECT ?work ?workLabel ?pg WHERE { ?work wdt:P50 wd:#{qid} ; wdt:P2034 ?pg .
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } }
    """

    Fetch.cached(
      "wikidata",
      "gutenberg-works:#{qid}",
      max_age,
      "https://www.wikidata.org/wiki/#{qid}",
      fn ->
        case Fetch.get(run, "wikidata", "verifier:works",
               url: sparql_endpoint(),
               params: [query: query, format: "json"],
               headers: [{"accept", "application/sparql-results+json"}]
             ) do
          {:ok, body} when is_map(body) ->
            {:ok, %{"qid" => qid, "works" => works(body)}}

          {:ok, body} when is_binary(body) ->
            {:ok, %{"qid" => qid, "works" => works(Jason.decode!(body))}}

          {:ok, :absent} ->
            {:ok, %{"qid" => qid, "works" => []}}

          other ->
            other
        end
      end
    )
  end

  defp works(%{"results" => %{"bindings" => bindings}}) do
    bindings
    |> Enum.flat_map(fn binding ->
      with %{"value" => "http://www.wikidata.org/entity/" <> qid} <- binding["work"],
           %{"value" => ebook} <- binding["pg"],
           true <- Regex.match?(~r/\A\d+\z/, ebook) do
        [%{"qid" => qid, "label" => get_in(binding, ["workLabel", "value"]), "ebook" => ebook}]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1["ebook"])
  end

  defp works(_body), do: []

  # A Gutenberg text is a fixed file: fetched once and kept for years.
  defp gutenberg_text(run, %{"ebook" => ebook} = work) do
    url = "https://www.gutenberg.org/ebooks/#{ebook}"

    result =
      Fetch.cached("gutenberg", "pg#{ebook}", 3650 * @day, url, fn ->
        case Fetch.get(run, "gutenberg", "verifier:text",
               url: gutenberg_text_url(ebook),
               decode_body: false
             ) do
          {:ok, text} when is_binary(text) ->
            {:ok,
             %{
               "ebook" => ebook,
               "work_qid" => work["qid"],
               "label" => work["label"],
               "text" => text
             }}

          {:ok, :absent} ->
            {:ok,
             %{
               "ebook" => ebook,
               "work_qid" => work["qid"],
               "label" => work["label"],
               "text" => nil
             }}

          other ->
            other
        end
      end)

    case result do
      {:ok, %{"text" => nil}, _rev} ->
        {:ok, nil}

      {:ok, payload, revision_id} ->
        {:ok,
         %{
           ebook: payload["ebook"],
           label: payload["label"],
           revision_id: revision_id,
           lines: String.split(payload["text"], ~r/\r?\n/),
           normalised: Fingerprint.normalise(payload["text"])
         }}

      other ->
        other
    end
  end

  # ── matching (pure) ─────────────────────────────────────────────────────

  @doc """
  What a page says about one line: a `:cited` finding for each cited item the
  line is (or is inside), a `:register` contradiction for each register row.
  """
  def match_page(nil, _line, _source), do: []

  def match_page(%{"items" => items} = page, line, source) do
    for item <- items, matches?(line, item["text"]) do
      locator =
        [page["title"], item["section"], item["subsection"], "##{item["position"]}"]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" › ")

      if item["register"] do
        %{
          source: source,
          kind: :register,
          role: :contradicts,
          note: item["citation"],
          locator: locator,
          record_revision_id: page["record_revision_id"]
        }
      else
        %{
          source: source,
          kind: :cited,
          role: :supports,
          work: item["work"],
          year: item["year"],
          locator: locator,
          record_revision_id: page["record_revision_id"],
          cited?:
            is_binary(item["citation"]) or is_binary(item["work"]) or is_integer(item["year"])
        }
      end
    end
    # Only a cited item supports: an uncited line on the page is not a claim.
    |> Enum.filter(&(&1.kind == :register or &1.cited?))
    |> Enum.map(&Map.delete(&1, :cited?))
  end

  @doc "A `:primary` finding for the first text the line is in, at its line."
  def match_texts(texts, line) do
    normalised = Fingerprint.normalise(line)

    if long_enough?(normalised) do
      Enum.find_value(texts, [], fn text ->
        if String.contains?(text.normalised, normalised) do
          [
            %{
              source: "gutenberg",
              kind: :primary,
              role: :supports,
              locator:
                "#{text.label || "Gutenberg"} (Gutenberg ##{text.ebook}), line #{line_number(text.lines, normalised)}",
              record_revision_id: text.revision_id
            }
          ]
        end
      end)
    else
      []
    end
  end

  defp matches?(line, text) when is_binary(line) and is_binary(text) do
    a = Fingerprint.normalise(line)
    b = Fingerprint.normalise(text)
    a != "" and (a == b or (long_enough?(a) and String.contains?(b, a)))
  end

  defp matches?(_line, _text), do: false

  defp long_enough?(normalised),
    do: length(String.split(normalised, " ", trim: true)) >= @min_words

  # The line a match starts on, reading three lines at a time so a sentence
  # wrapped across a line break is still found.
  defp line_number(lines, normalised) do
    windows = Enum.chunk_every(lines, 3, 1)

    case Enum.find_index(windows, &contains?(&1, normalised)) do
      nil ->
        "?"

      index ->
        # The window that first holds the line may start a line or two before
        # it; the line it starts on is the latest start that still holds it.
        window = Enum.at(windows, index)
        start = Enum.find(2..0//-1, 0, &contains?(Enum.drop(window, &1), normalised))
        index + start + 1
    end
  end

  defp contains?(lines, normalised),
    do: String.contains?(Fingerprint.normalise(Enum.join(lines, " ")), normalised)

  defp config, do: Application.get_env(:devils_dictionary, :verification, [])
  defp wikidata_api, do: config()[:wikidata_endpoint] || WikidataClient.api_url()
  defp sparql_endpoint, do: config()[:sparql_endpoint] || "https://query.wikidata.org/sparql"

  defp wikiquote_endpoint,
    do: config()[:wikiquote_endpoint] || "https://en.wikiquote.org/api/rest_v1/page/html/"

  defp gutenberg_text_url(ebook) do
    base = config()[:gutenberg_endpoint] || "https://www.gutenberg.org/cache/epub/"
    "#{base}#{ebook}/pg#{ebook}.txt"
  end
end
