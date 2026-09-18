defmodule DevilsDictionary.Artworks.Corpus.OpenLibrary do
  @moduledoc """
  Builds the `open-library` corpus manifest: public-domain literary works that
  Wikidata already carries an Open Library id for.

  The live provider answers *which book uses this word*. It does not answer
  *which books are worth holding*, because that is not a question a full-text
  search has an opinion about. This manifest is the other half: every work
  Wikidata links to Open Library through **P648**, written by a named author,
  famous enough to clear a measured sitelink floor, and old enough to be in the
  public domain.

  The identity is the **OLID**, which is the whole point of building it from
  P648 rather than from Open Library's own lists: a book found live by
  `DevilsDictionary.Discovery.Providers.OpenLibrary` and a book held here are
  one entity in the registry, the way PoetryDB's poems are.

  ## Why the query is paged by exact sitelink count, and what it cannot do

  #109 Phase 3c was given this query:

      ?work wdt:P648 ?olid ; wdt:P31/wdt:P279* wd:Q7725634 ; wdt:P50 ?author

  **It does not answer.** Measured 2026-09-18 against the Wikidata Query
  Service, VALUES-bound on sitelinks exactly as
  `DevilsDictionary.Artworks.Corpus.WikidataFamous` is: `{60}` → HTTP 502 after
  53 s, `{60…99}` → HTTP 504 after 84 s, `{30 31 32}` → connection closed after
  52 s. Three bands, three failures. The cost is the `P31/P279*` property path,
  which walks a 5,597-class subclass closure for every candidate the sitelink
  band proposes.

  Dropping the class filter from the walk answers the same band in 3.9 s. So
  the class axis moves to where the guide already puts the expensive parts of a
  Wikidata query — the **describe** pass over a bound set of QIDs, where the
  items are named and a lookup is cheap:

    1. **walk** — `VALUES ?sitelinks {…}` with `wdt:P648` and `wdt:P50`. No
       class filter. This is selective enough on its own: an item with an Open
       Library id and a named author is a book almost by construction.
    2. **describe** — `VALUES ?item {…}` for labels, `P31` classes, `P577`
       publication and each author's `P570` death year.
    3. **filter, locally** — the class closure of `Q7725634` (one query,
       `?c wdt:P279* wd:Q7725634`) and the public-domain rule below.

  The closure is fetched rather than committed because it is Wikidata's fact
  and it moves; 5,597 QIDs in a `VALUES` clause is also a query nobody should
  send.

  ## The public-domain rule

  The brief asked for public-domain works and named no test, so this is the
  test, stated rather than assumed. A work is kept when **either**:

    * its earliest `P577` publication year is **1929 or earlier** — the United
      States bright line, the same one #109 Phase 3b used for Chronicling
      America; **or**
    * it has no `P577` at all and **every** named author has a `P570` death
      year of **1955 or earlier** — life of the author plus seventy, as of
      2026.

  A work with no publication date and an author with no death date is
  **dropped**. The gap is deliberate: this manifest's rows are shown to readers
  as public domain, and a guess would be the one claim a corpus exists to
  avoid. `selection.public_domain` in the committed file records the rule and
  the count each branch kept.

  ## What is not here

  No cover URL. `P648` yields **work** OLIDs (`OL…W`), and Open Library's cover
  API serves edition ids and cover ids, not work ids — so a cover URL for these
  rows would be a URL that 404s. The live provider records one where
  `search.json` gives a `cover_i` to build it from. No image bytes are fetched
  by either, ever.
  """

  alias DevilsDictionary.Artworks.Corpus.Manifest

  @kind "open-library"

  @endpoint "https://query.wikidata.org/sparql"

  # The literary-work class whose subclass closure a row's `P31` must land in.
  @literary_work "Q7725634"

  # The count axis, walked downwards. Low counts are crowded and the bands get
  # slower and less reliable the further down you go — measured: `{10 11}`
  # answered in 7.7 s, `{12 13 14}` and `{8 9}` did not answer at all. The
  # floor is set where the walk is reliable, not where the graph runs out.
  @ceiling 400
  @default_min_sitelinks 15

  @default_request_limit 200
  @default_interval_ms 1_000
  @describe_batch 100
  @max_attempts 2

  # A famous-books set without *War and Peace* in it is not the set.
  @smoke_test_qid "Q161531"

  @publication_floor 1929
  @death_floor 1955

  @doc "The manifest kind this builder produces."
  def kind, do: @kind

  @doc "The QID whose presence proves the set is the set."
  def smoke_test_qid, do: @smoke_test_qid

  @doc "Where the committed manifest lives."
  def default_path, do: "priv/artworks/manifests/#{@kind}-v1.json"

  @doc """
  The sitelink-count bands the walk asks for at or above `minimum`, highest
  first.

  The chunking is the measured one: wide and sparse at the top where almost
  nothing holds those counts, narrow at the bottom where everything does.
  """
  def chunks(minimum \\ @default_min_sitelinks) do
    [
      Enum.to_list(100..@ceiling//1),
      Enum.to_list(60..99//1),
      Enum.to_list(50..59//1),
      Enum.to_list(40..49//1),
      Enum.to_list(30..39//1),
      Enum.to_list(25..29//1),
      Enum.to_list(20..24//1),
      Enum.to_list(15..19//1)
    ]
    |> Enum.map(&Enum.filter(&1, fn count -> count >= minimum end))
    |> Enum.reject(&(&1 == []))
  end

  @doc """
  Builds the manifest for every public-domain literary work at or above
  `:min_sitelinks`.

  Returns `{:ok, manifest, ledger}`, or `{:error, reason}` when the smoke test
  fails.
  """
  def build(opts \\ []) do
    minimum = opts[:min_sitelinks] || @default_min_sitelinks
    state = state(opts)

    with {:ok, closure, state} <- closure(state),
         {:ok, selected, state} <- walk(chunks(minimum), [], state) do
      selected = Enum.filter(selected, &(&1["sitelinks"] >= minimum))
      {described, state} = describe(selected, state)

      {kept, dropped} = partition(described, closure)

      if Enum.any?(kept, &(&1["qid"] == @smoke_test_qid)) do
        manifest =
          Manifest.new(@kind, kept, %{
            "min_sitelinks" => minimum,
            "paging" => "VALUES over exact sitelink counts #{minimum}..#{@ceiling}",
            "selection" =>
              "wdt:P648 with wdt:P50, sitelinks >= #{minimum}, " <>
                "P31 within the subclass closure of #{@literary_work}",
            "identity" => "Open Library work id (P648)",
            "class_filter" =>
              "applied on named items in the describe pass, not as P31/P279* in the walk — " <>
                "the walk form of that query answers 502, 504 and a closed connection",
            "closure_size" => map_size(closure),
            "public_domain" => %{
              "rule" =>
                "P577 publication year <= #{@publication_floor}, or no P577 and every " <>
                  "P50 author has a P570 death year <= #{@death_floor} (life + 70 as of 2026)",
              "by_publication" => Enum.count(kept, &(&1["pd_basis"] == "publication")),
              "by_author_death" => Enum.count(kept, &(&1["pd_basis"] == "author_death"))
            },
            "covers" =>
              "none recorded: P648 yields work OLIDs and Open Library's cover API serves " <>
                "edition and cover ids. No image bytes were fetched.",
            "smoke_test" => "#{@smoke_test_qid} (War and Peace) is present",
            "probe" => "docs/integrations/open-library.md",
            "probed_on" => "2026-09-18"
          })

        {:ok, manifest, ledger(state, kept, dropped, minimum)}
      else
        {:error, "smoke test failed: #{@smoke_test_qid} is not in the built set"}
      end
    else
      {:error, reason, _state} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One manifest row from a described selection, or `nil` when it is not a
  public-domain literary work.

  Exposed because it is the whole of the selection rule and a test can hold it
  to the rule without a network.
  """
  def row(described, closure) when is_map(described) and is_map(closure) do
    with true <- literary?(described["classes"], closure),
         {:ok, basis} <- public_domain(described) do
      %{
        "olid" => described["olid"],
        "qid" => described["qid"],
        "title" => described["title"] || described["qid"],
        "year" => described["publication_year"],
        "sitelinks" => described["sitelinks"],
        "authors" => described["authors"],
        "pd_basis" => basis,
        "source_url" => "https://openlibrary.org/works/#{described["olid"]}",
        "wikidata_url" => "https://www.wikidata.org/wiki/#{described["qid"]}"
      }
    else
      _ -> nil
    end
  end

  defp partition(described, closure) do
    Enum.reduce(described, {[], 0}, fn item, {kept, dropped} ->
      case row(item, closure) do
        nil -> {kept, dropped + 1}
        row -> {[row | kept], dropped}
      end
    end)
    |> then(fn {kept, dropped} -> {Enum.reverse(kept), dropped} end)
  end

  defp literary?(classes, closure) when is_list(classes),
    do: Enum.any?(classes, &Map.has_key?(closure, &1))

  defp literary?(_classes, _closure), do: false

  @doc """
  Whether a described work is in the public domain, and on which branch.

  `{:ok, "publication"}`, `{:ok, "author_death"}`, or `:error` — which is a
  work this manifest declines to claim anything about.
  """
  def public_domain(%{"publication_year" => year}) when is_integer(year) do
    if year <= @publication_floor, do: {:ok, "publication"}, else: :error
  end

  def public_domain(%{"authors" => authors}) when is_list(authors) and authors != [] do
    deaths = Enum.map(authors, & &1["died"])

    if Enum.all?(deaths, &(is_integer(&1) and &1 <= @death_floor)),
      do: {:ok, "author_death"},
      else: :error
  end

  def public_domain(_described), do: :error

  defp ledger(state, kept, dropped, minimum) do
    %{
      wikidata_requests: state.requests,
      min_sitelinks: minimum,
      works: length(kept),
      dropped_not_literary_or_not_public_domain: dropped,
      by_publication: Enum.count(kept, &(&1["pd_basis"] == "publication")),
      by_author_death: Enum.count(kept, &(&1["pd_basis"] == "author_death")),
      distinct_authors:
        kept |> Enum.flat_map(& &1["authors"]) |> Enum.map(& &1["qid"]) |> Enum.uniq() |> length(),
      smoke_test_present: Enum.any?(kept, &(&1["qid"] == @smoke_test_qid)),
      image_bytes_downloaded: 0,
      failures: Enum.reverse(state.failures)
    }
  end

  defp state(opts) do
    %{
      request_limit: opts[:request_limit] || @default_request_limit,
      request_fun: opts[:request_fun] || (&Req.request/1),
      interval_ms: Keyword.get(opts, :interval_ms) || @default_interval_ms,
      requests: 0,
      failures: []
    }
  end

  # The subclass closure of `Q7725634`, as a set. One request, and it is a pure
  # class walk with nothing joined to it, so it answers in about three seconds
  # where the same walk inlined into the item query does not answer at all.
  defp closure(state) do
    case request(state, closure_sparql()) do
      {:ok, bindings, state} ->
        set =
          bindings
          |> Enum.flat_map(&qid_from_entity(value(&1, "c")))
          |> Map.new(&{&1, true})

        if map_size(set) > 0, do: {:ok, set, state}, else: {:error, "empty_class_closure", state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp walk([], rows, state), do: {:ok, merge(rows), state}

  defp walk([counts | rest], rows, state) do
    case request(state, counts_sparql(counts)) do
      {:ok, bindings, state} ->
        walk(rest, rows ++ selection(bindings), state)

      {:error, :request_limit, state} ->
        {:ok, merge(rows), state}

      {:error, reason, state} ->
        # A band that will not answer is recorded rather than swallowed: the
        # floor's credibility depends on knowing which counts were measured.
        walk(
          rest,
          rows,
          fail(state, %{
            "counts" => "#{List.first(counts)}..#{List.last(counts)}",
            "reason" => to_string(reason)
          })
        )
    end
  end

  defp describe(selected, state) do
    by_qid = Map.new(selected, &{&1["qid"], &1})

    selected
    |> Enum.map(& &1["qid"])
    |> Enum.chunk_every(@describe_batch)
    |> Enum.reduce({[], state}, fn qids, {rows, state} ->
      case request(state, describe_sparql(qids)) do
        {:ok, bindings, state} ->
          described = Map.new(description(bindings), &{&1["qid"], &1})

          merged =
            Enum.flat_map(qids, fn qid ->
              case described[qid] do
                nil -> []
                row -> [Map.merge(by_qid[qid] || %{}, row)]
              end
            end)

          {rows ++ merged, state}

        {:error, :request_limit, state} ->
          {rows, state}

        {:error, reason, state} ->
          {rows, fail(state, %{"describe_batch" => length(qids), "reason" => to_string(reason)})}
      end
    end)
  end

  defp fail(state, failure), do: %{state | failures: [failure | state.failures]}

  defp request(%{requests: requests, request_limit: limit} = state, _query)
       when requests >= limit,
       do: {:error, :request_limit, state}

  defp request(state, query), do: attempt(state, query, 1)

  defp attempt(state, query, attempt) do
    if state.interval_ms > 0, do: Process.sleep(state.interval_ms)
    state = %{state | requests: state.requests + 1}

    options = [
      method: :get,
      url: @endpoint,
      params: [query: query, format: "json"],
      headers: [
        {"accept", "application/sparql-results+json"},
        {"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}
      ],
      receive_timeout: 120_000,
      retry: false
    ]

    case state.request_fun.(options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, get_in(body, ["results", "bindings"]) || [], state}

      {:ok, %Req.Response{status: status}} when status in [429, 500, 502, 503, 504] ->
        if attempt < @max_attempts,
          do: attempt(state, query, attempt + 1),
          else: {:error, "http_#{status}", state}

      {:ok, %Req.Response{status: status}} ->
        {:error, "http_#{status}", state}

      {:error, _reason} ->
        if attempt < @max_attempts,
          do: attempt(state, query, attempt + 1),
          else: {:error, :unavailable, state}
    end
  end

  defp closure_sparql, do: "SELECT ?c WHERE { ?c wdt:P279* wd:#{@literary_work} . }"

  # No class filter here on purpose — see the moduledoc. The sitelink band is
  # bound rather than filtered, which turns a scan into a lookup, and `P648`
  # with `P50` is selective enough to carry the rest.
  defp counts_sparql(counts) do
    """
    SELECT ?item ?sitelinks ?olid WHERE {
      VALUES ?sitelinks { #{Enum.join(counts, " ")} }
      ?item wikibase:sitelinks ?sitelinks ;
            wdt:P648 ?olid ;
            wdt:P50 ?author .
    }
    """
  end

  # Labels, classes, publication and authors for a *bound* set of QIDs. The set
  # is given in `VALUES`, so the service looks each one up instead of scanning.
  # `MIN(?year)` is the earliest publication a work records, which is the one
  # the public-domain rule is about; a work with three editions must not become
  # three groups.
  defp describe_sparql(qids) do
    values = qids |> Enum.map(&"wd:#{&1}") |> Enum.join(" ")

    """
    SELECT ?item (SAMPLE(?label) AS ?title) (MIN(?pubYear) AS ?published)
           (GROUP_CONCAT(DISTINCT ?class; separator="|") AS ?classes)
           (GROUP_CONCAT(DISTINCT ?authorTriple; separator="|") AS ?authors)
    WHERE {
      VALUES ?item { #{values} }
      OPTIONAL { ?item rdfs:label ?label . FILTER(lang(?label) = "en") }
      OPTIONAL { ?item wdt:P577 ?pub . BIND(YEAR(?pub) AS ?pubYear) }
      OPTIONAL { ?item wdt:P31 ?type . BIND(STRAFTER(STR(?type), "entity/") AS ?class) }
      OPTIONAL {
        ?item wdt:P50 ?author .
        OPTIONAL { ?author rdfs:label ?authorLabel . FILTER(lang(?authorLabel) = "en") }
        OPTIONAL { ?author wdt:P570 ?death . }
        BIND(CONCAT(
          STRAFTER(STR(?author), "entity/"), "~",
          COALESCE(?authorLabel, ""), "~",
          COALESCE(STR(YEAR(?death)), "")
        ) AS ?authorTriple)
      }
    }
    GROUP BY ?item
    """
  end

  defp selection(bindings) do
    bindings
    |> Enum.flat_map(fn binding ->
      qid = binding |> value("item") |> qid_from_entity() |> List.first()
      olid = presence(value(binding, "olid"))
      sitelinks = integer(value(binding, "sitelinks"))

      if qid && olid && sitelinks && valid_olid?(olid),
        do: [%{"qid" => qid, "olid" => olid, "sitelinks" => sitelinks}],
        else: []
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  defp description(bindings) do
    Enum.flat_map(bindings, fn binding ->
      case binding |> value("item") |> qid_from_entity() do
        [] ->
          []

        [qid] ->
          [
            %{
              "qid" => qid,
              "title" => presence(value(binding, "title")),
              "publication_year" => integer(value(binding, "published")),
              "classes" => split(value(binding, "classes")),
              "authors" => authors(value(binding, "authors"))
            }
          ]
      end
    end)
  end

  defp authors(nil), do: []
  defp authors(""), do: []

  defp authors(value) do
    value
    |> String.split("|", trim: true)
    |> Enum.flat_map(fn triple ->
      case String.split(triple, "~", parts: 3) do
        [qid, name, died] ->
          if valid_qid?(qid),
            do: [%{"qid" => qid, "name" => presence(name), "died" => integer(presence(died))}],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  defp split(nil), do: []
  defp split(""), do: []
  defp split(value), do: value |> String.split("|", trim: true) |> Enum.filter(&valid_qid?/1)

  # One item can arrive in more than one band only if its sitelink count
  # changed mid-walk. Merging on the QID keeps that from minting two rows.
  defp merge(rows) do
    rows
    |> Enum.group_by(& &1["qid"])
    |> Enum.map(fn {_qid, [first | _] = group} ->
      Enum.reduce(group, first, fn row, merged ->
        Map.merge(merged, row, fn _key, held, offered ->
          if held in [nil, "", []], do: offered, else: held
        end)
      end)
    end)
    |> Enum.sort_by(&{-&1["sitelinks"], &1["qid"]})
  end

  defp value(row, key), do: get_in(row, [key, "value"])

  defp qid_from_entity(nil), do: []

  defp qid_from_entity(url) do
    case Regex.run(~r{entity/(Q[1-9]\d*)\z}, url) do
      [_, qid] -> [qid]
      _ -> []
    end
  end

  defp integer(nil), do: nil

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim_leading(value, "+")) do
      {integer, _rest} -> integer
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  # `OL…W` is a work, `OL…M` an edition, `OL…A` an author. P648 carries all
  # three and only a work is a work.
  defp valid_olid?(value), do: Regex.match?(~r/\AOL[1-9]\d*W\z/, value)

  defp valid_qid?(value), do: Regex.match?(~r/\AQ[1-9]\d*\z/, value)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
