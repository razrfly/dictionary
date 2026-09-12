defmodule DevilsDictionary.Artworks.Seeder do
  @moduledoc "Idempotent, resumable Wikidata-to-Artsy selected artwork importer."

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Artsy.Client
  alias DevilsDictionary.Artworks.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Registry
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Sources

  @default_record_limit 500
  @max_record_limit 5_000
  @default_batch_size 25

  def run(manifest, opts \\ []) when is_map(manifest) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    resume? = Keyword.get(opts, :resume, false)
    record_limit = bounded(opts[:record_limit] || @default_record_limit, 1, @max_record_limit)
    batch_size = bounded(opts[:batch_size] || @default_batch_size, 1, 100)
    manifest_path = opts[:manifest_path]

    if dry_run? do
      {manifest,
       %{
         dry_run: true,
         candidates: length(manifest["candidates"]),
         eligible: Enum.count(manifest["candidates"], &eligible_candidate?/1),
         requests: 0,
         next_index: 0
       }}
    else
      %{sources: sources} = DevilsDictionary.Sources.Catalog.seed!()
      artsy_source = Map.fetch!(sources, "artsy")
      client = opts[:artsy_client] || Client.new(request_limit: opts[:request_limit] || 500)
      run = Sources.start_run("dd.artworks.seed", source_id: artsy_source.id)

      initial = %{
        candidates: length(manifest["candidates"]),
        processed: 0,
        matched: 0,
        created: 0,
        conflicts: 0,
        unavailable: 0,
        missing_links: 0,
        skipped: 0,
        reproductions: 0,
        creators_resolved: 0,
        creator_links: 0,
        genes: 0,
        quota_exhausted: false,
        requests: 0,
        retries: 0,
        next_index: nil
      }

      try do
        {manifest, client, summary} =
          manifest["candidates"]
          |> Enum.with_index()
          |> Enum.chunk_every(batch_size)
          |> Enum.reduce_while({manifest, client, initial}, fn batch, acc ->
            process_batch(batch, acc, sources, run, resume?, record_limit, manifest_path)
          end)

        summary = %{
          summary
          | requests: client.request_count,
            retries: client.retry_count
        }

        Sources.finish_run(run, stringify(summary))
        {maybe_save(manifest, manifest_path), summary}
      rescue
        exception ->
          Sources.fail_run(run, Exception.message(exception))
          reraise exception, __STACKTRACE__
      end
    end
  end

  defp process_batch(
         batch,
         {manifest, client, summary},
         sources,
         run,
         resume?,
         record_limit,
         path
       ) do
    result =
      Enum.reduce_while(batch, {manifest, client, summary}, fn {candidate, index},
                                                               {manifest, client, summary} ->
        cond do
          summary.processed >= record_limit ->
            {:halt, {manifest, client, %{summary | next_index: index}}}

          resume? and Manifest.completed?(candidate) ->
            {:cont, {manifest, client, summary}}

          true ->
            {outcome, client} = import_candidate(candidate, client, sources, run)

            manifest =
              Manifest.update_candidate(
                manifest,
                index,
                Map.put(outcome, :updated_at, timestamp())
              )

            summary = accumulate(summary, outcome, index)
            manifest = maybe_save(manifest, path)

            if outcome.status == :quota_exhausted do
              {:halt, {manifest, client, %{summary | quota_exhausted: true, next_index: index}}}
            else
              {:cont, {manifest, client, summary}}
            end
        end
      end)

    case result do
      {_manifest, _client, %{quota_exhausted: true}} ->
        {:halt, result}

      {_manifest, _client, %{processed: processed}} when processed >= record_limit ->
        {:halt, result}

      _ ->
        {:cont, result}
    end
  end

  defp import_candidate(candidate, client, sources, run) do
    cond do
      not eligible_candidate?(candidate) ->
        {%{status: :skipped, reason: "invalid_or_unsupported_candidate"}, client}

      true ->
        existing_id = Registry.by_external_id("wikidata", candidate["qid"])

        {work_id, _wikidata_record} =
          ensure_wikidata_work!(candidate, sources["wikidata"], run.id)

        case Client.artwork(client, candidate["artsy_artwork_slug"]) do
          {:ok, body, client, request_meta} ->
            artwork = Client.normalize_artwork(body)

            import_hydrated(
              candidate,
              artwork,
              work_id,
              existing_id,
              client,
              sources,
              run,
              request_meta
            )

          {:error, %{code: "not_found"}, client} ->
            {%{status: :unavailable, object_id: work_id, reason: "artsy_artwork_not_found"},
             client}

          {:error, %{code: "request_limit"}, client} ->
            {%{status: :quota_exhausted, object_id: work_id, reason: "request_limit"}, client}

          {:error, %{code: "quota_exhausted"}, client} ->
            {%{status: :quota_exhausted, object_id: work_id, reason: "provider_quota"}, client}

          {:error, failure, client} ->
            {%{status: :skipped, object_id: work_id, reason: failure.code}, client}
        end
    end
  end

  defp import_hydrated(
         candidate,
         artwork,
         work_id,
         existing_id,
         client,
         sources,
         run,
         request_meta
       ) do
    cond do
      artwork["slug"] != candidate["artsy_artwork_slug"] ->
        {record, client} =
          store_artsy_record(candidate, artwork, [], [], client, sources["artsy"], run.id)

        {:ok, entry} =
          Entry.new(%{
            source_slug: "artsy",
            source_id: sources["artsy"].id,
            source_record_id: record.id,
            source_record_revision_id: record.current_revision.id,
            import_run_id: run.id,
            object_kind: :entity,
            entity_kind: :work,
            work_kind: "artwork",
            stable_identifier: %{namespace: "wikidata", external_id: candidate["qid"]},
            identifiers: [
              %{namespace: "wikidata", external_id: candidate["qid"]},
              %{namespace: "artsy_artwork_slug", external_id: candidate["artsy_artwork_slug"]},
              %{namespace: "artsy_artwork_slug", external_id: artwork["slug"]},
              %{namespace: "artsy_artwork_id", external_id: artwork["id"]}
            ],
            label: candidate["title"],
            eligibility: :eligible,
            retention: :durable
          })

        resolution = SourceIdentity.resolve(entry)

        {%{
           status: :conflict,
           object_id: work_id,
           conflict_id: resolution.conflict_id,
           reason: "provider_slug_differs_from_wikidata_p11005",
           requested_slug: candidate["artsy_artwork_slug"],
           returned_slug: artwork["slug"]
         }, client}

      artwork["category"] != "Painting" ->
        {record, client} =
          store_artsy_record(candidate, artwork, [], [], client, sources["artsy"], run.id)

        {%{
           status: :skipped,
           object_id: work_id,
           source_record_id: record.id,
           reason: "artsy_category_not_painting",
           category: artwork["category"],
           reproduction: true
         }, client}

      true ->
        {artists_body, client, artist_failure} = collection(client, :artists, artwork["id"])
        {genes_body, client, gene_failure} = collection(client, :genes, artwork["id"])

        artists = Enum.map(artists_body, &Client.normalize_artist/1)
        genes = Enum.map(genes_body, &Client.normalize_gene/1)

        {record, client} =
          store_artsy_record(candidate, artwork, artists, genes, client, sources["artsy"], run.id)

        {:ok, entry} = artsy_entry(candidate, artwork, record, sources["artsy"], run.id)
        resolution = SourceIdentity.resolve(entry)

        if resolution.state == :conflicting_identifiers do
          {%{
             status: :conflict,
             object_id: work_id,
             conflict_id: resolution.conflict_id,
             reason: resolution.reason
           }, client}
        else
          {creator_stats, client} =
            import_creators(
              candidate,
              artists,
              resolution.object_id,
              record,
              client,
              sources,
              run
            )

          status = if is_nil(existing_id), do: :created, else: :matched

          {%{
             status: status,
             object_id: resolution.object_id,
             source_record_id: record.id,
             artsy_artwork_id: artwork["id"],
             artsy_artwork_slug: artwork["slug"],
             creator_count: creator_stats.resolved,
             creator_links: creator_stats.links,
             missing_creators: creator_stats.missing,
             gene_count: length(genes),
             artist_failure: artist_failure,
             gene_failure: gene_failure,
             redirects: request_meta.redirects
           }, client}
        end
    end
  end

  defp collection(client, kind, artwork_id) do
    result =
      case kind do
        :artists -> Client.artwork_artists(client, artwork_id)
        :genes -> Client.artwork_genes(client, artwork_id)
      end

    key = if kind == :artists, do: "artists", else: "genes"

    case result do
      {:ok, body, client, _meta} -> {get_in(body, ["_embedded", key]) || [], client, nil}
      {:error, failure, client} -> {[], client, failure.code}
    end
  end

  defp store_artsy_record(candidate, artwork, artists, genes, client, source, run_id) do
    raw = %{
      "artwork" => artwork,
      "artists" => artists,
      "genes" => genes,
      "wikidata_qid" => candidate["qid"],
      "wikidata_p11005" => candidate["artsy_artwork_slug"],
      "selection_reason" => candidate["selection_reason"],
      "retention" => %{
        "mode" => "discovery_cache",
        "image" => "reference_only",
        "durable_source" => "wikidata",
        "remove_on_provider_termination" => true
      }
    }

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "artwork:#{artwork["id"]}",
        url: artwork["permalink"],
        raw: raw,
        import_run_id: run_id
      })

    {record, client}
  end

  defp artsy_entry(candidate, artwork, record, source, run_id) do
    Entry.new(%{
      source_slug: source.slug,
      source_id: source.id,
      source_record_id: record.id,
      source_record_revision_id: record.current_revision.id,
      import_run_id: run_id,
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "artwork",
      stable_identifier: %{namespace: "artsy_artwork_id", external_id: artwork["id"]},
      identifiers: [
        %{namespace: "wikidata", external_id: candidate["qid"]},
        %{namespace: "artsy_artwork_slug", external_id: artwork["slug"]},
        %{namespace: "artsy_artwork_id", external_id: artwork["id"]}
      ],
      label: candidate["title"],
      metadata: %{},
      eligibility: :eligible,
      retention: :durable
    })
  end

  defp import_creators(candidate, artists, work_id, artwork_record, client, sources, run) do
    by_slug = Map.new(candidate["creators"] || [], &{&1["artsy_artist_slug"], &1})

    Enum.reduce(artists, {%{resolved: 0, links: 0, missing: 0}, client}, fn artist,
                                                                            {stats, client} ->
      case by_slug[artist["slug"]] do
        %{"qid" => qid} = creator when is_binary(qid) ->
          {person_id, _record} = ensure_wikidata_creator!(creator, sources["wikidata"], run.id)

          {:ok, artist_record} =
            Sources.upsert_record(sources["artsy"], %{
              external_id: "artist:#{artist["id"]}",
              url: artist["permalink"],
              raw: %{
                "artist" => artist,
                "wikidata_qid" => qid,
                "wikidata_p2042" => creator["artsy_artist_slug"],
                "retention" => %{"remove_on_provider_termination" => true}
              },
              import_run_id: run.id
            })

          {:ok, entry} =
            Entry.new(%{
              source_slug: "artsy",
              source_id: sources["artsy"].id,
              source_record_id: artist_record.id,
              source_record_revision_id: artist_record.current_revision.id,
              import_run_id: run.id,
              object_kind: :entity,
              entity_kind: :person,
              stable_identifier: %{namespace: "artsy_artist_id", external_id: artist["id"]},
              identifiers: [
                %{namespace: "wikidata", external_id: qid},
                %{namespace: "artsy_artist_slug", external_id: artist["slug"]},
                %{namespace: "artsy_artist_id", external_id: artist["id"]}
              ],
              label: creator["name"] || artist["name"],
              metadata: %{},
              eligibility: :eligible,
              retention: :durable
            })

          resolution = SourceIdentity.resolve(entry)

          if resolution.object_id == person_id do
            linked? = ensure_creator_link(work_id, person_id, sources["artsy"].id, artwork_record)

            {%{
               stats
               | resolved: stats.resolved + 1,
                 links: stats.links + if(linked?, do: 1, else: 0)
             }, client}
          else
            {%{stats | missing: stats.missing + 1}, client}
          end

        _ ->
          {%{stats | missing: stats.missing + 1}, client}
      end
    end)
  end

  defp ensure_creator_link(work_id, person_id, source_id, artwork_record) do
    origin_key = "artsy:creator:#{work_id}:#{person_id}"

    case DevilsDictionary.Repo.get_by(Assertion, source_id: source_id, origin_key: origin_key) do
      nil ->
        claim =
          unwrap(
            Claims.assert(work_id, "authored_by", person_id, %{
              source_id: source_id,
              origin_key: origin_key,
              method: "source_relationship",
              metadata: %{"provider" => "artsy", "review" => "attributed_source_fact"}
            })
          )

        revision = Claims.current_revision(claim.id)

        unwrap(
          Claims.add_evidence(revision.id, %{
            source_record_revision_id: artwork_record.current_revision.id,
            evidence_role: :supports,
            attribution_text: "Artsy artwork creator link"
          })
        )

        true

      _existing ->
        false
    end
  end

  defp ensure_wikidata_work!(candidate, source, run_id) do
    raw = wikidata_snapshot(candidate, :artwork)

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: candidate["qid"],
        url: "https://www.wikidata.org/wiki/#{candidate["qid"]}",
        raw: raw,
        import_run_id: run_id
      })

    {:ok, _} = Materializer.run(record, Wikidata, run_id: run_id)
    {Registry.by_external_id("wikidata", candidate["qid"]), record}
  end

  defp ensure_wikidata_creator!(creator, source, run_id) do
    raw = wikidata_snapshot(creator, :person)

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: creator["qid"],
        url: "https://www.wikidata.org/wiki/#{creator["qid"]}",
        raw: raw,
        import_run_id: run_id
      })

    {:ok, _} = Materializer.run(record, Wikidata, run_id: run_id)
    {Registry.by_external_id("wikidata", creator["qid"]), record}
  end

  defp wikidata_snapshot(value, kind) do
    claims =
      case kind do
        :artwork ->
          %{
            "P31" => [entity_statement("Q3305213")],
            "P11005" => [string_statement(value["artsy_artwork_slug"])],
            "P170" => Enum.map(value["creators"] || [], &entity_statement(&1["qid"]))
          }

        :person ->
          %{
            "P31" => [entity_statement("Q5")],
            "P2042" => [string_statement(value["artsy_artist_slug"])]
          }
      end

    %{
      "_artwork_seed_version" => 1,
      "id" => value["qid"],
      "labels" => %{"en" => %{"language" => "en", "value" => value["title"] || value["name"]}},
      "descriptions" => description(value["description"]),
      "aliases" => %{},
      "sitelinks" => sitelink(value["wikipedia_title"]),
      "claims" => claims
    }
  end

  defp entity_statement(nil), do: %{}

  defp entity_statement(qid) do
    %{
      "type" => "statement",
      "rank" => "normal",
      "mainsnak" => %{"datavalue" => %{"value" => %{"id" => qid}, "type" => "wikibase-entityid"}}
    }
  end

  defp string_statement(value) do
    %{
      "type" => "statement",
      "rank" => "normal",
      "mainsnak" => %{"datavalue" => %{"value" => value, "type" => "string"}}
    }
  end

  defp description(nil), do: %{}
  defp description(value), do: %{"en" => %{"language" => "en", "value" => value}}
  defp sitelink(nil), do: %{}
  defp sitelink(title), do: %{"enwiki" => %{"site" => "enwiki", "title" => title}}

  defp eligible_candidate?(candidate) do
    candidate["kind"] == "painting" and Regex.match?(~r/\AQ[1-9]\d*\z/, candidate["qid"] || "") and
      Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,254}\z/, candidate["artsy_artwork_slug"] || "") and
      is_binary(candidate["title"]) and String.trim(candidate["title"]) != ""
  end

  defp accumulate(summary, outcome, index) do
    summary = %{summary | processed: summary.processed + 1, next_index: index + 1}

    summary =
      case outcome.status do
        :created -> %{summary | created: summary.created + 1}
        :matched -> %{summary | matched: summary.matched + 1}
        :conflict -> %{summary | conflicts: summary.conflicts + 1}
        :unavailable -> %{summary | unavailable: summary.unavailable + 1}
        :quota_exhausted -> summary
        :skipped -> %{summary | skipped: summary.skipped + 1}
      end

    summary
    |> Map.update!(:reproductions, &(&1 + if(outcome[:reproduction], do: 1, else: 0)))
    |> Map.update!(:creators_resolved, &(&1 + (outcome[:creator_count] || 0)))
    |> Map.update!(:creator_links, &(&1 + (outcome[:creator_links] || 0)))
    |> Map.update!(:missing_links, &(&1 + (outcome[:missing_creators] || 0)))
    |> Map.update!(:genes, &(&1 + (outcome[:gene_count] || 0)))
  end

  defp maybe_save(manifest, nil), do: manifest
  defp maybe_save(manifest, path), do: Manifest.save!(manifest, path)
  defp bounded(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: DevilsDictionary.Repo.rollback(reason)
end
