defmodule DevilsDictionary.Artworks.Corpus.WikidataFamous do
  @moduledoc """
  Builds the `wikidata-famous` corpus manifest: paintings famous enough to be
  worth keeping, identified by QID and illustrated from Commons.

  The Met answers *what depicts a soldier*; it does not answer *where is the Mona
  Lisa*, because the Mona Lisa is in the Louvre. This manifest is the other half:
  `P31 Q3305213` (painting) with a Commons image (`P18`) and a sitelink count
  above a measured threshold, carrying `P170` creators and `P180` depictions.
  Sitelinks are the popularity proxy because they are a fact about the item on
  the graph rather than a ranking somebody would have to maintain.

  ## Why the query is paged by exact sitelink count

  A whole-graph sitelink filter times out: `?sitelinks >= 30` answers (108
  paintings in the 16:46 audit's measurement) while `>= 15` and `>= 10` do not.
  Half-open bands do not fix it either — measured here, `FILTER(?sitelinks >= 60)`
  took 58.4 s and `>= 10` never returned, because a range filter scans every
  painting's sitelink count whatever the range is.

  Binding the count instead of filtering it turns the scan into a lookup:
  `VALUES ?sitelinks { 20 21 22 }` answered in 11 s, `{ 60 … 99 }` in 8.5 s. The
  cost tracks how many entities *hold* those counts, not how many counts are
  asked for, so the walk asks for a few crowded low counts at a time and a wide
  sparse range at the top, and every request answers.

  Description is a second request for a **bound** set of QIDs through `VALUES`,
  for the same reason: the labels, creators and depictions that made a one-shot
  query time out are cheap once the items are named.

  No image bytes are fetched. `P18` is turned into the Commons thumbnail URL the
  absorber already derives, and it travels with the Commons file name as its
  attribution.
  """

  alias DevilsDictionary.Absorb.Sources.Wikidata, as: WikidataSource
  alias DevilsDictionary.Artworks.Corpus.Manifest

  @endpoint "https://query.wikidata.org/sparql"

  # The count axis, walked downwards. Low counts are crowded — every entity in
  # Wikidata with exactly 20 sitelinks is a candidate row before the painting
  # filter applies — so they are asked for a few at a time; high counts are
  # nearly empty, so the top of the range is one request.
  @ceiling 400
  @dense_below 30
  @dense_chunk 3
  @sparse_chunk 10
  @sparse_below 60

  @measure_floor 10

  @default_min_sitelinks 10
  @default_request_limit 80
  @describe_batch 50
  @max_attempts 2
  @smoke_test_qid "Q12418"

  @doc "The sitelink-count chunks the walk asks for at or above `minimum`, highest first."
  def chunks(minimum \\ @measure_floor) do
    minimum..@ceiling//1
    |> Enum.to_list()
    |> Enum.chunk_while([], &chunk_step/2, &chunk_done/1)
    |> Enum.reverse()
  end

  defp chunk_step(count, []), do: {:cont, [count]}

  defp chunk_step(count, [head | _] = acc) do
    if length(acc) >= chunk_size(head),
      do: {:cont, Enum.reverse(acc), [count]},
      else: {:cont, [count | acc]}
  end

  defp chunk_done([]), do: {:cont, []}
  defp chunk_done(acc), do: {:cont, Enum.reverse(acc), []}

  defp chunk_size(count) when count < @dense_below, do: @dense_chunk
  defp chunk_size(count) when count < @sparse_below, do: @sparse_chunk
  defp chunk_size(_count), do: @ceiling

  @doc "The QID whose presence proves the set is the famous set."
  def smoke_test_qid, do: @smoke_test_qid

  @doc """
  Walks the bands and reports the paged sitelink distribution without writing.

  This is the measurement the threshold decision rests on, and it is paged
  because the whole-graph form of the same question does not answer.
  """
  def measure(opts \\ []) do
    floor = opts[:min_sitelinks] || @measure_floor

    case walk(chunks(floor), [], state(opts)) do
      {:ok, rows, state} ->
        histogram = rows |> Enum.frequencies_by(& &1["sitelinks"]) |> Enum.sort(:desc)

        cumulative =
          [10, 12, 14, 15, 16, 18, 20, 25, 30, 45, 60]
          |> Enum.filter(&(&1 >= floor))
          |> Map.new(fn threshold ->
            {threshold, Enum.count(rows, &(&1["sitelinks"] >= threshold))}
          end)

        {:ok,
         %{
           requests: state.requests,
           measured_from: floor,
           paintings: length(rows),
           top_counts: Enum.take(histogram, 8),
           cumulative_at_or_above: cumulative,
           mona_lisa_present: Enum.any?(rows, &(&1["qid"] == @smoke_test_qid)),
           failures: Enum.reverse(state.failures)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds the manifest for every painting at or above `:min_sitelinks`.

  Returns `{:ok, manifest, ledger}`, or `{:error, reason}` when the smoke test
  fails — a famous-paintings set without the Mona Lisa in it is not the set.
  """
  def build(opts \\ []) do
    minimum = opts[:min_sitelinks] || @default_min_sitelinks

    case walk(chunks(minimum), [], state(opts)) do
      {:ok, selected, state} ->
        selected = Enum.filter(selected, &(&1["sitelinks"] >= minimum))
        {rows, state} = describe(selected, state)

        if Enum.any?(rows, &(&1["qid"] == @smoke_test_qid)) do
          manifest =
            Manifest.new("wikidata-famous", rows, %{
              "min_sitelinks" => minimum,
              "paging" => "VALUES over exact sitelink counts #{minimum}..#{@ceiling}",
              "selection" => "P31 Q3305213 with P18, sitelinks >= #{minimum}",
              "identity" => "Wikidata QID",
              "creators" => "P170",
              "depicts" => "P180",
              "images" =>
                "P18 as a Commons thumbnail URL plus the file name as attribution; no image bytes are fetched",
              "smoke_test" => "#{@smoke_test_qid} (Mona Lisa) is present"
            })

          {:ok, manifest, ledger(state, rows, minimum)}
        else
          {:error, "smoke test failed: #{@smoke_test_qid} is not in the built set"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ledger(state, rows, minimum) do
    %{
      wikidata_requests: state.requests,
      min_sitelinks: minimum,
      paintings: length(rows),
      with_creator: Enum.count(rows, &(&1["creators"] != [])),
      with_depicts: Enum.count(rows, &(&1["depicts"] != [])),
      distinct_depicted_qids:
        rows |> Enum.flat_map(& &1["depicts"]) |> Enum.map(& &1["qid"]) |> Enum.uniq() |> length(),
      mona_lisa_present: Enum.any?(rows, &(&1["qid"] == @smoke_test_qid)),
      image_bytes_downloaded: 0,
      failures: Enum.reverse(state.failures)
    }
  end

  defp state(opts) do
    %{
      request_limit: opts[:request_limit] || @default_request_limit,
      request_fun: opts[:request_fun] || (&Req.request/1),
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      requests: 0,
      failures: []
    }
  end

  defp walk([], rows, state), do: {:ok, merge(rows), state}

  defp walk([counts | rest], rows, state) do
    case request(state, counts_sparql(counts)) do
      {:ok, bindings, state} ->
        walk(rest, rows ++ selection(bindings), state)

      {:error, :request_limit, state} ->
        {:ok, merge(rows), state}

      {:error, reason, state} ->
        # A chunk that will not answer is recorded rather than swallowed: the
        # threshold's credibility depends on knowing which counts were measured.
        walk(rest, rows, %{
          state
          | failures: [
              %{
                "counts" => "#{List.first(counts)}..#{List.last(counts)}",
                "reason" => to_string(reason)
              }
              | state.failures
            ]
        })
    end
  end

  # Labels, creators, depictions and dates for a *bound* set of QIDs. The set is
  # given in `VALUES`, so the service looks each one up instead of scanning, and
  # a batch that fails costs only its own rows.
  defp describe(selected, state) do
    by_qid = Map.new(selected, &{&1["qid"], &1})

    selected
    |> Enum.map(& &1["qid"])
    |> Enum.chunk_every(@describe_batch)
    |> Enum.reduce({[], state}, fn qids, {rows, state} ->
      case request(state, describe_sparql(qids)) do
        {:ok, bindings, state} ->
          described = Map.new(description(bindings), &{&1["qid"], &1})

          {rows ++ Enum.map(qids, &row(by_qid[&1], described[&1])), state}

        {:error, :request_limit, state} ->
          {rows, state}

        {:error, reason, state} ->
          {rows,
           %{
             state
             | failures: [
                 %{"describe_batch" => length(qids), "reason" => to_string(reason)}
                 | state.failures
               ]
           }}
      end
    end)
    |> then(fn {rows, state} -> {merge(rows), state} end)
  end

  defp row(selected, described) do
    file = selected["commons_file"]

    %{
      "qid" => selected["qid"],
      "title" => (described && described["title"]) || selected["qid"],
      "sitelinks" => selected["sitelinks"],
      "date" => described && described["date"],
      "image_url" => WikidataSource.thumbnail_url(file),
      "commons_file" => file,
      "credit_line" => file <> " · Wikimedia Commons",
      "source_url" => "https://www.wikidata.org/wiki/" <> selected["qid"],
      "creators" => (described && described["creators"]) || [],
      "depicts" => (described && described["depicts"]) || []
    }
  end

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

      # 502 and 504 are the query service saying "not in the time I allow", and
      # the same query often answers on a second ask. One retry, counted.
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

  defp counts_sparql(counts) do
    """
    SELECT ?item ?sitelinks ?image WHERE {
      VALUES ?sitelinks { #{Enum.join(counts, " ")} }
      ?item wikibase:sitelinks ?sitelinks ;
            wdt:P31 wd:Q3305213 ;
            wdt:P18 ?image .
    }
    """
  end

  defp describe_sparql(qids) do
    values = qids |> Enum.map(&"wd:#{&1}") |> Enum.join(" ")

    """
    SELECT ?item ?label ?inception
           (GROUP_CONCAT(DISTINCT ?creatorPair; separator="|") AS ?creators)
           (GROUP_CONCAT(DISTINCT ?depictsPair; separator="|") AS ?depicts)
    WHERE {
      VALUES ?item { #{values} }
      OPTIONAL { ?item rdfs:label ?label . FILTER(lang(?label) = "en") }
      OPTIONAL { ?item wdt:P571 ?inception . }
      OPTIONAL {
        ?item wdt:P170 ?creator .
        OPTIONAL { ?creator rdfs:label ?creatorLabel . FILTER(lang(?creatorLabel) = "en") }
        BIND(CONCAT(STRAFTER(STR(?creator), "entity/"), "~", COALESCE(?creatorLabel, "")) AS ?creatorPair)
      }
      OPTIONAL {
        ?item wdt:P180 ?depiction .
        OPTIONAL { ?depiction rdfs:label ?depictionLabel . FILTER(lang(?depictionLabel) = "en") }
        BIND(CONCAT(STRAFTER(STR(?depiction), "entity/"), "~", COALESCE(?depictionLabel, "")) AS ?depictsPair)
      }
    }
    GROUP BY ?item ?label ?inception
    """
  end

  defp selection(bindings) do
    bindings
    |> Enum.flat_map(fn binding ->
      qid = qid_from_entity(value(binding, "item"))
      file = commons_file(value(binding, "image"))
      sitelinks = integer(value(binding, "sitelinks"))

      if qid && file && sitelinks,
        do: [%{"qid" => qid, "sitelinks" => sitelinks, "commons_file" => file}],
        else: []
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  defp description(bindings) do
    Enum.flat_map(bindings, fn binding ->
      case qid_from_entity(value(binding, "item")) do
        nil ->
          []

        qid ->
          [
            %{
              "qid" => qid,
              "title" => presence(value(binding, "label")),
              "date" => year(value(binding, "inception")),
              "creators" => pairs(value(binding, "creators")),
              "depicts" => pairs(value(binding, "depicts"))
            }
          ]
      end
    end)
  end

  # One item can arrive in more than one band's response only if its sitelink
  # count changed mid-walk. Merging on the QID keeps that from minting two rows.
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

  defp pairs(nil), do: []
  defp pairs(""), do: []

  defp pairs(value) do
    value
    |> String.split("|", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "~", parts: 2) do
        [qid, label] ->
          if valid_qid?(qid), do: [%{"qid" => qid, "term" => presence(label)}], else: []

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1["qid"])
  end

  defp value(row, key), do: get_in(row, [key, "value"])

  defp qid_from_entity(nil), do: nil

  defp qid_from_entity(url) do
    case Regex.run(~r{entity/(Q[1-9]\d*)\z}, url) do
      [_, qid] -> qid
      _ -> nil
    end
  end

  # P18 arrives as `…/Special:FilePath/Mona%20Lisa.jpg`; the file name is what
  # Commons indexes and what the attribution names.
  defp commons_file(nil), do: nil

  defp commons_file(url) do
    url
    |> String.split("Special:FilePath/")
    |> List.last()
    |> URI.decode()
    |> String.replace("_", " ")
    |> presence()
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      _ -> nil
    end
  end

  defp year(nil), do: nil

  defp year(value) do
    case Regex.run(~r/\A-?(\d{1,4})-/, value) do
      [_, year] -> String.trim_leading(year, "0")
      _ -> nil
    end
  end

  defp valid_qid?(value), do: Regex.match?(~r/\AQ[1-9]\d*\z/, value)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
