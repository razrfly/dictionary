defmodule DevilsDictionary.Artworks.WikidataCandidates do
  @moduledoc "Bounded local-first discovery of painting candidates carrying Wikidata P11005."

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, WorkDetails}
  alias DevilsDictionary.Repo

  @endpoint "https://query.wikidata.org/sparql"
  @default_limit 50
  @max_limit 5_000
  @default_page_size 50
  @max_requests 100

  @doc "Returns local candidates first, then bounded paginated Wikidata SPARQL candidates."
  def discover(opts \\ []) do
    limit = bounded(opts[:limit] || @default_limit, 1, @max_limit, :limit)
    request_limit = bounded(opts[:request_limit] || 10, 1, @max_requests, :request_limit)
    page_size = bounded(opts[:page_size] || @default_page_size, 1, 200, :page_size)
    offset = bounded(opts[:offset] || 0, 0, 100_000, :offset)
    remote? = Keyword.get(opts, :remote, true)
    request_fun = opts[:request_fun] || (&default_request/1)

    local = local_candidates(limit)
    remaining = max(limit - length(local), 0)

    {remote, stats} =
      if remote? and remaining > 0 do
        remote_candidates(remaining, offset, page_size, request_limit, request_fun)
      else
        {[], %{requests: 0, next_offset: offset, truncated: remaining > 0}}
      end

    candidates = merge_candidates(local ++ remote) |> Enum.take(limit)
    local_identities = MapSet.new(local, &{&1["qid"], &1["artsy_artwork_slug"]})

    remote_count =
      Enum.count(
        candidates,
        &(!MapSet.member?(local_identities, {&1["qid"], &1["artsy_artwork_slug"]}))
      )

    {:ok, candidates,
     Map.merge(stats, %{
       local: length(local),
       remote: remote_count,
       discovered: length(candidates),
       limit: limit,
       kinds: ["painting"]
     })}
  end

  defp local_candidates(limit) do
    rows =
      Repo.all(
        from entity in Entity,
          join: details in WorkDetails,
          on: details.entity_id == entity.object_id and details.work_kind == "artwork",
          join: artsy in ExternalIdentifier,
          on:
            artsy.object_id == entity.object_id and artsy.namespace == "artsy_artwork_slug" and
              artsy.status == :verified,
          join: qid in ExternalIdentifier,
          on:
            qid.object_id == entity.object_id and qid.namespace == "wikidata" and
              qid.status == :verified,
          order_by: [asc: entity.object_id],
          limit: ^limit,
          select: %{
            "object_id" => entity.object_id,
            "qid" => qid.external_id,
            "artsy_artwork_slug" => artsy.external_id,
            "title" => entity.preferred_label,
            "description" => entity.description,
            "wikipedia_title" => entity.metadata["wikipedia_title"],
            "kind" => "painting",
            "selection_reason" => "existing_local_wikidata_p11005",
            "origin" => "local_registry"
          }
      )

    creators = local_creators(Enum.map(rows, & &1["object_id"]))

    Enum.map(rows, fn row ->
      row
      |> Map.put("creators", Map.get(creators, row["object_id"], []))
      |> Map.delete("object_id")
    end)
  end

  defp local_creators([]), do: %{}

  defp local_creators(work_ids) do
    AssertionRevision
    |> join(:inner, [revision], predicate in Claims.Predicate,
      on: predicate.id == revision.predicate_id and predicate.key == "authored_by"
    )
    |> join(:inner, [revision], creator in Entity,
      on: creator.object_id == revision.object_object_id
    )
    |> join(:inner, [_revision, _predicate, creator], qid in ExternalIdentifier,
      on:
        qid.object_id == creator.object_id and qid.namespace == "wikidata" and
          qid.status == :verified
    )
    |> join(:left, [_revision, _predicate, creator, _qid], artsy in ExternalIdentifier,
      on:
        artsy.object_id == creator.object_id and artsy.namespace == "artsy_artist_slug" and
          artsy.status == :verified
    )
    |> where(
      [revision],
      revision.subject_object_id in ^work_ids and revision.is_current and
        revision.lifecycle_state == :active
    )
    |> Claims.visible(:public)
    |> order_by(
      [revision, _predicate, creator, qid, artsy],
      asc: revision.subject_object_id,
      asc: creator.preferred_label,
      asc: creator.object_id
    )
    |> select([revision, _predicate, creator, qid, artsy], {
      revision.subject_object_id,
      %{
        "qid" => qid.external_id,
        "name" => creator.preferred_label,
        "artsy_artist_slug" => artsy.external_id
      }
    })
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp remote_candidates(limit, offset, page_size, request_limit, request_fun) do
    do_remote([], limit, offset, page_size, request_limit, 0, request_fun)
  end

  defp do_remote(rows, limit, offset, _page_size, request_limit, requests, _request_fun)
       when length(rows) > limit or requests >= request_limit do
    {Enum.take(rows, limit), %{requests: requests, next_offset: offset, truncated: true}}
  end

  defp do_remote(rows, limit, offset, page_size, request_limit, requests, request_fun) do
    take = page_size

    case request_fun.(request_options(take, offset)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        bindings = get_in(body, ["results", "bindings"]) || []
        page = normalize_bindings(bindings)
        next_offset = offset + take

        if bindings == [] do
          {Enum.take(rows, limit),
           %{requests: requests + 1, next_offset: next_offset, truncated: false}}
        else
          do_remote(
            merge_candidates(rows ++ page),
            limit,
            next_offset,
            page_size,
            request_limit,
            requests + 1,
            request_fun
          )
        end

      {:ok, %Req.Response{status: status}} ->
        {rows,
         %{
           requests: requests + 1,
           next_offset: offset,
           truncated: true,
           error: "wikidata_http_#{status}"
         }}

      {:error, _reason} ->
        {rows,
         %{
           requests: requests + 1,
           next_offset: offset,
           truncated: true,
           error: "wikidata_unavailable"
         }}
    end
  end

  defp request_options(limit, offset) do
    [
      method: :get,
      url: @endpoint,
      params: [query: sparql(limit, offset), format: "json"],
      headers: [
        {"accept", "application/sparql-results+json"},
        {"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}
      ],
      receive_timeout: 15_000,
      # Discovery accounting is per physical request. Disable Req's hidden
      # retries so the bounded loop and reported count cannot diverge.
      retry: false
    ]
  end

  defp default_request(options), do: Req.request(options)

  defp sparql(limit, offset) do
    """
    SELECT ?item ?itemLabel ?itemDescription ?artsy ?article ?creator ?creatorLabel ?creatorArtsy WHERE {
      ?item wdt:P31 wd:Q3305213 ; wdt:P11005 ?artsy .
      OPTIONAL { ?article schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> . }
      OPTIONAL {
        ?item wdt:P170 ?creator .
        OPTIONAL { ?creator wdt:P2042 ?creatorArtsy . }
      }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
    }
    ORDER BY DESC(BOUND(?article)) ?item ?creator
    LIMIT #{limit}
    OFFSET #{offset}
    """
  end

  defp normalize_bindings(bindings) do
    bindings
    |> Enum.group_by(&{qid(value(&1, "item")), value(&1, "artsy")})
    |> Enum.reject(fn {{qid, artsy}, _} -> is_nil(qid) or is_nil(artsy) end)
    |> Enum.map(fn {{qid, artsy}, rows} ->
      first = hd(rows)

      %{
        "qid" => qid,
        "artsy_artwork_slug" => artsy,
        "title" => value(first, "itemLabel"),
        "description" => value(first, "itemDescription"),
        "wikipedia_title" => wikipedia_title(value(first, "article")),
        "kind" => "painting",
        "selection_reason" =>
          if(value(first, "article"),
            do: "wikidata_p11005_with_english_wikipedia",
            else: "wikidata_p11005_painting"
          ),
        "origin" => "wikidata_sparql",
        "creators" =>
          rows
          |> Enum.map(fn row ->
            %{
              "qid" => qid(value(row, "creator")),
              "name" => value(row, "creatorLabel"),
              "artsy_artist_slug" => value(row, "creatorArtsy")
            }
          end)
          |> Enum.reject(&is_nil(&1["qid"]))
          |> Enum.uniq_by(& &1["qid"])
      }
    end)
    |> Enum.sort_by(& &1["qid"])
  end

  defp merge_candidates(rows) do
    rows
    |> Enum.group_by(&{&1["qid"], &1["artsy_artwork_slug"]})
    |> Enum.map(fn {_identity, observations} ->
      preferred =
        Enum.find(observations, &(&1["origin"] == "wikidata_sparql")) || hd(observations)

      creators =
        observations
        |> Enum.flat_map(&(&1["creators"] || []))
        |> Enum.group_by(& &1["qid"])
        |> Enum.map(fn {_qid, rows} ->
          Enum.reduce(rows, %{}, fn row, merged ->
            Map.merge(merged, row, fn _key, held, offered -> held || offered end)
          end)
        end)
        |> Enum.sort_by(&{&1["name"] || "", &1["qid"] || ""})

      observations
      |> Enum.reduce(preferred, fn row, merged ->
        Map.merge(merged, row, fn _key, held, offered -> held || offered end)
      end)
      |> Map.put("creators", creators)
    end)
    |> Enum.sort_by(&{&1["qid"], &1["artsy_artwork_slug"]})
  end

  defp value(row, key), do: get_in(row, [key, "value"])

  defp qid("http://www.wikidata.org/entity/" <> qid), do: if(valid_qid?(qid), do: qid)
  defp qid("https://www.wikidata.org/entity/" <> qid), do: if(valid_qid?(qid), do: qid)
  defp qid(_), do: nil
  defp valid_qid?(qid), do: Regex.match?(~r/\AQ[1-9]\d*\z/, qid)

  defp wikipedia_title(nil), do: nil

  defp wikipedia_title(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "en.wikipedia.org", path: "/wiki/" <> title} ->
        title |> URI.decode() |> String.replace("_", " ")

      _ ->
        nil
    end
  end

  defp bounded(value, min, max, _name) when is_integer(value) and value >= min and value <= max,
    do: value

  defp bounded(_value, _min, _max, name),
    do: raise(ArgumentError, "#{name} is outside the supported bound")
end
