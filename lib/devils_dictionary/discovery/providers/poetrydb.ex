defmodule DevilsDictionary.Discovery.Providers.Poetrydb do
  @moduledoc """
  PoetryDB, matched by attestation — the exception that proves the one rule.

  Every other provider keeps a candidate because an identifier it publishes
  equals an identifier the encyclopedia already asserts: a TMDb keyword id, a
  Wikidata QID on a Met subject tag, an Artsy gene. A poem publishes no such
  claim. It has no opinion about what *war* means and it is not tagged with
  Q198. So its evidence is the other kind the README names: **attestation**.
  This work *uses* this word, at this line, and the shelf says
  *Uses “war” at line 16* and never *about war*.

  The one identity a poem does carry is its author's, and that is why the
  corpus manifest holds a Wikidata QID per author where a rule could name one
  — `DevilsDictionary.Artworks.Corpus.Poetrydb` writes the crosswalk and
  `Corpus.Seeder` writes it onto the seeded poem. A live result carries the
  poet's name; it does not invent the poet's QID.

  ## Two stages, because the API cannot answer in one

  `/lines/<word>` is the attestation search. Asking it for the `lines` output
  field returns a 503 **every time** — measured at 25 results and at 1,026,
  so it is not a volume limit but the endpoint itself (see
  `docs/integrations/poetrydb.md`). The lines are what the reason is made of,
  so they have to come from somewhere else:

    1. `/lines/<word>/title,author,linecount` — the candidate list. One
       request, whatever the page.
    2. `/lines,author/<word>;<author>/title,author,linecount,lines` — the same
       search narrowed to one poet, which *does* return the lines. One request
       per distinct poet in the page's window.

  The narrowing is by **author** and never by title, and that is a measured
  constraint rather than a preference: `:` `;` and `/` are PoetryDB's own
  operators, 434 of the 2,526 titles contain one, and **no** author name does.
  A title-keyed hydration would be broken for one poem in six.

  ## The search proposes, the lines dispose

  PoetryDB's `/lines` match is a substring match: `/lines/war` answers 1,026
  poems, of which only 201 contain *war* as a word — the rest are *warm*,
  *toward*, *wary*. A shelf built on that count would say *Uses “war” at line
  4* over a line reading "her warm hand". So the search generates candidates
  and nothing else, and an item is kept only when the hydrated lines contain
  the term at a word boundary. That is the same shape as the Met's tag gate,
  asked of text: the query is never the evidence.
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  alias DevilsDictionary.SourceIdentity.Entry

  @adapter_version "poetrydb.attestation.v1"
  @operation "poetrydb_attestation"

  @candidate_fields "title,author,linecount"
  @poem_fields "title,author,linecount,lines"

  # How many candidates one page hydrates when the pipeline names no limit.
  # `request["first"]` is `:result_limit`, and the window is that and not a
  # number of this module's own: a text provider that scanned wider than the
  # page it fills would pay for items it then threw away.
  @default_limit 12

  # Measured, not published. 127 author fetches at 300 ms spacing drew no
  # throttle of any kind — no 429, no `Retry-After`, no rising latency. The two
  # failures in that run were oversized-payload 503s and would have happened at
  # any rate. 1 s is therefore not a throttle this provider was forced to; it is
  # what a free, single-dyno public service is owed by something that visits it
  # on every word page.
  @request_interval_ms 1_000

  # A 503 here is usually the response the app could not finish building, and
  # it arrives after ~16 s with no `Retry-After`. Retrying straight into that
  # buys another 16 s timeout, so the gap after a failure is deliberately long.
  @min_retry_interval_ms 5_000

  @impl true
  def slug, do: "poetrydb"

  @impl true
  def adapter_version, do: @adapter_version

  @doc "The identity namespace one poem is registered under."
  def namespace, do: "poetrydb_poem"

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "PoetryDB",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Public domain poetry; API under MIT",
      license_url: "https://github.com/thundercomb/poetrydb/blob/master/LICENSE",
      homepage: "https://poetrydb.org/",
      attribution: "PoetryDB",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "attestation: the work uses the word at a line",
        "verification" => "word-boundary match on the hydrated lines",
        "author_identity" => "Wikidata QID crosswalk, corpus manifest only"
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :persistent,
      pagination: :offset,
      operations: [@operation],
      content_types: [:text],
      min_retry_interval_ms: @min_retry_interval_ms,
      request_interval_ms: request_interval_ms()
    }
  end

  defp request_interval_ms do
    case config()[:request_interval_ms] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @request_interval_ms
    end
  end

  @impl true
  def enabled? do
    config()[:enabled] != false and is_binary(config()[:endpoint])
  end

  @impl true
  def shelf_detail, do: "attested lines"

  # No `covers?/1`. The default is `true` and it is the right answer: unlike the
  # Met, this provider needs no prior claim from the encyclopedia — any word can
  # be looked for in a line, and a word no poem uses is an empty answer, which
  # the pipeline caches as a negative rather than treating as a failure.
  #
  # No `mapping_identity/1` either. The recipe is the word and nothing else, so
  # there is no frozen evidence that could move underneath it.

  @impl true
  def automatic_mapping(target) do
    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "attestation_v1"
     }}
  end

  @impl true
  def validate_mapping(@operation, %{"term" => term, "resolution_strategy" => "attestation_v1"})
      when is_binary(term) and byte_size(term) > 0 and byte_size(term) <= 100,
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  @impl true
  def request_options(%{"endpoint" => "candidates", "term" => term}) do
    [
      method: :get,
      url: "#{base()}/lines/#{segment(term)}/#{@candidate_fields}",
      headers: headers()
    ]
  end

  def request_options(%{"endpoint" => "poems", "term" => term, "author" => author}) do
    [
      method: :get,
      url: "#{base()}/lines,author/#{segment(term)};#{segment(author)}/#{@poem_fields}",
      headers: headers()
    ]
  end

  defp base, do: config()[:endpoint] |> to_string() |> String.trim_trailing("/")

  # PoetryDB reads its operators out of the path, so every value that goes into
  # one is percent-encoded down to the unreserved set. A poet called
  # "Major Henry Livingston, Jr." is one comma away from a query that means
  # something else.
  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      term = mapping["term"]
      limit = limit(request)
      offset = offset(request["after"])

      case request_fun.("candidates", %{"endpoint" => "candidates", "term" => term}) do
        {:ok, body} ->
          case candidates(body) do
            {:ok, []} ->
              {:ok, empty(request, offset, 0)}

            {:ok, all} ->
              hydrate(term, request, all, offset, limit, request_fun)

            :error ->
              {:error, "malformed_response"}
          end

        {:error, code} ->
          {:error, code}

        {:deferred, code, seconds} ->
          {:deferred, code, seconds, request}
      end
    else
      {:error, _reason} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  defp limit(request) do
    case request["first"] do
      first when is_integer(first) and first > 0 -> first
      _ -> @default_limit
    end
  end

  # A word no poem uses answers `200` with `{"status": 404, "reason": "Not
  # found"}` in the body — PoetryDB's dialect for an empty result, not an error
  # and not a malformed response. Treating the status line as the answer would
  # turn every unattested word into a provider failure and a backoff.
  defp candidates(%{"status" => 404}), do: {:ok, []}

  defp candidates(rows) when is_list(rows) do
    {:ok,
     rows
     |> Enum.filter(&(is_map(&1) and present?(&1["title"]) and present?(&1["author"])))
     |> Enum.map(&%{title: String.trim(&1["title"]), author: String.trim(&1["author"])})
     |> Enum.uniq()}
  end

  defp candidates(_body), do: :error

  defp empty(request, offset, total) do
    %{
      request_parameters: request_parameters(request, offset, 0, total),
      items: [],
      next_cursor: nil,
      completion_reason: :no_results
    }
  end

  defp request_parameters(request, offset, scanned, total) do
    request
    |> Map.put("offset", Integer.to_string(offset))
    |> Map.put("scanned", scanned)
    |> Map.put("candidates", total)
  end

  defp hydrate(term, request, all, offset, limit, request_fun) do
    window = Enum.slice(all, offset, limit)
    authors = window |> Enum.map(& &1.author) |> Enum.uniq()

    case fetch_authors(term, authors, request_fun, %{}) do
      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}

      {:ok, poems} ->
        items =
          window
          |> Enum.flat_map(&attest(term, &1, poems))
          |> Enum.uniq_by(& &1.external_id)
          |> Enum.with_index(&Map.put(&1, :position, &2))

        {:ok,
         %{
           request_parameters: request_parameters(request, offset, length(window), length(all)),
           items: items,
           next_cursor: if(offset + limit < length(all), do: Integer.to_string(offset + limit)),
           completion_reason: if(items == [], do: :no_results, else: :results)
         }}
    end
  end

  # One poet at a time, each with its own stage name. The stage is the retry
  # ladder's key, so sharing one across a window's poets would spend the whole
  # page's attempts on the third of them. A poet whose fetch will not come back
  # is dropped and the page is still a page without them.
  defp fetch_authors(_term, [], _request_fun, acc), do: {:ok, acc}

  defp fetch_authors(term, [author | rest], request_fun, acc) do
    payload = %{"endpoint" => "poems", "term" => term, "author" => author}

    case request_fun.("poems:#{author}", payload) do
      {:ok, rows} when is_list(rows) ->
        fetch_authors(term, rest, request_fun, Map.put(acc, author, index_poems(rows)))

      {:ok, _body} ->
        fetch_authors(term, rest, request_fun, acc)

      {:error, _code} ->
        fetch_authors(term, rest, request_fun, acc)

      {:deferred, code, seconds} ->
        {:deferred, code, seconds}
    end
  end

  defp index_poems(rows) do
    rows
    |> Enum.filter(&(is_map(&1) and present?(&1["title"]) and is_list(&1["lines"])))
    |> Enum.into(%{}, &{String.trim(&1["title"]), &1})
  end

  # The gate. A candidate becomes an item only when the poet's own text shows
  # the term at a word boundary; the substring the search matched on is not
  # evidence and never reaches the shelf.
  defp attest(term, %{title: title, author: author}, poems) do
    with %{} = by_title <- Map.get(poems, author),
         %{"lines" => lines} = poem <- Map.get(by_title, title),
         {number, text} <- first_attestation(term, lines) do
      [item(term, author, title, poem, lines, number, text)]
    else
      _ -> []
    end
  end

  @doc """
  The first line that uses `term` as a word, as `{line number, line text}`.

  The number is a 1-based index into the `lines` array **as the API returns
  it**, blank stanza separators included, because that array is the only thing
  a reader can count against. PoetryDB's own `linecount` field is a different
  number — it counts non-blank lines, and disagrees with `length(lines)` for
  1,694 of the 2,526 poems measured — so it is recorded as the source's claim
  and never used to locate anything.
  """
  def first_attestation(term, lines) when is_list(lines) do
    pattern = word_pattern(term)

    lines
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, number} ->
      is_binary(line) and Regex.match?(pattern, line) and {number, String.trim(line)}
    end)
  end

  def first_attestation(_term, _lines), do: nil

  # Word boundary in the Unicode sense rather than `\b`, which treats an
  # apostrophe as a boundary and would find *war* inside *war's* but also
  # inside a hyphenated form the poet did not write.
  defp word_pattern(term) do
    escaped = Regex.escape(String.trim(term))
    Regex.compile!("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu")
  end

  defp item(term, author, title, poem, lines, number, text) do
    external_id = poem_id(author, title, lines)

    %{
      external_namespace: namespace(),
      external_id: external_id,
      identifiers: [
        %{
          namespace: namespace(),
          external_id: external_id,
          metadata: %{"field" => "author+title+lines"}
        }
      ],
      position: 0,
      match_details: %{
        "kind" => "attestation",
        "query" => term,
        "lines" => [%{"number" => number, "text" => text}]
      },
      preview_metadata: %{
        "title" => label(title),
        "artist" => author,
        "author" => author,
        "line_count" => length(lines),
        "source_line_count" => poem["linecount"],
        "source_url" => source_url(author),
        "content_type" => "text",
        "provider" => "PoetryDB"
      },
      display_allowed: true
    }
  end

  @doc """
  The stable identity of one poem: its poet, its title and its text.

  PoetryDB publishes no id. Poet and title alone are not one either — 18 pairs
  in the 2,526 poems measured are used twice — so the text is part of the key,
  which is also the lines hash the corpus manifest records. The cost is stated
  rather than hidden: a poem whose text is corrected upstream becomes a new
  identity, and the old one is left behind for the retirement path rather than
  silently rewritten.
  """
  def poem_id(author, title, lines) do
    [String.trim(to_string(author)), String.trim(to_string(title)), Enum.join(lines, "\n")]
    |> Enum.join("\n ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc "The full digest of a poem's lines, recorded by the corpus manifest."
  def lines_hash(lines) do
    lines |> Enum.join("\n") |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  # PoetryDB serves no page for a poem, so the citable locator is the query that
  # returns it. It is keyed on the poet for the same reason the hydration is:
  # a title may carry the API's own operators and an author name may not.
  defp source_url(author) do
    "https://poetrydb.org/author/#{segment(author)}/#{@poem_fields}"
  end

  # `entities.preferred_label` is varchar(255) and Postgres counts characters.
  # The longest title measured is 127, so this clamp has never fired — it is
  # here because the column is the constraint and the corpus can grow.
  defp label(title), do: String.slice(title, 0, 255)

  @impl DevilsDictionary.SourceIdentity.Adapter
  def identity_record(%{external_namespace: "poetrydb_poem", external_id: poem_id} = item) do
    metadata = item.preview_metadata

    Entry.new(%{
      source_slug: slug(),
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "poem",
      stable_identifier: %{namespace: namespace(), external_id: poem_id},
      identifiers: Map.get(item, :identifiers, []),
      label: metadata["title"],
      metadata: %{
        "content_type" => "text",
        "author_display_name" => metadata["author"],
        "line_count" => metadata["line_count"],
        "source_url" => metadata["source_url"],
        "catalog_source" => "poetrydb"
      },
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported_poetrydb_identity}

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp config, do: Application.get_env(:devils_dictionary, :poetrydb, [])
end
