defmodule DevilsDictionary.Artworks.Corpus.MetHighlights do
  @moduledoc """
  Builds the `met-highlights` corpus manifest from the Met's own highlight flag.

  Two measured facts shape this. First, `isPublicDomain=true` on the search does
  not filter — Phase 2a returned objects 108646 and 261944 from that query whose
  own payloads say `isPublicDomain: false` — so the gate is applied to the
  hydrated object and only there. Second, the v1.1 search answers with a capped
  slice of `objectIDs` (100 by default, 500 with `limit`) beside a much larger
  `total`, so the identity list is paged rather than read off one response.

  Every object is hydrated exactly once, at about one request a second, and only
  the fields a shelf may keep are written down: the object id, title, artist,
  date, the Met's own Wikidata QID when it publishes one, `primaryImageSmall` as
  a URL, `creditLine` as the attribution that travels with it, and the tag QIDs
  that let the catalog answer a QID lookup without a live search. **No image
  bytes are ever fetched.**

  Hydration is the expensive half, so it is resumable: each object's kept fields
  are appended to a JSONL progress file as they arrive, and a rerun reads that
  file before spending a request. The progress file is scratch, not a
  deliverable; the committed manifest is.
  """

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Discovery.Providers.Met

  @base "https://collectionapi.metmuseum.org/public/collection"
  @search_path "/v1.1/search"
  @object_path "/v1/objects"

  # 500 is the largest page the search honoured in measurement; a larger `limit`
  # is silently capped, which would look like the end of the list.
  @search_page 500

  @search_params %{"isHighlight" => "true", "hasImages" => "true", "q" => "*"}

  @default_request_limit 3_000
  @default_interval_ms 1_000
  @retry_interval_ms 1_500
  @default_max_attempts 3

  @doc """
  Builds the manifest and returns `{:ok, manifest, ledger}`.

  ## Options

    * `:request_limit` — hard ceiling on physical Met requests (default 3,000)
    * `:interval_ms` — pause between requests (default 1,000)
    * `:max_attempts` — attempts per object before it is left to a later pass
      (default 3). One attempt is the cheaper setting when the Met is refusing
      in volume: the progress file means a refused object costs nothing to
      re-ask on the next pass, while an in-run retry costs a request now.
    * `:progress` — path of the resumable hydration cache
    * `:id_limit` — stop after this many candidate ids (for tests and rehearsals)
    * `:request_fun` — 1-arity `Req` options → response, for tests
  """
  def build(opts \\ []) do
    state = %{
      request_limit: opts[:request_limit] || @default_request_limit,
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      request_fun: opts[:request_fun] || (&Req.request/1),
      max_attempts: opts[:max_attempts] || @default_max_attempts,
      requests: 0,
      search_requests: 0,
      hydrations: 0,
      retries: 0,
      refused: 0,
      failed: 0
    }

    progress = opts[:progress] || default_progress()
    cached = load_progress(progress)

    if opts[:from_cache] do
      from_cache(cached, state)
    else
      from_search(cached, progress, state, opts)
    end
  end

  @doc """
  Writes the manifest from what has already been hydrated, spending nothing.

  The hydration cache is the expensive artifact — thousands of paced requests —
  and turning it into a manifest is a local operation. A run that was stopped
  before it could write its manifest must not have to re-ask the Met for the id
  list just to write down what it already holds.
  """
  def from_cache(cached, state) do
    rows = cached |> Map.values() |> Enum.sort_by(&object_id(&1["met_object_id"]))
    kept = Enum.filter(rows, & &1["public_domain"])

    manifest =
      Manifest.new(
        "met-highlights",
        Enum.map(kept, &Map.delete(&1, "public_domain")),
        selection(nil, length(rows), rows, kept, "hydration cache of the isHighlight query")
      )

    {:ok, manifest, ledger(state, nil, rows, rows, kept)}
  end

  defp from_search(cached, progress, state, opts) do
    with {:ok, ids, total, state} <- collect_ids(state, opts[:id_limit]) do
      {rows, state} = hydrate(ids, cached, progress, state)

      kept = Enum.filter(rows, & &1["public_domain"])

      manifest =
        Manifest.new(
          "met-highlights",
          Enum.map(kept, &Map.delete(&1, "public_domain")),
          selection(total, length(ids), rows, kept, "live isHighlight search")
        )

      {:ok, manifest, ledger(state, total, ids, rows, kept)}
    end
  end

  defp selection(total, candidates, rows, kept, built_from) do
    %{
      "query" => @search_params,
      "search_total" => total,
      "candidate_ids" => candidates,
      "hydrated" => length(rows),
      "public_domain_with_image" => length(kept),
      "built_from" => built_from,
      "gate" => "isPublicDomain and primaryImageSmall on the hydrated object",
      "images" => "primaryImageSmall URL plus creditLine; no image bytes are fetched",
      "identity" => "Met object ID, plus the object's own P3634 QID when published"
    }
  end

  defp object_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _ -> 0
    end
  end

  defp ledger(state, total, ids, rows, kept) do
    %{
      met_requests: state.requests,
      search_requests: state.search_requests,
      hydrations: state.hydrations,
      retries: state.retries,
      refused_403: state.refused,
      failed: state.failed,
      search_total: total,
      candidate_ids: length(ids),
      hydrated: length(rows),
      public_domain_kept: length(kept),
      not_public_domain: length(rows) - length(kept),
      image_bytes_downloaded: 0
    }
  end

  defp collect_ids(state, id_limit), do: collect_ids(state, id_limit, 0, [], nil)

  defp collect_ids(state, id_limit, offset, acc, total) do
    params =
      Map.merge(@search_params, %{
        "offset" => Integer.to_string(offset),
        "limit" => Integer.to_string(@search_page)
      })

    case request(state, "search", url: @base <> @search_path, params: params) do
      {:ok, body, state} ->
        state = %{state | search_requests: state.search_requests + 1}
        ids = body["objectIDs"] |> List.wrap() |> Enum.filter(&is_integer/1)
        total = total || body["total"]
        acc = acc ++ ids

        cond do
          ids == [] ->
            {:ok, dedupe(acc, id_limit), total, state}

          is_integer(id_limit) and length(acc) >= id_limit ->
            {:ok, dedupe(acc, id_limit), total, state}

          is_integer(total) and length(acc) >= total ->
            {:ok, dedupe(acc, id_limit), total, state}

          true ->
            collect_ids(state, id_limit, offset + @search_page, acc, total)
        end

      {:error, reason, _state} ->
        {:error, "met_search_#{reason}"}
    end
  end

  defp dedupe(ids, nil), do: Enum.uniq(ids)
  defp dedupe(ids, limit) when is_integer(limit), do: ids |> Enum.uniq() |> Enum.take(limit)

  # Exhausting the budget stops the *requests*, not the walk. A cached row costs
  # nothing, and the ids are not hydrated in one contiguous block — a pass that
  # gave up on an object leaves a hole that a later pass fills — so halting at
  # the first refused request would throw away rows already paid for.
  defp hydrate(ids, cached, progress, state) do
    Enum.reduce(ids, {[], state}, fn id, {rows, state} ->
      key = Integer.to_string(id)

      case Map.fetch(cached, key) do
        {:ok, row} ->
          {[row | rows], state}

        :error ->
          if state.requests >= state.request_limit do
            {rows, state}
          else
            case request(state, "object:#{key}", url: "#{@base}#{@object_path}/#{id}") do
              {:ok, object, state} when is_map(object) ->
                row = row(object, key)
                append_progress(progress, row)
                {[row | rows], %{state | hydrations: state.hydrations + 1}}

              {:ok, _body, state} ->
                {rows, %{state | failed: state.failed + 1}}

              {:error, :request_limit, state} ->
                {rows, state}

              {:error, _reason, state} ->
                {rows, %{state | failed: state.failed + 1}}
            end
          end
      end
    end)
    |> then(fn {rows, state} -> {Enum.reverse(rows), state} end)
  end

  defp row(object, key) do
    %{
      "met_object_id" => key,
      "public_domain" =>
        object["isPublicDomain"] == true and presence(object["primaryImageSmall"]) != nil,
      "title" => presence(object["title"]) || "Untitled",
      "artist" => presence(object["artistDisplayName"]),
      "date" => presence(object["objectDate"]),
      "qid" => Met.qid_from_url(object["objectWikidata_URL"]),
      "image_url" => presence(object["primaryImageSmall"]),
      "credit_line" => presence(object["creditLine"]),
      "source_url" => presence(object["objectURL"]),
      "medium" => presence(object["medium"]),
      "department" => presence(object["department"]),
      "tags" => Enum.map(Met.tags(object), fn {term, qid} -> %{"term" => term, "qid" => qid} end)
    }
  end

  # The 403 the P0 probe measured is a throttle signal with no `Retry-After`, so
  # it is retried on the Met's own declared floor rather than treated as an
  # authentication verdict. Everything else is counted and dropped: one object
  # that will not come back must not end a 2,290-object build.
  defp request(state, _stage, options), do: attempt(state, options, 1)

  defp attempt(%{requests: requests, request_limit: limit} = state, _options, _attempt)
       when requests >= limit,
       do: {:error, :request_limit, state}

  defp attempt(state, options, attempt) do
    pace(state.interval_ms)

    options =
      options
      |> Keyword.merge(
        method: :get,
        headers: [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}],
        receive_timeout: 15_000,
        retry: false
      )

    state = %{state | requests: state.requests + 1}

    case state.request_fun.(options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body, state}

      {:ok, %Req.Response{status: 403}} ->
        state = %{state | refused: state.refused + 1}

        if attempt < state.max_attempts do
          Process.sleep(@retry_interval_ms)
          attempt(%{state | retries: state.retries + 1}, options, attempt + 1)
        else
          {:error, :forbidden, state}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "http_#{status}", state}

      {:error, _reason} ->
        {:error, :unavailable, state}
    end
  end

  defp pace(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp pace(_ms), do: :ok

  defp default_progress,
    do: Path.join(System.tmp_dir!(), "dd-artworks-met-highlights.jsonl")

  defp load_progress(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"met_object_id" => id} = row} when is_binary(id) -> [{id, row}]
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp append_progress(path, row) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(row) <> "\n", [:append])
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
