defmodule DevilsDictionary.Quotations.Corpus.Build do
  @moduledoc """
  Builds `wikiquote-pd-v1`, the public-domain Wikiquote corpus (#174, build 6
  of #158): a committed selection of lines that build 5's checks call
  *Verified*, each against a Gutenberg text its credited author wrote before
  the public-domain line.

  ## Selection (#174 design 1, decision 1)

    * **Theme pages.** Every concept an active `refers_to` on a sense points
      at, and the page its `enwikiquote` sitelink names. Sense-level only:
      no lexeme fallback.
    * **Author pages.** Every person the registry holds with a QID, and their
      own page. The page is read only when the person has a Gutenberg work
      dated before 1931, because nobody else can verify a line
      (`docs/integrations/wikiquote.md`, *Corpus*).

  Each page is read through Parsoid and `Wikiquote.Parser`, the same parser
  the live provider and the verifier run, so a corpus line and a live line
  get one fingerprint (the spike's route (a)). A line is credited the way the
  provider credits it: the page's subject on an author page, and on a theme
  page the first page its citation links, resolved to a QID by Wikiquote's
  page properties. The credit is never a name.

  ## Kept only when Verified

  A cited line credited to an author with a pre-1931 Gutenberg work goes
  through build 5's pure checks:

    * the line's own claim, from this corpus
    * the page's register (a row there with the line's fingerprint
      contradicts it)
    * the credited author's own Wikiquote page (`Checks.match_page/3`)
    * the author's pre-1931 Gutenberg texts (`Checks.match_texts/2`)

  `Badge.compute/2` decides, and only `"verified"` is kept. A line is kept
  when two sources agree, one of them a primary text, and nothing contradicts
  it. The build never calls `Verifier.verify_author/2`, because that writes:
  verification runs, source records and the ledger. This module writes
  nothing to the database. The seeder writes the evidence.

  ## The work's own date (decision 3)

  A work's year is its `P577`. A work that is an edition or translation of
  another (`P629`) takes its original's `P577`: Aeschylus in a 1956
  translation is still 458 BC. Only works dated before
  1931 are read, and the line's era is the work's.

  ## Reproducible

  The `selection` block pins everything the network was asked:

    * every page with its revision id, read again through Parsoid's
      `page/html/<title>/<revision>`
    * every credit a page property resolved
    * every work with its ebook number and year
    * every author's Wikidata facts

  `run(selection: manifest["selection"])` therefore rebuilds the same set from
  the same bytes. Only the Gutenberg texts are fetched again, and a Gutenberg
  text does not change. `mix dd.quotes.corpus.build` compares the rebuilt set
  with the committed one and refuses to write when they differ.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Clients.Wikidata, as: WikidataClient
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.Discovery.Providers.Wikiquote.Parser
  alias DevilsDictionary.Quotations.{Badge, Fingerprint}
  alias DevilsDictionary.Quotations.Verifier.Checks
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Creators

  @kind "wikiquote-pd"
  @source "wikiquote-pd-v1"
  @public_domain_before 1931
  @wikiquote_batch 50
  @minted_properties ~w(P31 P569 P570 P648)

  @endpoints %{
    parsoid: "https://en.wikiquote.org/api/rest_v1/page/html/",
    wikiquote_api: "https://en.wikiquote.org/w/api.php",
    wikidata_api: "https://www.wikidata.org/w/api.php",
    sparql: "https://query.wikidata.org/sparql",
    gutenberg: "https://www.gutenberg.org/cache/epub/"
  }

  @doc "The manifest kind this builds (`Corpus.Manifest`'s key)."
  def kind, do: @kind

  @doc "The source row its lines are claims of."
  def source_slug, do: @source

  @doc "The public-domain line: a work dated before this year."
  def public_domain_before, do: @public_domain_before

  @doc """
  Builds the corpus. Returns `{:ok, rows, selection, ledger}`.

  Options:

    * `:selection` — a committed manifest's `selection` block. The build reads
      those pages at those revisions with those credits and works, and asks
      nothing else of Wikidata or Wikiquote. Without it, a fresh selection is
      made from the registry (`:concept_qids` and `:person_qids` override that
      read, for tests).
    * `:page_limit` — read only the first N pages (a sample, never a corpus).
    * `:get` — `fn request -> {:ok, status, body, headers} | {:error, reason}`,
      where `request` is a `Req` keyword list. The default is `Req` with an
      identifying User-Agent, pacing and a disk cache under `:cache_dir`.
    * `:endpoints` — overrides for `#{inspect(Map.keys(@endpoints))}`.
    * `:progress` — `fn message -> any end`.
  """
  def run(opts \\ []) do
    ctx = context(opts)

    try do
      with {:ok, selection} <- selection(ctx, opts[:selection]) do
        selection = limit_pages(selection, opts[:page_limit])
        {rows, selection} = read(ctx, selection)
        {:ok, rows, selection, ledger(ctx)}
      end
    after
      :ets.delete(ctx.ledger)
    end
  end

  # ── context: the request function and its ledger ──────────────────────────

  defp context(opts) do
    ledger = :ets.new(:quotes_corpus_ledger, [:public, :duplicate_bag])
    endpoints = Map.merge(@endpoints, Map.new(opts[:endpoints] || []))
    progress = opts[:progress] || fn _message -> :ok end
    get = opts[:get] || default_get(opts[:cache_dir])

    %{
      endpoints: endpoints,
      progress: progress,
      ledger: ledger,
      concept_qids: opts[:concept_qids],
      person_qids: opts[:person_qids],
      get: fn stage, request ->
        answer = get.(request)
        :ets.insert(ledger, {stage, status_of(answer)})
        answer
      end
    }
  end

  defp status_of({:ok, status, _body, _headers}), do: status
  defp status_of({:ok, status, _body}), do: status
  defp status_of({:error, reason}), do: {:error, reason}

  defp ledger(ctx) do
    ctx.ledger
    |> :ets.tab2list()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {stage, statuses} ->
      {stage,
       %{
         "requests" => length(statuses),
         "statuses" => statuses |> Enum.frequencies() |> Map.new(fn {k, v} -> {inspect(k), v} end)
       }}
    end)
  end

  @doc false
  # The default transport: `Req` with the house User-Agent, one request at a
  # time, Wikimedia at 200 ms and Gutenberg at one second, a `429` or `5xx`
  # waited out up to three times, and every answer kept on disk so a second
  # build of the same selection costs nothing.
  def default_get(cache_dir) do
    fn request ->
      key = cache_key(request)
      cached = cache_dir && Path.join(cache_dir, key)

      case cached && File.read(cached) do
        {:ok, binary} ->
          :erlang.binary_to_term(binary)

        _ ->
          answer = fetch(request, 3)

          if cached && match?({:ok, status, _, _} when status in [200, 404], answer) do
            File.mkdir_p!(cache_dir)
            File.write!(cached, :erlang.term_to_binary(answer))
          end

          answer
      end
    end
  end

  defp cache_key(request) do
    [request[:method] || :get, request[:url], request[:params], request[:form]]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch(request, attempts) do
    host = URI.parse(request[:url]).host
    Process.sleep(if host =~ "gutenberg", do: 1_000, else: 200)

    response =
      request
      |> Keyword.merge(
        retry: false,
        receive_timeout: 120_000,
        headers: [
          {"user-agent", DevilsDictionary.Absorb.Clients.HTTP.user_agent()}
          | Keyword.get(request, :headers, [])
        ]
      )
      |> Req.request()

    case response do
      {:ok, %Req.Response{status: status} = response}
      when (status == 429 or status >= 500) and attempts > 1 ->
        Process.sleep(retry_after(response) * 1_000)
        fetch(request, attempts - 1)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, status, body, headers}

      {:error, exception} ->
        if attempts > 1,
          do: fetch(request, attempts - 1),
          else: {:error, Exception.message(exception)}
    end
  end

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      min(max(seconds, 1), 300)
    else
      _ -> 60
    end
  end

  defp get_ok(ctx, stage, request) do
    case ctx.get.(stage, request) do
      {:ok, 200, body, _headers} -> {:ok, body}
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _body, _headers} -> :absent
      {:ok, 404, _body} -> :absent
      {:ok, status, _body, _headers} -> {:error, "#{stage}: http #{status}"}
      {:ok, status, _body} -> {:error, "#{stage}: http #{status}"}
      {:error, reason} -> {:error, "#{stage}: #{inspect(reason)}"}
    end
  end

  # ── selection ─────────────────────────────────────────────────────────────

  defp selection(_ctx, %{} = selection), do: {:ok, selection}

  defp selection(ctx, nil) do
    concept_qids = ctx.concept_qids || registry_concept_qids()
    person_qids = ctx.person_qids || registry_person_qids()
    ctx.progress.("registry: #{length(concept_qids)} concepts, #{length(person_qids)} persons")

    with {:ok, works} <- gutenberg_works(ctx) do
      pd_authors = works |> Enum.map(& &1["author"]) |> MapSet.new()

      ctx.progress.(
        "gutenberg: #{length(works)} works before #{@public_domain_before}, " <>
          "#{MapSet.size(pd_authors)} authors"
      )

      # Every concept's page, and the page of every person who could verify
      # a line: an author with no pre-line text cannot, so their page is not
      # worth a request.
      wanted =
        Enum.uniq(concept_qids ++ Enum.filter(person_qids, &MapSet.member?(pd_authors, &1)))

      with {:ok, sitelinks} <- sitelinks(ctx, wanted) do
        persons = MapSet.new(person_qids)
        concepts = MapSet.new(concept_qids)

        pages =
          for qid <- wanted, title = sitelinks[qid], is_binary(title) do
            %{
              "qid" => qid,
              "title" => title,
              "kind" => if(MapSet.member?(persons, qid), do: "person", else: "concept"),
              "concept" => MapSet.member?(concepts, qid)
            }
          end
          |> Enum.sort_by(& &1["title"])

        ctx.progress.("pages: #{length(pages)}")

        {:ok,
         %{
           "issue" => "#174",
           "spike" => "docs/integrations/wikiquote.md#corpus",
           "public_domain_before" => @public_domain_before,
           "rules" => rules(),
           "counts" => %{
             "concepts" => length(concept_qids),
             "persons" => MapSet.size(persons),
             "gutenberg_authors_before_line" => MapSet.size(pd_authors)
           },
           "pages" => pages,
           "works" => works
         }}
      end
    end
  end

  defp rules do
    %{
      "theme_pages" =>
        "the enwikiquote sitelink of every QID an active refers_to on a sense points at (sense-level only, #174 decision 1)",
      "author_pages" =>
        "the enwikiquote sitelink of every registry person with a verified QID and a Gutenberg (P2034 + P50) work dated before the line",
      "credit" =>
        "an author page's subject for its own cited lines; otherwise the first page the citation links, resolved by Wikiquote pageprops (wikibase_item, redirects followed); never a name",
      "kept" =>
        "cited (a work or a year), credited to an author with a pre-line Gutenberg work, and Badge.compute/2 = verified over the corpus claim, the page's register, the author's own page and the author's pre-line Gutenberg texts",
      "work_year" =>
        "P577 of the Gutenberg item, or of the work it is an edition or translation of (P629) when that has one (#174 decision 3)",
      "parser" => "Wikiquote.Parser over Parsoid HTML (the spike's route (a))"
    }
  end

  @doc false
  # The registry's half of the selection: the QIDs senses refer to. Read the
  # way `PageEvidence.query/1` reads a page's, for every sense at once.
  def registry_concept_qids do
    Repo.all(
      from s in DevilsDictionary.Registry.Sense,
        join: r in DevilsDictionary.Claims.AssertionRevision,
        on: r.subject_object_id == s.object_id and r.is_current,
        join: p in DevilsDictionary.Claims.Predicate,
        on: p.id == r.predicate_id and p.key == "refers_to",
        join: ei in DevilsDictionary.Registry.ExternalIdentifier,
        on: ei.object_id == r.object_object_id and ei.namespace == "wikidata",
        where: r.lifecycle_state == :active and ei.status == :verified,
        distinct: true,
        select: ei.external_id
    )
    |> Enum.sort()
  end

  @doc false
  def registry_person_qids do
    Repo.all(
      from e in DevilsDictionary.Registry.Entity,
        join: ei in DevilsDictionary.Registry.ExternalIdentifier,
        on: ei.object_id == e.object_id and ei.namespace == "wikidata",
        where: e.entity_kind == :person and ei.status == :verified,
        distinct: true,
        select: ei.external_id
    )
    |> Enum.sort()
  end

  # Every item with a Gutenberg ebook id and an author on it, and the year it
  # was published — or its original's, for an edition or a translation. Two
  # queries and no label service: joined in one, with labels, the query
  # service timed out three times running on 2026-09-24; apart they take a
  # minute between them. Labels come later, for the works a line can use.
  defp gutenberg_works(ctx) do
    works = """
    SELECT ?work ?author ?pg ?date WHERE {
      ?work wdt:P2034 ?pg ; wdt:P50 ?author .
      OPTIONAL { ?work wdt:P577 ?date }
    }
    """

    originals = """
    SELECT ?work ?origDate WHERE {
      ?work wdt:P2034 ?pg ; wdt:P629 ?orig . ?orig wdt:P577 ?origDate
    }
    """

    with {:ok, body} <- sparql(ctx, "sparql:works", works),
         {:ok, original_body} <- sparql(ctx, "sparql:originals", originals) do
      {:ok, works_from(body, original_body)}
    end
  end

  @doc false
  def works_from(body, original_body) do
    originals =
      original_body
      |> bindings()
      |> Enum.flat_map(fn b ->
        with "http://www.wikidata.org/entity/" <> work <- get_in(b, ["work", "value"]),
             year when is_integer(year) <- year_of(get_in(b, ["origDate", "value"])) do
          [{work, year}]
        else
          _ -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    body
    |> bindings()
    |> Enum.flat_map(fn b ->
      with "http://www.wikidata.org/entity/" <> work <- get_in(b, ["work", "value"]),
           "http://www.wikidata.org/entity/" <> author <- get_in(b, ["author", "value"]),
           ebook when is_binary(ebook) <- get_in(b, ["pg", "value"]),
           true <- Regex.match?(~r/\A\d+\z/, ebook) do
        [%{work: work, author: author, ebook: ebook, date: year_of(get_in(b, ["date", "value"]))}]
      else
        _ -> []
      end
    end)
    |> Enum.group_by(&{&1.work, &1.author, &1.ebook})
    |> Enum.flat_map(fn {{work, author, ebook}, rows} ->
      dates = rows |> Enum.map(& &1.date) |> Enum.reject(&is_nil/1)

      {year, basis} =
        cond do
          Map.has_key?(originals, work) -> {Enum.min(originals[work]), "P629 P577"}
          dates != [] -> {Enum.min(dates), "P577"}
          true -> {nil, nil}
        end

      if is_integer(year) and year < @public_domain_before do
        [
          %{
            "work" => work,
            "author" => author,
            "ebook" => ebook,
            "year" => year,
            "year_basis" => basis
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1["author"], String.to_integer(&1["ebook"]), &1["work"]})
  end

  defp year_of(value) when is_binary(value) do
    case Regex.run(~r/\A(-?\d+)-/, value) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp year_of(_value), do: nil

  # `enwikiquote` sitelinks for a set of QIDs, fifty to a `wbgetentities`:
  # the provider's own route to a theme page (`WikidataClient.sitelink_params/2`),
  # and the Action API rather than the query service, which answered a
  # 400-QID `VALUES` query with 504 on 2026-09-24.
  defp sitelinks(ctx, qids) do
    qids
    |> Enum.sort()
    |> Enum.chunk_every(WikidataClient.batch_size())
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case get_ok(ctx, "wikidata:sitelinks",
             url: ctx.endpoints.wikidata_api,
             params: WikidataClient.sitelink_params(chunk, "enwikiquote")
           ) do
        {:ok, body} when is_map(body) ->
          {:cont, {:ok, Map.merge(acc, WikidataClient.sitelink_titles(body, "enwikiquote"))}}

        {:ok, _other} ->
          {:cont, {:ok, acc}}

        :absent ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sparql(ctx, stage, query) do
    case get_ok(ctx, stage,
           method: :post,
           url: ctx.endpoints.sparql,
           form: [query: query, format: "json"],
           headers: [{"accept", "application/sparql-results+json"}]
         ) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, body} when is_binary(body) -> {:ok, Jason.decode!(body)}
      :absent -> {:error, "#{stage}: 404"}
      other -> other
    end
  end

  defp bindings(%{"results" => %{"bindings" => bindings}}), do: bindings
  defp bindings(_body), do: []

  defp limit_pages(selection, nil), do: selection

  defp limit_pages(selection, limit) when is_integer(limit),
    do: Map.update!(selection, "pages", &Enum.take(&1, limit))

  # ── reading ───────────────────────────────────────────────────────────────

  defp read(ctx, selection) do
    works = Enum.group_by(selection["works"], & &1["author"])
    pinned? = Map.has_key?(selection, "credits")

    pages =
      selection["pages"]
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {page, n} ->
        if rem(n, 50) == 0, do: ctx.progress.("page #{n}/#{length(selection["pages"])}")

        case read_page(ctx, page["title"], page["revision_id"]) do
          {:ok, parsed} -> [{Map.put(page, "revision_id", parsed.revision_id), parsed}]
          :absent -> []
          {:error, reason} -> raise "page #{page["title"]}: #{reason}"
        end
      end)

    candidates = Enum.flat_map(pages, fn {page, parsed} -> candidates(page, parsed) end)

    credits =
      if pinned?,
        do: selection["credits"],
        else: resolve_credits(ctx, candidates, works)

    credited =
      for candidate <- candidates,
          author = credit(candidate, credits),
          Map.has_key?(works, author),
          do: Map.put(candidate, :author, author)

    authors = Enum.map(credited, & &1.author) |> Enum.uniq() |> Enum.sort()
    ctx.progress.("candidates: #{length(credited)} lines, #{length(authors)} authors")

    entities =
      if pinned?, do: selection["authors"], else: author_entities(ctx, authors)

    # The works a candidate could be found in, labelled: a pinned selection
    # carries its labels, a fresh one asks Wikidata for these works only.
    works =
      if pinned?,
        do: works,
        else: label_works(ctx, works, authors)

    author_pages =
      if pinned?,
        do: selection["author_pages"],
        else: author_page_titles(ctx, authors, pages)

    # Each author's own page, read once and pinned at the revision read.
    own_pages =
      author_pages
      |> Map.take(authors)
      |> Map.new(fn {qid, pinned} -> {qid, own_page(ctx, pinned)} end)

    author_pages =
      Map.new(own_pages, fn
        {qid, nil} -> {qid, author_pages[qid]}
        {qid, page} -> {qid, %{"title" => page["title"], "revision_id" => page["revision_id"]}}
      end)

    rows =
      credited
      |> Enum.group_by(& &1.author)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {author, lines} ->
        verify_author(ctx, author, lines, works[author], entities[author], own_pages[author])
      end)
      |> fold()

    kept_authors = rows |> Enum.map(& &1["author_qid"]) |> MapSet.new()
    kept_works = rows |> Enum.map(& &1["work_qid"]) |> MapSet.new()

    selection =
      selection
      |> Map.put("pages", Enum.map(pages, &elem(&1, 0)))
      |> Map.put("credits", pinned_credits(credits, candidates, works, pinned?))
      |> Map.put("authors", Map.take(entities, Enum.sort(authors)))
      |> Map.put("author_pages", Map.take(author_pages, authors))
      |> Map.put(
        "works",
        works
        |> Map.take(authors)
        |> Map.values()
        |> List.flatten()
        |> Enum.sort_by(&{&1["author"], String.to_integer(&1["ebook"]), &1["work"]})
      )
      |> Map.update("counts", %{}, fn counts ->
        Map.merge(counts, %{
          "pages_read" => length(pages),
          "candidates" => length(credited),
          "candidate_authors" => length(authors),
          "kept" => length(rows),
          "kept_authors" => MapSet.size(kept_authors),
          "kept_works" => MapSet.size(kept_works)
        })
      end)

    {rows, selection}
  end

  # A pinned selection keeps its credits as it had them; a fresh one keeps
  # only the credits that led anywhere — a title resolving to an author with
  # no pre-line work is dropped whether or not it is pinned.
  defp pinned_credits(credits, _candidates, _works, true), do: credits

  defp pinned_credits(credits, _candidates, works, false) do
    credits
    |> Enum.filter(fn {_title, qid} -> Map.has_key?(works, qid) end)
    |> Map.new()
  end

  @doc false
  def read_page(ctx, title, revision) do
    path = title |> String.replace(" ", "_") |> URI.encode(&URI.char_unreserved?/1)
    path = if revision, do: "#{path}/#{revision}", else: path

    case get_ok(ctx, "parsoid",
           url: ctx.endpoints.parsoid <> path,
           headers: [{"accept", "text/html; charset=utf-8"}],
           decode_body: false,
           max_redirects: 1
         ) do
      {:ok, html} when is_binary(html) -> {:ok, Parser.parse(html)}
      other -> other
    end
  end

  # The page's cited lines, each with the page it came from and what the page
  # says about its credit — before anybody has been asked who that is.
  defp candidates(page, parsed) do
    author_page? = page["kind"] == "person"
    register = register_index(parsed.register)
    title = parsed.title || page["title"]

    for line <- parsed.quotations,
        is_binary(line.work) or is_integer(line.year),
        fingerprint = Fingerprint.fingerprint(line.text),
        is_binary(fingerprint) do
      %{
        page: Map.put(page, "title", title),
        revision_id: parsed.revision_id,
        line: line,
        fingerprint: fingerprint,
        credit: credit_source(line, author_page?, page["qid"]),
        register: Map.get(register, fingerprint)
      }
    end
  end

  # The provider's rule (`Wikiquote.credit/2`): on an author page, a line not
  # under *Quotes about* is the subject's; any other line is its citation's
  # first linked page.
  defp credit_source(line, true, qid) do
    if line.about_subject,
      do: {:title, List.first(line.citation_links)},
      else: {:qid, qid}
  end

  defp credit_source(line, false, _qid), do: {:title, List.first(line.citation_links)}

  defp credit(%{credit: {:qid, qid}}, _credits), do: qid
  defp credit(%{credit: {:title, nil}}, _credits), do: nil
  defp credit(%{credit: {:title, title}}, credits), do: Map.get(credits, title)

  defp register_index(register) do
    for row <- register,
        row.register in [:misattributed, :disputed, :unsourced],
        fingerprint = Fingerprint.fingerprint(row.text),
        is_binary(fingerprint),
        into: %{},
        do: {fingerprint, row}
  end

  defp resolve_credits(ctx, candidates, _works) do
    titles =
      for %{credit: {:title, title}} <- candidates, is_binary(title), uniq: true, do: title

    ctx.progress.("credits: #{length(titles)} linked pages")

    titles
    |> Enum.sort()
    |> Enum.chunk_every(@wikiquote_batch)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case get_ok(ctx, "pageprops",
             url: ctx.endpoints.wikiquote_api,
             params: [
               action: "query",
               format: "json",
               formatversion: "2",
               titles: Enum.join(chunk, "|"),
               redirects: "1",
               prop: "pageprops",
               ppprop: "wikibase_item"
             ]
           ) do
        {:ok, body} -> Map.merge(acc, Wikiquote.page_items(body, chunk))
        :absent -> acc
        {:error, reason} -> raise reason
      end
    end)
  end

  defp label_works(ctx, works, authors) do
    wanted = works |> Map.take(authors) |> Map.values() |> List.flatten()
    qids = wanted |> Enum.map(& &1["work"]) |> Enum.uniq() |> Enum.sort()

    labels =
      qids
      |> Enum.chunk_every(@wikiquote_batch)
      |> Enum.reduce(%{}, fn chunk, acc ->
        case get_ok(ctx, "wikidata:labels",
               url: ctx.endpoints.wikidata_api,
               params: [
                 action: "wbgetentities",
                 format: "json",
                 ids: Enum.join(chunk, "|"),
                 props: "labels",
                 languages: "en|mul"
               ]
             ) do
          {:ok, %{"entities" => entities}} ->
            Map.merge(
              acc,
              for {qid, entity} <- entities, into: %{} do
                {qid,
                 get_in(entity, ["labels", "en", "value"]) ||
                   get_in(entity, ["labels", "mul", "value"])}
              end
            )

          {:error, reason} ->
            raise reason

          _other ->
            acc
        end
      end)

    Map.new(works, fn {author, list} ->
      {author, Enum.map(list, &Map.put(&1, "label", Map.get(labels, &1["work"])))}
    end)
  end

  # What `Creators.classify/2` needs to mint the author offline: labels,
  # description, and the minted properties, each statement cut to its
  # `mainsnak`. The seeder builds its prepared map from this and never asks
  # Wikidata.
  defp author_entities(_ctx, []), do: %{}

  defp author_entities(ctx, qids) do
    qids
    |> Enum.chunk_every(@wikiquote_batch)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case get_ok(ctx, "wikidata:entities",
             url: ctx.endpoints.wikidata_api,
             params: [
               action: "wbgetentities",
               format: "json",
               ids: Enum.join(chunk, "|"),
               props: "labels|descriptions|claims",
               languages: "en|mul"
             ]
           ) do
        {:ok, %{"entities" => entities}} ->
          Map.merge(
            acc,
            for(
              {qid, entity} <- entities,
              entity["missing"] == nil,
              into: %{},
              do: {qid, snapshot(entity)}
            )
          )

        {:ok, _other} ->
          acc

        :absent ->
          acc

        {:error, reason} ->
          raise reason
      end
    end)
  end

  @doc false
  def snapshot(entity) do
    %{
      "id" => entity["id"],
      "labels" => Map.take(entity["labels"] || %{}, ["en", "mul"]),
      "descriptions" => Map.take(entity["descriptions"] || %{}, ["en"]),
      "claims" =>
        entity
        |> Map.get("claims", %{})
        |> Map.take(@minted_properties)
        |> Map.new(fn {property, statements} ->
          {property,
           statements
           |> Enum.map(&Map.take(&1, ["mainsnak", "rank", "type"]))
           |> Enum.map(
             &update_in(&1, ["mainsnak"], fn snak -> Map.drop(snak || %{}, ["hash"]) end)
           )}
        end)
    }
  end

  # Each credited author's own Wikiquote page: already read if it was one of
  # the selection's pages, otherwise found by its sitelink and read once.
  defp author_page_titles(ctx, authors, pages) do
    read =
      for {page, parsed} <- pages, page["kind"] == "person", into: %{} do
        {page["qid"],
         %{"title" => parsed.title || page["title"], "revision_id" => parsed.revision_id}}
      end

    missing = Enum.reject(authors, &Map.has_key?(read, &1))

    found =
      case sitelinks(ctx, missing) do
        {:ok, titles} -> titles
        {:error, reason} -> raise reason
      end

    Map.merge(
      read,
      for {qid, title} <- found, into: %{} do
        {qid, %{"title" => title, "revision_id" => nil}}
      end
    )
  end

  # ── verifying, per author ─────────────────────────────────────────────────

  defp verify_author(ctx, author, lines, works, entity, page) do
    case Creators.classify(author, %{author => entity}) do
      {:ok, %{kind: :person} = attrs} ->
        texts = texts(ctx, works)
        dated? = is_integer(attrs.birth_year) or is_integer(attrs.death_year)

        Enum.flat_map(lines, fn candidate ->
          verify_line(candidate, attrs, page, texts, dated?)
        end)

      _not_a_person ->
        []
    end
  end

  defp own_page(_ctx, nil), do: nil

  defp own_page(ctx, %{"title" => title} = pinned) do
    case read_page(ctx, title, pinned["revision_id"]) do
      {:ok, parsed} -> Map.put(Checks.compact(parsed, title), "revision_id", parsed.revision_id)
      :absent -> nil
      {:error, reason} -> raise "author page #{title}: #{reason}"
    end
  end

  # One author's pre-line texts, each fetched once and normalised once.
  defp texts(ctx, works) do
    works
    |> Enum.uniq_by(& &1["ebook"])
    |> Enum.flat_map(fn work ->
      ebook = work["ebook"]

      case get_ok(ctx, "gutenberg",
             url: "#{ctx.endpoints.gutenberg}#{ebook}/pg#{ebook}.txt",
             decode_body: false
           ) do
        {:ok, body} when is_binary(body) ->
          text = Checks.text_body(body)
          lines = String.split(text, ~r/\r?\n/)

          [
            {work,
             %{
               ebook: ebook,
               label: work["label"],
               revision_id: nil,
               lines: lines,
               line_index: Checks.index_lines(lines),
               normalised: Fingerprint.normalise(text)
             }}
          ]

        :absent ->
          []

        {:error, reason} ->
          raise "gutenberg ##{ebook}: #{reason}"
      end
    end)
  end

  defp verify_line(candidate, attrs, page, texts, dated?) do
    line = candidate.line

    claim = %{
      source: @source,
      kind: :cited,
      role: :supports,
      work: line.work,
      year: line.year
    }

    register =
      case candidate.register do
        nil ->
          []

        row ->
          [%{source: "wikiquote", kind: :register, role: :contradicts, note: row.citation}]
      end

    own = Checks.match_page(page, line.text, "wikiquote")

    primary =
      Enum.find_value(texts, [], fn {work, text} ->
        case Checks.match_texts([text], line.text) do
          [finding] -> [Map.put(finding, :work, work)]
          [] -> nil
        end
      end)

    findings = [claim | register] ++ own ++ primary
    verdict = Badge.compute(findings, author_dated?: dated?)

    case {verdict.badge, primary} do
      {"verified", [%{work: work} = found]} ->
        [row(candidate, attrs, work, found, findings, verdict)]

      _ ->
        []
    end
  end

  defp row(candidate, attrs, work, found, findings, verdict) do
    line = candidate.line
    page = candidate.page
    title = page["title"]

    %{
      "fingerprint" => candidate.fingerprint,
      "text" => line.text,
      "author_qid" => attrs.qid,
      "author_label" => attrs.label,
      "work_qid" => work["work"],
      "work_label" => work["label"],
      "work_year" => work["year"],
      "work_year_basis" => work["year_basis"],
      "gutenberg" => %{"ebook" => work["ebook"], "locator" => found.locator},
      "page" => title,
      "page_qid" => page["qid"],
      "revision_id" => candidate.revision_id,
      "wikiquote_item" => Wikiquote.stable_id(title, line),
      "locator" =>
        [title, line.section, line.subsection, "##{line.position}"]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" › "),
      "section" => [line.section, line.subsection] |> Enum.reject(&is_nil/1) |> Enum.join(" › "),
      "citation" => line.citation,
      "cited_work" => line.work,
      "cited_year" => line.year,
      "source_url" => source_url(title, line),
      "concept_qids" => if(page["concept"], do: [page["qid"]], else: []),
      "badge" => verdict.badge,
      "agreements" => verdict.agreements,
      "sources" => verdict.sources,
      "score" => verdict.score,
      "checks" =>
        findings
        |> Enum.reject(&(&1.source == @source))
        |> Enum.map(fn finding ->
          %{
            "source" => finding.source,
            "kind" => Atom.to_string(finding.kind),
            "role" => Atom.to_string(finding.role),
            "locator" => finding[:locator]
          }
        end)
        |> Enum.sort_by(&{&1["source"], &1["kind"], &1["locator"] || ""})
    }
  end

  defp source_url(title, line) do
    anchor = (line.subsection || line.section || "") |> String.replace(" ", "_")
    path = title |> String.replace(" ", "_") |> URI.encode(&URI.char_unreserved?/1)
    "https://en.wikiquote.org/wiki/" <> path <> "#" <> URI.encode(anchor, &URI.char_unreserved?/1)
  end

  # One line, one row: the same words found on two pages are one subject.
  # The first page by title keeps the row; every page's concept joins it, so
  # the line reaches every word page either page would have.
  defp fold(rows) do
    rows
    |> Enum.group_by(& &1["fingerprint"])
    |> Enum.map(fn {_fingerprint, group} ->
      [first | _] = Enum.sort_by(group, &{&1["page"], &1["locator"]})

      concepts = group |> Enum.flat_map(& &1["concept_qids"]) |> Enum.uniq() |> Enum.sort()

      also =
        group
        |> Enum.map(& &1["locator"])
        |> Enum.uniq()
        |> Enum.sort()
        |> List.delete(first["locator"])

      first
      |> Map.put("concept_qids", concepts)
      |> Map.put("also_at", also)
    end)
    |> Enum.sort_by(& &1["fingerprint"])
  end

  @doc """
  The checksum of the set: the rows alone, in fingerprint order, so a rebuild
  that finds the same lines at the same places is the same corpus whatever
  its ledger says.
  """
  def set_checksum(rows) do
    rows
    |> Enum.sort_by(& &1["fingerprint"])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
