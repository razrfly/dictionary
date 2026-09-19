defmodule DevilsDictionary.Discovery.Providers.OpenLibrary do
  @moduledoc """
  Open Library, matched by attestation — the second text provider, and the
  first one whose attestation is a book.

  PoetryDB proved the shape; this proves it generalises. A book publishes no
  claim about what *war* means, so its evidence is the other kind the README
  names: **attestation**. This work *uses* this word, and the shelf says
  *Uses “war”* over *The Art of War* and never *about war*.

  ## Two stages, because the search and the identity are different indexes

  `search/inside.json` is Open Library's full-text search over the Internet
  Archive's scanned books. It answers with **Internet Archive identifiers**
  (`artofwaroldestmi00suntuoft`) and not with Open Library ids, and the whole
  point of this provider is an `olid` — the identifier the corpus half of this
  phase also keys on, so that a book found live and a book held in the manifest
  are one entity rather than two. So:

    1. `GET /search/inside.json?q=<word>&page=<n>` — the candidate page, with
       the snippets that are the evidence. Twenty documents a page, measured;
       the page size is the source's and is not a parameter.
    2. `GET /search.json?q=ia:(<id> OR <id> …)&fields=key,…` — the crosswalk to
       the work OLID, for the window's candidates and no others.

  Stage 2 is **one request for the whole window**. `ia:` is a queryable field
  and it takes an `OR` group — measured 2026-09-18: three identifiers answered
  in one 546 ms request with the three works. A crosswalk through
  `archive.org/metadata/<id>` also works and was rejected: it is one request
  per candidate and it measured 4.2 s.

  A candidate whose identifier crosses to no Open Library work is **dropped**,
  not guessed at. Measured: `resorttowardatag0000sark` is the first result for
  *war* and `ia:` finds no work for it, even though the Internet Archive's own
  metadata names one. No OLID, no identity, no item — which is the rule the
  README states, applied to the one identifier this provider exists to publish.

  ## The search proposes, the snippet disposes

  Open Library marks the matched token in the snippet with `{{{…}}}`. That
  marker is the *source's* claim and it is not the evidence: the gate is our
  own word-boundary test over the snippet with the markers stripped, which is
  the same gate PoetryDB applies to a poem's lines and the same rule the Met
  applies to a tag. Measured on 2026-09-18, the markers for `war` and for
  `love` were exact tokens in all forty documents and the gate rejected none of
  them — it is here because the marker is the source's word and the OCR
  underneath it is noisy, not because it fired on the day it was written.

  ## The language gate, which is not optional

  `search/inside.json` is language-blind and has no language parameter —
  measured: `q=war AND meta_languageSorter:English` answers zero documents, so
  the filter is ours to apply or not at all. Half of what it returns for *war*
  is German: nine English documents, ten German and one undetermined, on the
  first page on 2026-09-18. German *war* is the past tense of *sein*, and a
  novel using it is not evidence about the English word at all — it is the
  clearest case in the kit of a search's own ranking proposing something that
  is not evidence.

  So a candidate is kept only when the document's own `meta_languageSorter`
  matches the **target's** language, which the mapping already carries. A
  language this module has no name for is not gated, because dropping
  everything is worse than dropping nothing and the table is one line to
  extend; `undetermined` is gated out, because a scan whose language nobody
  could identify is not evidence for a word in a particular one.

  ## What the reason cannot say

  `DevilsDictionary.Discovery.MatchReason` builds an attestation's locator as
  `"line " <> number` and nothing else, so a text provider whose locator is not
  a line number cannot state one. A book's attestation has no line to cite —
  `search/inside.json` returns one `page_num` for five snippets, measured, so
  there is no per-snippet page either — and calling a page a line would be the
  provider lying about the medium to satisfy a renderer. So the locator is left
  empty, the snippet travels as the reason's note, and the shelf shows
  *Uses “war”* beside the card's own title and year. #109 Phase 3c records this
  as a finding against the kit rather than working around it.
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  alias DevilsDictionary.SourceIdentity.Entry

  @adapter_version "open_library.attestation.v1"
  @operation "open_library_attestation"

  @identity_namespace "olid"

  # Measured 2026-09-18: `search/inside.json` answers twenty documents a page
  # whatever else is asked of it. It is the source's page size, not a
  # parameter, and the offset cursor is an offset into that stream.
  @page_size 20

  # The fields the crosswalk asks for. `ia` comes back so the answer can be
  # matched to the candidate that asked for it; `cover_i` is the only cover
  # identifier Open Library publishes here, and it becomes a URL and never
  # bytes.
  @work_fields "key,title,first_publish_year,ia,cover_i,author_name,author_key"

  # How many attested candidates one page hydrates when the pipeline names no
  # limit — the same reasoning as PoetryDB's: a text provider that scanned
  # wider than the page it fills would pay for items it then threw away.
  @default_limit 12

  # Measured, not published. Thirty requests at 500 ms spacing drew no 429, no
  # `Retry-After` and no rising latency; the endpoint's own latency dominates
  # (3.1–8.5 s for `search/inside.json`, 0.5–3.6 s for `search.json`). One
  # second is what a free public service is owed by something that visits it on
  # every word page, not a throttle this provider was forced to.
  @request_interval_ms 1_000

  # Open Library answers an overloaded index with a 5xx after several seconds
  # and no `Retry-After`. Retrying straight back into that buys another
  # timeout.
  @min_retry_interval_ms 5_000

  @impl true
  def slug, do: "open-library"

  @impl true
  def adapter_version, do: @adapter_version

  @doc "The identity namespace one Open Library work is registered under."
  def namespace, do: @identity_namespace

  @doc "How many documents one `search/inside.json` page carries."
  def page_size, do: @page_size

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Open Library",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license:
        "Open Library bibliographic data is CC0; the scanned texts are the Internet Archive's " <>
          "and only a snippet, a cover URL and a link are stored",
      license_url: "https://openlibrary.org/developers/licensing",
      homepage: "https://openlibrary.org/",
      url_template: "https://openlibrary.org/works/{external_id}",
      attribution: "Open Library · Internet Archive",
      active: true,
      config: %{
        "operation" => @operation,
        "match" => "attestation: the work uses the word in its scanned text",
        "verification" => "word-boundary match on the hydrated snippet",
        "identity" => "Open Library work id (OLID), crosswalked from the Internet Archive id"
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
      min_retry_interval_ms: interval(:min_retry_interval_ms, @min_retry_interval_ms),
      request_interval_ms: interval(:request_interval_ms, @request_interval_ms)
    }
  end

  # Overridable for the same reason the Met's and PoetryDB's are: an interval
  # is a live-rate courtesy, and a suite that paid it would spend a second per
  # stubbed request to be polite to a server it never calls.
  defp interval(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> default
    end
  end

  @impl true
  def enabled? do
    config()[:enabled] != false and is_binary(config()[:endpoint])
  end

  @impl true
  def shelf_detail, do: "attested books"

  # No `covers?/1`. The default is `true` and it is the right answer for a text
  # provider matching by attestation: any word can be looked for in a book, and
  # a word no book uses is an empty answer the pipeline caches as a negative.
  #
  # No `mapping_identity/1` either — the recipe is the word and nothing else,
  # so there is no frozen evidence that could move underneath it.

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
  def request_options(%{"endpoint" => "inside", "term" => term, "page" => page}) do
    [
      method: :get,
      url: "#{base()}/search/inside.json",
      params: [q: term, page: to_string(page)],
      headers: headers()
    ]
  end

  def request_options(%{"endpoint" => "works", "ia_ids" => ia_ids}) do
    [
      method: :get,
      url: "#{base()}/search.json",
      params: [q: ia_query(ia_ids), fields: @work_fields, limit: to_string(length(ia_ids))],
      headers: headers()
    ]
  end

  # `ia:(a OR b OR c)`. The identifiers are Open Library's own — lowercase
  # letters, digits and underscores — so they carry no Lucene operator, but the
  # group is built rather than interpolated so that an identifier which ever
  # does is dropped instead of rewriting the query.
  defp ia_query(ia_ids) do
    "ia:(" <> (ia_ids |> Enum.filter(&safe_ia_id?/1) |> Enum.join(" OR ")) <> ")"
  end

  defp safe_ia_id?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value)

  defp base, do: config()[:endpoint] |> to_string() |> String.trim_trailing("/")

  defp headers do
    # Open Library asks that a script identify itself with a way to reach its
    # author. The shared line already carries one.
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      term = mapping["term"]
      limit = limit(request)
      offset = offset(request["after"])
      page = div(offset, @page_size) + 1
      within = rem(offset, @page_size)

      case request_fun.("candidates:#{page}", %{
             "endpoint" => "inside",
             "term" => term,
             "page" => page
           }) do
        {:ok, body} ->
          case candidates(body) do
            {:ok, docs} ->
              window(term, mapping["language"], request, docs, offset, within, limit, request_fun)

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

  @doc """
  The candidate documents of one `search/inside.json` page.

  A word no scanned book uses answers `200` with an empty `hits.hits`, which is
  an empty result and not a failure — the pipeline caches it as a negative.
  """
  def candidates(%{"hits" => %{"hits" => docs}}) when is_list(docs) do
    {:ok, Enum.flat_map(docs, &candidate/1)}
  end

  def candidates(%{"hits" => _hits}), do: {:ok, []}
  def candidates(_body), do: :error

  # `fields` values arrive as one-element lists, which is the Elasticsearch
  # envelope Open Library passes through rather than a list of anything.
  defp candidate(%{"fields" => fields} = doc) when is_map(fields) do
    case first(fields["identifier"]) do
      nil ->
        []

      ia_id ->
        [
          %{
            ia_id: ia_id,
            title: presence(first(fields["meta_title"])),
            year: year(first(fields["meta_year"])),
            creator: presence(first(fields["meta_creator"])),
            language: presence(first(fields["meta_languageSorter"])),
            snippets: snippets(doc)
          }
        ]
    end
  end

  defp candidate(_doc), do: []

  defp snippets(doc) do
    doc
    |> get_in(["highlight", "text"])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  # The window is an offset into the candidate *stream*, not a page number, so
  # a `first` smaller than the source's page size advances by what it actually
  # consumed and the next run resumes inside the same page rather than skipping
  # the rest of it.
  defp window(term, language, request, docs, offset, within, limit, request_fun) do
    {attested, consumed} = attest_window(term, language, Enum.drop(docs, within), limit)

    if attested == [] do
      next_offset = offset + max(consumed, length(docs) - within)

      # A full page on which every candidate failed the gate is not the end of
      # the search: the next page may attest. Only a short page — the API's
      # own last page — ends pagination. Without the cursor the pipeline
      # caches this as a negative and never asks again (CodeRabbit on #121).
      next_cursor = if length(docs) == @page_size, do: Integer.to_string(next_offset)

      {:ok, empty(request, next_offset, length(docs), next_cursor)}
    else
      hydrate(term, request, attested, docs, offset, within, consumed, request_fun)
    end
  end

  # Walks the page in order, keeping the candidates whose own snippet shows the
  # term at a word boundary, and counting every candidate it looked at — the
  # count is the cursor's unit, so a rejected candidate is still consumed.
  defp attest_window(term, language, docs, limit) do
    pattern = word_pattern(term)
    expected = language_name(language)

    {kept, consumed, _} =
      Enum.reduce_while(docs, {[], 0, 0}, fn doc, {kept, consumed, taken} ->
        if taken >= limit do
          {:halt, {kept, consumed, taken}}
        else
          with true <- in_language?(doc.language, expected),
               snippet when is_binary(snippet) <- first_attestation(pattern, doc.snippets) do
            {:cont, {[{doc, snippet} | kept], consumed + 1, taken + 1}}
          else
            _ -> {:cont, {kept, consumed + 1, taken}}
          end
        end
      end)

    {Enum.reverse(kept), consumed}
  end

  # The Internet Archive writes a language *name* into `meta_languageSorter`,
  # not a code, so the target's tag has to be named before it can be compared.
  # One line per language the encyclopedia serves; a tag that is not here is
  # not gated, which is stated in the moduledoc rather than inferred from a
  # missing clause.
  @language_names %{"en" => "English"}

  @doc "The Internet Archive's own name for a language tag, or `nil`."
  def language_name(tag) when is_binary(tag) do
    Map.get(@language_names, tag |> String.trim() |> String.downcase() |> String.slice(0, 2))
  end

  def language_name(_tag), do: nil

  @doc """
  Whether a document's language is the one the target asked for.

  `true` when the provider has no name for the target's language — see the
  moduledoc. `false` for a document whose own language is missing or
  `undetermined`, once a name *is* known.
  """
  def in_language?(_document_language, nil), do: true
  def in_language?(document_language, expected), do: document_language == expected

  @doc """
  The first snippet that uses `term` as a word, with its markers stripped.

  Open Library wraps the matched token in `{{{…}}}`. The markers are removed
  *before* the test, so a marker sitting inside a longer word — which OCR and a
  hyphenated line break can both produce — is judged on the word it is actually
  part of rather than on the source's say-so.
  """
  def first_attestation(pattern, snippets) when is_list(snippets) do
    Enum.find_value(snippets, fn snippet ->
      plain = strip_markers(snippet)
      Regex.match?(pattern, plain) and plain
    end)
  end

  def first_attestation(_pattern, _snippets), do: nil

  @doc "A snippet with Open Library's highlight markers removed and its whitespace collapsed."
  def strip_markers(snippet) do
    snippet
    |> String.replace("{{{", "")
    |> String.replace("}}}", "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  The word-boundary pattern one term is attested by.

  Unicode boundaries rather than `\\b`, which treats an apostrophe as a
  boundary and would find *war* inside *war's* but also inside a hyphenated
  form nobody wrote. This is the same rule
  `DevilsDictionary.Discovery.Providers.Poetrydb` applies to a poem's lines.
  """
  def word_pattern(term) do
    escaped = Regex.escape(String.trim(term))
    Regex.compile!("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu")
  end

  defp empty(request, next_offset, scanned, next_cursor) do
    %{
      request_parameters: request_parameters(request, next_offset, scanned, 0),
      items: [],
      next_cursor: next_cursor,
      completion_reason: :no_results
    }
  end

  defp request_parameters(request, offset, scanned, attested) do
    request
    |> Map.put("offset", Integer.to_string(offset))
    |> Map.put("scanned", scanned)
    |> Map.put("attested", attested)
  end

  defp hydrate(term, request, attested, docs, offset, within, consumed, request_fun) do
    ia_ids = Enum.map(attested, fn {doc, _snippet} -> doc.ia_id end)

    case request_fun.("works", %{"endpoint" => "works", "ia_ids" => ia_ids}) do
      {:ok, body} ->
        works = works(body)

        items =
          attested
          |> Enum.flat_map(fn {doc, snippet} ->
            case Map.get(works, doc.ia_id) do
              nil -> []
              work -> [item(term, doc, work, snippet)]
            end
          end)
          |> Enum.uniq_by(& &1.external_id)
          |> Enum.with_index(&Map.put(&1, :position, &2))

        next_offset = offset + consumed
        exhausted? = within + consumed >= length(docs)

        {:ok,
         %{
           request_parameters:
             request_parameters(request, next_offset, consumed, length(attested)),
           items: items,
           next_cursor:
             if(not exhausted? or length(docs) == @page_size,
               do: Integer.to_string(next_offset)
             ),
           completion_reason: if(items == [], do: :no_results, else: :results)
         }}

      {:error, code} ->
        {:error, code}

      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}
    end
  end

  # The crosswalk's answer, indexed by every Internet Archive identifier the
  # work carries — the query asked for a group and the answer does not say
  # which identifier matched which work, so the work is filed under all of
  # them and the candidate that asked finds its own.
  defp works(%{"docs" => docs}) when is_list(docs) do
    Enum.reduce(docs, %{}, fn doc, index ->
      case olid(doc["key"]) do
        nil ->
          index

        olid ->
          work = %{
            olid: olid,
            title: presence(doc["title"]),
            year: year(doc["first_publish_year"]),
            cover_id: doc["cover_i"],
            authors: doc["author_name"] |> List.wrap() |> Enum.filter(&is_binary/1)
          }

          doc["ia"]
          |> List.wrap()
          |> Enum.filter(&is_binary/1)
          |> Enum.reduce(index, &Map.put_new(&2, &1, work))
      end
    end)
  end

  defp works(_body), do: %{}

  @doc "The work OLID in an Open Library search key, or `nil` for anything else."
  def olid(key) when is_binary(key) do
    case Regex.run(~r{\A/works/(OL[1-9]\d*[AMW])\z}, key) do
      [_, olid] -> olid
      _ -> nil
    end
  end

  def olid(_key), do: nil

  defp item(term, doc, work, snippet) do
    title = work.title || doc.title || work.olid
    year = work.year || doc.year
    author = List.first(work.authors) || doc.creator

    %{
      external_namespace: @identity_namespace,
      external_id: work.olid,
      identifiers: [
        %{
          namespace: @identity_namespace,
          external_id: work.olid,
          metadata: %{"field" => "key", "ia" => doc.ia_id}
        }
      ],
      position: 0,
      # `"lines"` is what `MatchReason` reads an attestation from. The number is
      # `nil` deliberately: see the moduledoc — a book's snippet has no line to
      # cite and the shared renderer would print whatever went here as one.
      match_details: %{
        "kind" => "attestation",
        "query" => term,
        "lines" => [%{"number" => nil, "text" => snippet}],
        "olid" => work.olid,
        "ia" => doc.ia_id
      },
      preview_metadata:
        %{
          "title" => label(title),
          "year" => year,
          "artist" => author,
          "author" => author,
          "snippet" => snippet,
          "source_url" => "https://openlibrary.org/works/#{work.olid}",
          "read_url" => "https://archive.org/details/#{doc.ia_id}",
          "cover_url" => cover_url(work.cover_id),
          "content_type" => "text",
          "provider" => "Open Library"
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      display_allowed: true
    }
  end

  @doc """
  The cover URL for an Open Library cover id, or `nil`.

  A URL and never bytes — the probe downloaded no image. It is recorded rather
  than rendered: the `:text` content type has no image slot at all, which is
  why a text result shows a title instead of an empty poster frame.
  """
  def cover_url(cover_id) when is_integer(cover_id),
    do: "https://covers.openlibrary.org/b/id/#{cover_id}-M.jpg"

  def cover_url(_cover_id), do: nil

  # `entities.preferred_label` is varchar(255) and Postgres counts characters.
  # Scanned-book titles reach it: the first result for *war* is 96 characters
  # and subtitles run much longer.
  defp label(title), do: String.slice(to_string(title), 0, 255)

  @impl DevilsDictionary.SourceIdentity.Adapter
  def identity_record(%{external_namespace: @identity_namespace, external_id: olid} = item) do
    metadata = item.preview_metadata

    Entry.new(%{
      source_slug: slug(),
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "book",
      stable_identifier: %{namespace: @identity_namespace, external_id: olid},
      identifiers: Map.get(item, :identifiers, []),
      label: metadata["title"],
      year: metadata["year"],
      metadata:
        %{
          "content_type" => "text",
          "catalog_source" => "open-library",
          "source_url" => metadata["source_url"]
        }
        |> put_present("author_display_name", metadata["author"])
        |> put_present("cover_url", metadata["cover_url"])
        |> put_present("read_url", metadata["read_url"]),
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported_open_library_identity}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp offset(nil), do: 0

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  defp offset(_value), do: 0

  defp first([value | _rest]), do: value
  defp first(value) when is_list(value), do: nil
  defp first(value), do: value

  defp year(value) when is_integer(value), do: value

  defp year(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {year, _rest} -> year
      _ -> nil
    end
  end

  defp year(_value), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:devils_dictionary, :open_library, [])
end
