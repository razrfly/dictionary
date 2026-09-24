defmodule DevilsDictionary.Discovery.Providers.Wikiquote do
  @moduledoc """
  Wikiquote theme pages on the Quotes shelf, with the misattribution register
  applied from the first run (#158 build 4). The first provider whose results
  are durable quotations.

  ## Identity, sense-level

  A word page's senses refer to QIDs (`refers_to`). Wikidata's `enwikiquote`
  **sitelink** on that QID names the theme page — *grief* (Q...) → *Grief*.
  That is the match: an identifier the encyclopedia already asserts, reaching a
  page by Wikidata's own statement, never a title search. A page whose senses
  refer to nothing declines at coverage and spends nothing; a QID with no
  Wikiquote sitelink costs the one Wikidata request that says so and is then a
  negative cache like any empty answer. `list=search` and `action=parse`
  wikitext are never called (#158 Finding 1).

  ## One page, four requests at most

    1. `sitelinks` — `wbgetentities` for the page's QIDs, `sitefilter=enwikiquote`
       (the Wikidata client's parameters, this provider's budget)
    2. `page` — `GET /api/rest_v1/page/html/<title>`: Parsoid HTML, capped at
       2 MB (*Love* is 1.45 MB), one redirect followed (*Bank* → *Banking*), a
       `404` an honest empty (*Situationship*)
    3. `authors` — the pages the kept lines' citations link to, read from
       Wikiquote's own page properties (`wikibase_item`, the other end of the
       sitelink), redirects followed, 50 at a time
    4. `humans` — which of those items are people (`P31` = `Q5`), one
       `VALUES` query to the Wikidata query service, so a citation that links
       a work or a theme before its author is credited to the author

  Paced 200 ms apart, the Wikidata client's own pace, by the transport.
  Pagination is an **offset into the page's kept lines**: one theme page is one
  answer, and *Load more* asks for the same page again at the next offset.

  ## What is kept, and what is set aside

  A line is kept when its citation or its `<h3>` names a work or a year — a
  cited claim, which is what the shelf may show. Its `era` is its year's band
  (open question 4): 👑 `aristocracy` before 1931 (public domain in the US in
  2026), 📚 `middle` to 1999, 📱 `plebs` after.

  Rows under *Misattributed*, *Disputed* and *Unsourced* are **the register**:
  extracted in the same pass, persisted as provenance with
  `preview_metadata["register"]`, and never put on the rail (the reader shows
  them as a disclosure line). A kept line whose fingerprint matches a register
  row on the page is badged `disputed` (the register names someone else) or
  `apocryphal` (it names no one), with the register's own sentence as the
  note; every other kept line is `plausible` — one cited claim, unverified.

  ## Credits

  A line's `authored_by` is the QID of the first page its citation links to
  **whose item is a human** (`P31` = `Q5`), read from that page's
  `enwikiquote` sitelink — **never a name lookup** — at
  `:candidate` on a theme page (the citation names the author; nothing checked
  it) and at `:verified` on an author page's own cited work. A register row
  gets **no** `authored_by`: when its sentence links the person the line is
  attributed to (or the row sits on that person's own page), it gets a
  `misattributed_to` with `register: true` and the sentence, verbatim, as the
  rationale.

  *Cato, a Tragedy (1713)* may link the play before Addison, and Grief's
  Horace line links the theme page *Impropriety* first. Crediting the first
  link credited the work, which the endpoint rule then refused, and every such
  line opened an `unresolved_creator` case (the audit of #169, residual 1).
  So the credit skips a linked item that is not a person. A citation whose
  linked items are all something else credits nobody and opens no case. One
  whose first link has no item at all is still reported as
  `author_unresolved`. If the query service cannot answer, the old rule stands:
  the first link.
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  import Ecto.Query, only: [from: 2]

  import DevilsDictionary.Discovery.Provider.Helpers,
    only: [offset: 1, headers: 0, limit: 2, sparse: 1, clamp_label: 1]

  alias DevilsDictionary.Absorb.Clients.Wikidata, as: WikidataClient
  alias DevilsDictionary.Discovery.PageEvidence
  alias DevilsDictionary.Discovery.Providers.Wikiquote.Parser
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.SourceIdentity.Entry

  @adapter_version "wikiquote.parsoid.v1"
  @operation "wikiquote_page"
  @site "enwikiquote"
  @namespace "wikiquote_item"
  @max_entities 5
  @max_body 2 * 1024 * 1024
  @page_size 12
  @registers [:misattributed, :disputed, :unsourced]
  @public_domain_before 1931
  @license "CC BY-SA 4.0"
  @license_url "https://creativecommons.org/licenses/by-sa/4.0/"

  @impl true
  def slug, do: "wikiquote"

  @impl true
  def adapter_version, do: @adapter_version

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Wikiquote",
      tier: :middle,
      kind: :encyclopedia,
      access: :api,
      license: @license,
      license_url: @license_url,
      homepage: "https://en.wikiquote.org/",
      logo: "/images/sources/wikiquote.png",
      url_template: "https://en.wikiquote.org/wiki/{title}",
      attribution: "Wikiquote contributors (CC BY-SA 4.0)",
      active: true,
      config: %{
        "operation" => @operation,
        "site" => @site,
        "never_called" => ["action=parse wikitext", "list=search"]
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
      content_types: [:quote],
      body: :html,
      request_interval_ms: request_interval_ms(),
      min_retry_interval_ms: request_interval_ms()
    }
  end

  defp request_interval_ms,
    do: DevilsDictionary.Discovery.Provider.Helpers.interval(config(), :request_interval_ms, 200)

  @impl true
  def enabled?, do: config()[:enabled] != false and is_binary(config()[:endpoint])

  @impl true
  def shelf_detail, do: "theme pages by Wikidata sitelink"

  # ── the target ──────────────────────────────────────────────────────────

  @impl true
  def covers?(target),
    do: PageEvidence.any?(DevilsDictionary.Discovery.page_lexeme_ids(target))

  @impl true
  def automatic_mapping(target) do
    entities =
      target
      |> DevilsDictionary.Discovery.page_lexeme_ids()
      |> PageEvidence.entities(@max_entities)
      |> Enum.map(&Map.take(&1, ["qid", "label", "object_id"]))
      |> with_kinds()

    {@operation,
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "relevance" => target.relevance,
       "resolution_strategy" => "sitelink_qid_v1",
       "entities" => entities
     }}
  end

  # What the registry holds each QID as. A person's Wikiquote page is an
  # author page, whose own subject is the credit for its cited lines and the
  # target of its register — read from the registry the target was built from,
  # never guessed from the page's headings.
  defp with_kinds([]), do: []

  defp with_kinds(entities) do
    kinds =
      DevilsDictionary.Repo.all(
        from e in DevilsDictionary.Registry.Entity,
          where: e.object_id in ^Enum.map(entities, & &1["object_id"]),
          select: {e.object_id, e.entity_kind}
      )
      |> Map.new(fn {id, kind} -> {id, Atom.to_string(kind)} end)

    Enum.map(entities, &Map.put(&1, "kind", Map.get(kinds, &1["object_id"])))
  end

  @impl true
  def mapping_identity(%{"entities" => entities}) when is_list(entities),
    do: PageEvidence.digest(entities)

  def mapping_identity(_parameters), do: "no-entities"

  @impl true
  def validate_mapping(@operation, %{
        "term" => term,
        "resolution_strategy" => "sitelink_qid_v1",
        "entities" => entities
      })
      when is_binary(term) and term != "" and is_list(entities) do
    if PageEvidence.valid_entities?(entities), do: :ok, else: {:error, :invalid_mapping}
  end

  def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}

  # ── requests ────────────────────────────────────────────────────────────

  @impl true
  def request_options(%{"endpoint" => "sitelinks", "qids" => qids}) do
    [
      method: :get,
      url: wikidata_url(),
      params: WikidataClient.sitelink_params(qids, @site),
      headers: headers()
    ]
  end

  # The pages the citations link to, and each one's Wikidata item, from
  # Wikiquote's own page properties: `wikibase_item` is the other end of the
  # sitelink. `redirects=1` follows a link to a redirect (an author's alias
  # page) to the page the item is on, and the answer says which title became
  # which — so a credit survives the link being to an alias (CodeRabbit on
  # #169). A page read, never `list=search` and never `action=parse`.
  def request_options(%{"endpoint" => "authors", "titles" => titles}) do
    [
      method: :get,
      url: api_url(),
      params: [
        action: "query",
        format: "json",
        formatversion: "2",
        titles: Enum.join(titles, "|"),
        redirects: "1",
        prop: "pageprops",
        ppprop: "wikibase_item"
      ],
      headers: headers()
    ]
  end

  # Which of the linked items are people: one small `VALUES` query, because a
  # `wbgetentities` for their claims is every claim they have (Voltaire's alone
  # is a megabyte) and there is no page property that says so.
  def request_options(%{"endpoint" => "humans", "qids" => qids}) do
    [
      method: :get,
      url: sparql_url(),
      params: [
        query:
          "SELECT ?item WHERE { VALUES ?item { #{Enum.map_join(qids, " ", &"wd:#{&1}")} } " <>
            "?item wdt:P31 wd:Q5 }",
        format: "json"
      ],
      headers: [{"accept", "application/sparql-results+json"} | headers()]
    ]
  end

  def request_options(%{"endpoint" => "page", "title" => title}) do
    [
      method: :get,
      url: config()[:endpoint] <> page_path(title),
      headers: [{"accept", "text/html; charset=utf-8"} | headers()],
      # One redirect, as the issue says: *Bank* answers 307 to *Banking*, and
      # a chain is a page we would rather not guess about.
      redirect: true,
      max_redirects: 1,
      # Streamed through the cap below, so nothing is decompressed for us and
      # nothing is decoded: the body is HTML and `parse_body/1` reads it.
      compressed: false,
      decode_body: false,
      into: capped_body(@max_body)
    ]
  end

  defp wikidata_url, do: config()[:wikidata_endpoint] || WikidataClient.api_url()
  defp api_url, do: config()[:api_endpoint] || "https://en.wikiquote.org/w/api.php"
  defp sparql_url, do: config()[:sparql_endpoint] || "https://query.wikidata.org/sparql"

  defp page_path(title),
    do: title |> String.replace(" ", "_") |> URI.encode(&URI.char_unreserved?/1)

  # Reads the body until it passes `limit` bytes, and then stops reading: a
  # response that large is refused whole (`"response_too_large"` from the
  # transport), never parsed in part.
  defp capped_body(limit) do
    fn {:data, data}, {request, response} ->
      body = if(is_binary(response.body), do: response.body, else: "") <> data

      if byte_size(body) > limit do
        {:halt,
         {request, %{response | body: "", private: Map.put(response.private, :body_capped, true)}}}
      else
        {:cont, {request, %{response | body: body}}}
      end
    end
  end

  # The page is HTML; the query service's answer is JSON under a media type
  # (`application/sparql-results+json`) that may reach here undecoded.
  @impl true
  def parse_body("{" <> _ = json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  def parse_body(html) when is_binary(html), do: {:ok, %{"page" => Parser.parse(html)}}
  def parse_body(_body), do: :error

  # A title with no page is an answer: there is no Wikiquote page for this.
  @impl true
  def absent_status?(404), do: true
  def absent_status?(_status), do: false

  # ── retrieve ────────────────────────────────────────────────────────────

  @impl true
  def retrieve(@operation, mapping, request, request_fun) do
    with :ok <- validate_mapping(@operation, mapping) do
      offset = offset(request["after"])
      limit = limit(request["first"], @page_size)

      with {:ok, target} <- sitelink(mapping["entities"], request_fun),
           {:ok, page} <- fetch_page(target, request_fun) do
        build(mapping, request, target, page, offset, limit, request_fun)
      else
        :none -> {:ok, empty(request, offset)}
        {:error, code} -> {:error, code}
        {:deferred, code, seconds} -> {:deferred, code, seconds, request}
      end
    else
      {:error, _reason} -> {:error, "invalid_mapping"}
    end
  end

  def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

  # The first of the page's QIDs, in the page's own order, that has a
  # Wikiquote page. A page's senses rarely refer to more than one concept
  # with a theme page, and when they do the best-evidenced one wins.
  defp sitelink([], _request_fun), do: :none

  defp sitelink(entities, request_fun) do
    qids = Enum.map(entities, & &1["qid"])

    case request_fun.("sitelinks", %{"endpoint" => "sitelinks", "qids" => qids}) do
      {:ok, body} ->
        titles = WikidataClient.sitelink_titles(body, @site)

        entities
        |> Enum.find_value(:none, fn entity ->
          case Map.get(titles, entity["qid"]) do
            nil ->
              nil

            title ->
              {:ok,
               %{qid: entity["qid"], title: title, label: entity["label"], kind: entity["kind"]}}
          end
        end)

      other ->
        other
    end
  end

  defp fetch_page(target, request_fun) do
    case request_fun.("page", %{"endpoint" => "page", "title" => target.title}) do
      {:ok, %{"page" => page}} -> {:ok, page}
      {:ok, %{"absent" => _status}} -> :none
      {:ok, _other} -> {:error, "malformed_response"}
      other -> other
    end
  end

  defp build(mapping, request, target, page, offset, limit, request_fun) do
    title = page.title || target.title
    author_page? = target.kind == "person"

    kept = page.quotations |> Enum.filter(&cited?/1)
    register = Enum.filter(page.register, &(&1.register in @registers))
    slice = kept |> Enum.drop(offset) |> Enum.take(limit)
    # The register rides with the first page only: it is the page's
    # provenance, not a list to page through.
    register_rows = if offset == 0, do: register, else: []

    # Every linked page a credit could be, first links first so a long
    # citation never crowds out another line's author.
    titles =
      (Enum.flat_map(slice, &Enum.take(author_titles(&1, author_page?), 1)) ++
         Enum.flat_map(register_rows, &attributed_titles(&1, author_page?)) ++
         Enum.flat_map(slice, &author_titles(&1, author_page?)))
      |> Enum.uniq()
      |> Enum.take(WikidataClient.batch_size())

    with {:ok, qids} <- author_qids(titles, request_fun),
         {:ok, humans} <- humans(Map.values(qids), request_fun) do
      qids = if author_page?, do: Map.put(qids, title, target.qid), else: qids

      context = %{
        mapping: mapping,
        target: target,
        title: title,
        revision_id: page.revision_id,
        author_page?: author_page?,
        qids: qids,
        humans: humans,
        register: register_index(register)
      }

      items =
        Enum.map(slice, &kept_item(&1, context)) ++
          Enum.map(register_rows, &register_item(&1, context))

      {:ok,
       %{
         request_parameters: Map.put(request, "offset", Integer.to_string(offset)),
         items: items |> Enum.with_index() |> Enum.map(fn {item, i} -> %{item | position: i} end),
         next_cursor: if(offset + limit < length(kept), do: Integer.to_string(offset + limit)),
         completion_reason: if(items == [], do: :no_results, else: :results)
       }}
    else
      # The provider contract: a deferral carries the request back, so the
      # run is retried from where it stood (CodeRabbit on #169).
      {:deferred, code, seconds} ->
        {:deferred, code, seconds, request}

      {:error, code} ->
        {:error, code}
    end
  end

  defp empty(request, offset) do
    %{
      request_parameters: Map.put(request, "offset", Integer.to_string(offset)),
      items: [],
      next_cursor: nil,
      completion_reason: :no_results
    }
  end

  # A line is on the shelf only as a cited claim: its citation or the work
  # heading above it names a work or a year.
  defp cited?(line), do: is_binary(line.work) or is_integer(line.year)

  defp author_titles(line, true), do: if(line.about_subject, do: line.citation_links, else: [])
  defp author_titles(line, false), do: line.citation_links

  defp attributed_titles(_row, true), do: []
  defp attributed_titles(row, false), do: Enum.take(row.attributed_links, 1)

  defp author_qids([], _request_fun), do: {:ok, %{}}

  defp author_qids(titles, request_fun) do
    case request_fun.("authors", %{"endpoint" => "authors", "titles" => titles}) do
      {:ok, body} -> {:ok, page_items(body, titles)}
      other -> other
    end
  end

  # Which of these items are people, or `:unknown` when the query service did
  # not say — in which case the first link is credited, as before. A deferral
  # is still a deferral: the transport has already backed the source off.
  defp humans([], _request_fun), do: {:ok, MapSet.new()}

  defp humans(qids, request_fun) do
    case request_fun.("humans", %{
           "endpoint" => "humans",
           "qids" => qids |> Enum.uniq() |> Enum.sort()
         }) do
      {:ok, %{"results" => %{"bindings" => bindings}}} ->
        {:ok,
         for(
           %{"item" => %{"value" => "http://www.wikidata.org/entity/" <> qid}} <- bindings,
           into: MapSet.new(),
           do: qid
         )}

      {:deferred, _code, _seconds} = deferred ->
        deferred

      _unknown ->
        {:ok, :unknown}
    end
  end

  @doc """
  `%{requested title => QID}` from a `prop=pageprops&ppprop=wikibase_item`
  answer, following its `normalized` and `redirects` lists back to the title
  each citation actually linked. A title whose page has no item, or does not
  exist, is absent — and reported on the item as unresolved, never dropped
  in silence.
  """
  def page_items(%{"query" => query}, titles) when is_list(titles) do
    hops =
      Map.new(
        List.wrap(query["normalized"]) ++ List.wrap(query["redirects"]),
        &{&1["from"], &1["to"]}
      )

    items =
      for %{"title" => title, "pageprops" => %{"wikibase_item" => qid}} <-
            List.wrap(query["pages"]),
          into: %{},
          do: {title, qid}

    for title <- titles, qid = Map.get(items, follow(hops, title, 3)), into: %{}, do: {title, qid}
  end

  def page_items(_body, _titles), do: %{}

  # Normalisation, then a redirect: two hops at most, three to be safe.
  defp follow(_hops, title, 0), do: title

  defp follow(hops, title, n) do
    case Map.get(hops, title) do
      nil -> title
      next -> follow(hops, next, n - 1)
    end
  end

  defp register_index(register) do
    register
    |> Enum.flat_map(fn row ->
      case Fingerprint.fingerprint(row.text) do
        nil -> []
        fingerprint -> [{fingerprint, row}]
      end
    end)
    |> Map.new()
  end

  # ── items ───────────────────────────────────────────────────────────────

  defp kept_item(line, context) do
    fingerprint = Fingerprint.fingerprint(line.text)
    {provenance, note} = provenance(Map.get(context.register, fingerprint))
    {author_qid, author_title, certainty} = credit(line, context)

    item(line, context, %{
      "provenance" => provenance,
      "provenance_note" => note,
      "author_title" => author_title,
      "author_qid" => author_qid,
      "author_unresolved" => if(author_title && is_nil(author_qid), do: author_title),
      "certainty" => certainty && Atom.to_string(certainty)
    })
  end

  defp register_item(row, context) do
    {target_qid, target_title} =
      cond do
        context.author_page? ->
          {context.target.qid, context.title}

        title = List.first(row.attributed_links) ->
          {Map.get(context.qids, title), title}

        true ->
          {nil, nil}
      end

    item(row, context, %{
      "register" => Atom.to_string(row.register),
      "register_note" => row.citation,
      "misattributed_to_title" => target_title,
      "misattributed_to_qid" => target_qid,
      "misattributed_to_unresolved" => if(target_title && is_nil(target_qid), do: target_title)
    })
  end

  # The citation's first linked page is the line's author on a theme page — a
  # candidate, because nothing but the citation says so. On an author page a
  # line under the page's own cited work is the page subject's, verified by
  # the page itself; one under "Quotes about" is somebody else's.
  defp credit(line, %{author_page?: true} = context) do
    cond do
      line.about_subject ->
        linked_credit(line.citation_links, context)

      is_binary(line.subsection) or is_binary(line.citation) ->
        {context.target.qid, context.title, :verified}

      true ->
        {context.target.qid, context.title, :candidate}
    end
  end

  defp credit(line, context), do: linked_credit(line.citation_links, context)

  # The first linked page whose item is a person. Failing that: the first link
  # reported as unresolved when it has no item at all, and no credit when its
  # item is something else — a work, a theme — because crediting a work is a
  # case nobody can close.
  defp linked_credit(links, %{humans: :unknown} = context) do
    title = List.first(links)
    {title && Map.get(context.qids, title), title, :candidate}
  end

  defp linked_credit(links, context) do
    human = Enum.find(links, &MapSet.member?(context.humans, Map.get(context.qids, &1, "")))
    first = List.first(links)

    cond do
      human -> {Map.fetch!(context.qids, human), human, :candidate}
      first && not Map.has_key?(context.qids, first) -> {nil, first, :candidate}
      true -> {nil, nil, nil}
    end
  end

  defp provenance(nil), do: {"plausible", nil}

  defp provenance(row) do
    if is_binary(row.citation),
      do: {"disputed", row.citation},
      else: {"apocryphal", nil}
  end

  defp item(line, context, extra) do
    id = stable_id(context.title, line)

    %{
      external_namespace: @namespace,
      external_id: id,
      identifiers:
        [
          %{
            namespace: @namespace,
            external_id: id,
            metadata: %{"field" => "page+section+position"}
          }
        ] ++
          List.wrap(Fingerprint.identifier(line.text)),
      position: 0,
      match_details: %{
        "kind" => "sitelink",
        "evidence" => "identity",
        "query" => context.mapping["term"],
        "sitelinks" => [
          %{
            "qid" => context.target.qid,
            "title" => context.title,
            "site" => @site,
            "wiki" => "Wikiquote"
          }
        ]
      },
      preview_metadata:
        sparse(
          Map.merge(
            %{
              "title" => line.text,
              "artist" => extra["author_title"],
              "work" => line.work,
              "year" => line.year,
              "era" => era(line.year),
              "citation" => line.citation,
              "section" => section_label(line),
              "locator" => locator(context.title, line),
              "revision_id" => context.revision_id,
              "page" => context.title,
              "source_url" => source_url(context.title, line),
              "attribution" => "Wikiquote, #{@license}",
              "license" => @license,
              "license_url" => @license_url,
              "content_type" => "quote",
              "provider" => "Wikiquote"
            },
            extra
          )
        ),
      display_allowed: true
    }
  end

  @doc """
  The era band of a citation year, for the shelf's banding (#158 open
  question 4): `"aristocracy"` before #{@public_domain_before} (public domain
  in the US as of 2026), `"middle"` to 1999, `"plebs"` from 2000, nil for an
  undated line.
  """
  def era(year) when is_integer(year) and year < @public_domain_before, do: "aristocracy"
  def era(year) when is_integer(year) and year < 2000, do: "middle"
  def era(year) when is_integer(year), do: "plebs"
  def era(_year), do: nil

  # The provider's own id for a line: the page, the section chain and the
  # line's place in it. Hashed, like PoetryDB's poem id, because a section
  # title can hold anything and this id reaches a DOM id; the readable form is
  # `preview_metadata["locator"]`. A line added above this one on the wiki
  # moves the positions after it — a new id for an old line, which the
  # fingerprint then folds back onto the same item.
  @doc false
  def stable_id(title, line) do
    [title, line.section, line.subsection || "", Integer.to_string(line.position)]
    |> Enum.join("\n\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp locator(title, line),
    do:
      [title, line.section, line.subsection, "##{line.position}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" › ")

  defp section_label(line),
    do: [line.section, line.subsection] |> Enum.reject(&is_nil/1) |> Enum.join(" › ")

  defp source_url(title, line) do
    anchor = (line.subsection || line.section || "") |> String.replace(" ", "_")

    "https://en.wikiquote.org/wiki/" <>
      page_path(title) <> "#" <> URI.encode(anchor, &URI.char_unreserved?/1)
  end

  # ── identity ────────────────────────────────────────────────────────────

  @impl DevilsDictionary.SourceIdentity.Adapter
  def identity_record(%{external_namespace: @namespace, external_id: id} = item) do
    metadata = item.preview_metadata

    Entry.new(%{
      source_slug: slug(),
      object_kind: :content,
      content_kind: :quotation,
      stable_identifier: %{namespace: @namespace, external_id: id},
      identifiers: Map.get(item, :identifiers, []),
      label: clamp_label(metadata["title"]),
      year: metadata["year"],
      content: %{
        body: metadata["title"],
        canonical_url: metadata["source_url"],
        year: metadata["year"],
        rights_metadata: %{
          "license" => @license,
          "license_url" => @license_url,
          "attribution" => "Wikiquote contributors",
          "revision_id" => metadata["revision_id"]
        }
      },
      metadata: %{
        "author_display_name" => metadata["artist"] || metadata["misattributed_to_title"],
        "locator" => metadata["locator"]
      },
      relationships: relationships(metadata),
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported_wikiquote_identity}

  # A register row never credits anyone (#164 C4): it may say who a line is
  # misattributed to, with its own sentence as the reason.
  defp relationships(%{"register" => _kind} = metadata) do
    case metadata["misattributed_to_qid"] do
      nil ->
        []

      qid ->
        [
          %{
            role: "misattributed_to",
            register: true,
            certainty: :candidate,
            rationale: metadata["register_note"],
            target_identifiers: [
              %{namespace: "wikidata", external_id: qid, metadata: %{"field" => "sitelink"}}
            ]
          }
        ]
    end
  end

  defp relationships(%{"author_qid" => qid, "certainty" => certainty}) when is_binary(qid) do
    [
      %{
        role: "authored_by",
        certainty: String.to_existing_atom(certainty),
        target_identifiers: [
          %{namespace: "wikidata", external_id: qid, metadata: %{"field" => "sitelink"}}
        ]
      }
    ]
  end

  defp relationships(_metadata), do: []

  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:wikiquote)
end
