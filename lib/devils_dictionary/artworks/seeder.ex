defmodule DevilsDictionary.Artworks.Seeder do
  @moduledoc """
  Idempotent, stage-resumable Wikidata-to-Artsy selected artwork importer.

  Wikidata records are immutable observations owned by the shared absorber. This
  importer materializes an existing full record when one is available, but it
  never replaces that record with a manifest-shaped summary. Artsy payloads are
  explicitly disposable caches and every provider-data write is guarded by the
  same row lock used by provider withdrawal.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Artsy.{Availability, Client}
  alias DevilsDictionary.Artworks.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @default_record_limit 500
  @max_record_limit 5_000
  @default_batch_size 25
  @max_collection_pages 20
  @freshness_seconds 86_400

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
      client = opts[:artsy_client] || Client.new(request_limit: opts[:request_limit] || 500)

      # The importer owns an entry-point gate as well as the client's per-attempt
      # gate. An injected/test client must not be able to bypass a withdrawn source,
      # and this check happens before Catalog.seed!/0 can touch source lifecycle.
      if provider_accessible?(client) and Client.available?(client) do
        do_run(manifest, client, resume?, record_limit, batch_size, manifest_path)
      else
        {manifest, disabled_summary(manifest)}
      end
    end
  end

  defp provider_accessible?(%Client{} = client) do
    Availability.status_with_credentials(
      client.client_id,
      client.client_secret,
      client.coordinator
    ) == :ok
  end

  defp do_run(manifest, client, resume?, record_limit, batch_size, manifest_path) do
    %{sources: sources} = Sources.Catalog.seed!()
    artsy_source = Map.fetch!(sources, "artsy")
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
      partial: 0,
      reproductions: 0,
      creators_resolved: 0,
      creator_links: 0,
      genes: 0,
      request_exhausted: false,
      provider_quota_exhausted: false,
      quota_exhausted: false,
      provider_disabled: false,
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

      summary = %{summary | requests: client.request_count, retries: client.retry_count}
      Sources.finish_run(run, stringify(summary))
      {maybe_save(manifest, manifest_path), summary}
    rescue
      exception ->
        Sources.fail_run(run, Exception.message(exception))
        reraise exception, __STACKTRACE__
    end
  end

  defp process_batch(batch, {manifest, client, summary}, sources, run, resume?, limit, path) do
    result =
      Enum.reduce_while(batch, {manifest, client, summary}, fn {candidate, index}, acc ->
        {manifest, client, summary} = acc

        cond do
          summary.processed >= limit ->
            {:halt, {manifest, client, %{summary | next_index: index}}}

          resume? and Manifest.completed?(candidate) ->
            {:cont, acc}

          true ->
            {outcome, client} = import_candidate(candidate, client, sources, run)

            manifest =
              manifest
              |> Manifest.update_candidate(index, Map.put(outcome, :updated_at, timestamp()))
              |> maybe_save(path)

            summary = accumulate(summary, outcome, index)

            if outcome[:stop] do
              {:halt, {manifest, client, summary}}
            else
              {:cont, {manifest, client, summary}}
            end
        end
      end)

    case result do
      {_manifest, _client, %{request_exhausted: true}} -> {:halt, result}
      {_manifest, _client, %{provider_quota_exhausted: true}} -> {:halt, result}
      {_manifest, _client, %{provider_disabled: true}} -> {:halt, result}
      {_manifest, _client, %{processed: processed}} when processed >= limit -> {:halt, result}
      _ -> {:cont, result}
    end
  end

  defp import_candidate(candidate, client, sources, run) do
    if eligible_candidate?(candidate) do
      existing_id = Registry.by_external_id("wikidata", candidate["qid"])
      {work_id, wikidata_stage} = ensure_wikidata_work!(candidate, sources["wikidata"], run.id)
      ensure_wikidata_creator_links(candidate, work_id, sources["wikidata"].id)

      stages = stage_map(candidate) |> Map.put("wikidata", wikidata_stage)

      case cached_artsy_record(candidate, sources["artsy"]) do
        %{fresh?: true} = cached ->
          continue_hydrated(
            candidate,
            work_id,
            existing_id,
            cached,
            client,
            sources,
            run,
            Map.put(stages, "artwork", %{"status" => "complete"})
          )

        %{payload: payload} = cached when is_map(payload) ->
          if partial_payload?(payload) do
            continue_hydrated(
              candidate,
              work_id,
              existing_id,
              cached,
              client,
              sources,
              run,
              Map.put(stages, "artwork", %{"status" => "complete"})
            )
          else
            fetch_artwork(candidate, work_id, existing_id, client, sources, run, stages)
          end

        nil ->
          fetch_artwork(candidate, work_id, existing_id, client, sources, run, stages)
      end
    else
      {%{status: :skipped, reason: "invalid_or_unsupported_candidate"}, client}
    end
  end

  defp fetch_artwork(candidate, work_id, existing_id, client, sources, run, stages) do
    case Client.artwork(client, candidate["artsy_artwork_slug"]) do
      {:ok, body, client, request_meta} ->
        artwork = Client.normalize_artwork(body)

        payload =
          artsy_payload(candidate, artwork)
          |> put_in(["request_meta"], stringify(request_meta))

        case guarded_store(payload, sources["artsy"], run.id) do
          {:ok, record} ->
            cached = %{record: record, payload: payload, fresh?: true}

            continue_hydrated(
              candidate,
              work_id,
              existing_id,
              cached,
              client,
              sources,
              run,
              Map.put(stages, "artwork", %{"status" => "complete"})
            )

          {:error, :provider_disabled} ->
            {partial(work_id, stages, "provider_disabled", :provider_disabled), client}
        end

      {:error, %{code: "not_found"}, client} ->
        {%{
           status: :unavailable,
           object_id: work_id,
           reason: "artsy_artwork_not_found",
           stages: Map.put(stages, "artwork", %{"status" => "unavailable"})
         }, client}

      {:error, failure, client} ->
        {failure_outcome(work_id, stages, "artwork", failure), client}
    end
  end

  defp continue_hydrated(
         candidate,
         work_id,
         existing_id,
         cached,
         client,
         sources,
         run,
         stages
       ) do
    artwork = cached.payload["artwork"] || %{}

    cond do
      artwork["slug"] != candidate["artsy_artwork_slug"] ->
        entry = artsy_entry(candidate, artwork, cached.record, sources["artsy"], run.id, true)
        resolution = guarded_resolve(entry)

        {%{
           status: :conflict,
           object_id: work_id,
           conflict_id: resolution && resolution.conflict_id,
           reason: "provider_slug_differs_from_wikidata_p11005",
           requested_slug: candidate["artsy_artwork_slug"],
           returned_slug: artwork["slug"],
           stages: Map.put(stages, "identity", %{"status" => "conflict"})
         }, client}

      artwork["category"] != "Painting" ->
        {%{
           status: :skipped,
           object_id: work_id,
           source_record_id: cached.record.id,
           reason: "artsy_category_not_painting",
           category: artwork["category"],
           reproduction: true,
           stages: Map.put(stages, "artwork", %{"status" => "ineligible"})
         }, client}

      true ->
        hydrate_collections(
          candidate,
          work_id,
          existing_id,
          cached,
          client,
          sources,
          run,
          stages
        )
    end
  end

  defp hydrate_collections(candidate, work_id, existing_id, cached, client, sources, run, stages) do
    with {:ok, cached, client, stages} <-
           ensure_collection(:artists, cached, client, sources["artsy"], run.id, stages),
         {:ok, cached, client, stages} <-
           ensure_collection(:genes, cached, client, sources["artsy"], run.id, stages) do
      artists = Enum.map(cached.payload["artists"] || [], &Client.normalize_artist/1)
      genes = Enum.map(cached.payload["genes"] || [], &Client.normalize_gene/1)
      record = cached.record

      {:ok, entry} =
        artsy_entry(candidate, cached.payload["artwork"], record, sources["artsy"], run.id)

      case guarded_resolve(entry) do
        nil ->
          {partial(work_id, stages, "provider_disabled", :provider_disabled), client}

        %{state: :conflicting_identifiers} = resolution ->
          {%{
             status: :conflict,
             object_id: work_id,
             conflict_id: resolution.conflict_id,
             reason: resolution.reason,
             stages: Map.put(stages, "identity", %{"status" => "conflict"})
           }, client}

        resolution ->
          {creator_stats, creator_stage} =
            import_creators(candidate, artists, resolution.object_id, record, sources, run)

          status = if is_nil(existing_id), do: :created, else: :matched

          {%{
             status: status,
             object_id: resolution.object_id,
             source_record_id: record.id,
             artsy_artwork_id: cached.payload["artwork"]["id"],
             artsy_artwork_slug: cached.payload["artwork"]["slug"],
             creator_count: creator_stats.resolved,
             creator_links: creator_stats.links,
             missing_creators: creator_stats.missing,
             gene_count: length(genes),
             cache_fresh: cached.fresh?,
             stages:
               stages
               |> Map.put("identity", %{"status" => "complete"})
               |> Map.put("creators", creator_stage)
           }, client}
      end
    else
      {:partial, stage, failure, cached, client, stages} ->
        outcome = failure_outcome(work_id, stages, to_string(stage), failure)

        outcome =
          Map.merge(outcome, %{
            source_record_id: cached.record.id,
            retained_artwork: true,
            retained_artist_count: length(cached.payload["artists"] || []),
            retained_gene_count: length(cached.payload["genes"] || [])
          })

        {outcome, client}
    end
  end

  defp ensure_collection(kind, cached, client, source, run_id, stages) do
    key = if kind == :artists, do: "artists", else: "genes"
    state = get_in(cached.payload, ["collection_state", key]) || %{}

    if state["status"] == "complete" do
      {:ok, cached, client, Map.put(stages, key, state)}
    else
      cursor = state["next_cursor"]
      fetch_collection(kind, cached, client, source, run_id, stages, cursor, 0)
    end
  end

  defp fetch_collection(kind, cached, client, source, run_id, stages, cursor, page_count)
       when page_count < @max_collection_pages do
    artwork_id = cached.payload["artwork"]["id"]
    key = if kind == :artists, do: "artists", else: "genes"

    result =
      case kind do
        :artists -> Client.artwork_artists(client, artwork_id, cursor: cursor)
        :genes -> Client.artwork_genes(client, artwork_id, cursor: cursor)
      end

    case result do
      {:ok, body, client, meta} ->
        rows = get_in(body, ["_embedded", key]) || []
        accumulated = dedupe_source_rows((cached.payload[key] || []) ++ rows)
        next_cursor = meta.next_cursor
        status = if next_cursor, do: "partial", else: "complete"

        collection_state = %{
          "status" => status,
          "next_cursor" => next_cursor,
          "pages" => page_count + 1,
          "returned_next_preserved_filter" => meta.returned_next_preserved_filter
        }

        payload =
          cached.payload
          |> Map.put(key, accumulated)
          |> put_collection_state(key, collection_state)

        case guarded_store(payload, source, run_id) do
          {:ok, record} ->
            cached = %{cached | payload: payload, record: record}
            stages = Map.put(stages, key, collection_state)

            if next_cursor do
              fetch_collection(
                kind,
                cached,
                client,
                source,
                run_id,
                stages,
                next_cursor,
                page_count + 1
              )
            else
              {:ok, cached, client, stages}
            end

          {:error, :provider_disabled} ->
            failure = %{code: "provider_disabled"}
            {:partial, kind, failure, cached, client, stages}
        end

      {:error, failure, client} ->
        state = %{"status" => "partial", "next_cursor" => cursor, "error" => failure.code}
        payload = put_collection_state(cached.payload, key, state)

        cached =
          case guarded_store(payload, source, run_id) do
            {:ok, record} -> %{cached | payload: payload, record: record}
            _ -> cached
          end

        {:partial, kind, failure, cached, client, Map.put(stages, key, state)}
    end
  end

  defp fetch_collection(kind, cached, client, _source, _run_id, stages, cursor, _page_count) do
    failure = %{code: "collection_page_limit"}
    state = %{"status" => "partial", "next_cursor" => cursor, "error" => failure.code}
    {:partial, kind, failure, cached, client, Map.put(stages, to_string(kind), state)}
  end

  defp cached_artsy_record(candidate, source) do
    record =
      Repo.one(
        from record in SourceRecord,
          join: revision in SourceRecordRevision,
          on:
            revision.source_record_id == record.id and
              revision.revision_key == record.content_hash,
          where:
            record.source_id == ^source.id and record.display_allowed and
              fragment("?->>'wikidata_qid'", revision.payload) == ^candidate["qid"] and
              fragment("?->>'wikidata_p11005'", revision.payload) ==
                ^candidate["artsy_artwork_slug"],
          order_by: [desc: revision.observed_at, desc: revision.id],
          limit: 1,
          select:
            {record,
             map(revision, [
               :id,
               :source_record_id,
               :revision_key,
               :payload,
               :checksum,
               :observed_at,
               :import_run_id,
               :inserted_at,
               :updated_at
             ])}
      )

    case record do
      {record, revision} ->
        age = DateTime.diff(DateTime.utc_now(), revision.observed_at, :second)

        %{
          record: Map.put(record, :current_revision, revision),
          payload: revision.payload,
          fresh?: age <= freshness_seconds()
        }

      nil ->
        nil
    end
  end

  defp guarded_store(payload, source, run_id) do
    case Availability.with_active_source(fn _locked_source ->
           artwork = payload["artwork"]

           Sources.upsert_record(source, %{
             external_id: "artwork:#{artwork["id"]}",
             url: artwork["permalink"],
             raw: payload,
             import_run_id: run_id
           })
         end) do
      {:ok, {:ok, record}} -> {:ok, record}
      {:error, :provider_disabled} -> {:error, :provider_disabled}
      {:error, reason} -> raise "Artsy record write failed: #{inspect(reason)}"
    end
  end

  defp guarded_resolve({:ok, entry}), do: guarded_resolve(entry)

  defp guarded_resolve(%Entry{} = entry) do
    case Availability.with_active_source(fn _ -> SourceIdentity.resolve(entry) end) do
      {:ok, resolution} -> resolution
      {:error, :provider_disabled} -> nil
    end
  end

  defp artsy_payload(candidate, artwork) do
    %{
      "artwork" => artwork,
      "artists" => [],
      "genes" => [],
      "collection_state" => %{
        "artists" => %{"status" => "pending", "next_cursor" => nil},
        "genes" => %{"status" => "pending", "next_cursor" => nil}
      },
      "wikidata_qid" => candidate["qid"],
      "wikidata_p11005" => candidate["artsy_artwork_slug"],
      "selection_reason" => candidate["selection_reason"],
      "freshness" => %{
        "observed_at" => timestamp(),
        "fresh_for_seconds" => freshness_seconds(),
        "retained_content_may_be_stale" => true
      },
      "retention" => %{
        "mode" => "disposable_discovery_cache",
        "image" => "remote_reference_only",
        "durable_source" => "wikidata",
        "remove_on_provider_termination" => true,
        "api_access_does_not_grant_permanent_retention" => true
      }
    }
  end

  defp artsy_entry(candidate, artwork, record, source, run_id, conflict? \\ false) do
    identifiers = [
      %{namespace: "wikidata", external_id: candidate["qid"]},
      %{namespace: "artsy_artwork_slug", external_id: artwork["slug"]},
      %{namespace: "artsy_artwork_id", external_id: artwork["id"]}
    ]

    identifiers =
      if conflict?,
        do: [
          %{namespace: "artsy_artwork_slug", external_id: candidate["artsy_artwork_slug"]}
          | identifiers
        ],
        else: identifiers

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
      identifiers: identifiers,
      label: candidate["title"] || artwork["title"],
      metadata: %{"provider" => "artsy", "retention" => "disposable_cache"},
      eligibility: :eligible,
      retention: :durable
    })
  end

  defp ensure_wikidata_work!(candidate, source, run_id) do
    case current_source_record(source.id, candidate["qid"]) do
      nil ->
        {:ok, entry} = wikidata_work_entry(candidate, source)
        resolution = SourceIdentity.resolve(entry)
        {resolution.object_id, %{"status" => "exact_manifest_link", "source_record_id" => nil}}

      {record, revision} ->
        record = record |> Map.put(:raw, revision.payload) |> Map.put(:current_revision, revision)
        {:ok, _} = Materializer.run(record, Wikidata, run_id: run_id)

        work_id =
          Registry.by_external_id("wikidata", candidate["qid"]) ||
            resolve_wikidata_work(candidate, source, record, revision, run_id)

        {work_id,
         %{
           "status" => "materialized_full_record",
           "source_record_id" => record.id,
           "source_record_revision_id" => revision.id,
           "preserved" => true
         }}
    end
  end

  defp wikidata_work_entry(candidate, source) do
    Entry.new(%{
      source_slug: source.slug,
      source_id: source.id,
      object_kind: :entity,
      entity_kind: :work,
      work_kind: "artwork",
      stable_identifier: %{namespace: "wikidata", external_id: candidate["qid"]},
      identifiers: [
        %{namespace: "wikidata", external_id: candidate["qid"]},
        %{namespace: "artsy_artwork_slug", external_id: candidate["artsy_artwork_slug"]}
      ],
      label: candidate["title"],
      description: nil,
      metadata: %{
        "identity_evidence" => "wikidata_exact_qid_p11005_manifest",
        "not_a_wikidata_record" => true
      },
      eligibility: :eligible,
      retention: :durable
    })
  end

  defp resolve_wikidata_work(candidate, source, record, revision, run_id) do
    {:ok, entry} = wikidata_work_entry(candidate, source)

    entry = %{
      entry
      | source_record_id: record.id,
        source_record_revision_id: revision.id,
        import_run_id: run_id
    }

    SourceIdentity.resolve(entry).object_id
  end

  defp ensure_wikidata_creator_links(candidate, work_id, source_id) do
    Enum.each(candidate["creators"] || [], fn creator ->
      if valid_qid?(creator["qid"]) do
        person_id = ensure_wikidata_creator!(creator, source_id)

        if is_integer(work_id) and is_integer(person_id) do
          ensure_creator_link(work_id, person_id, source_id, nil, "wikidata_manifest")
        end
      end
    end)
  end

  defp ensure_wikidata_creator!(creator, source_id) do
    identifiers =
      [%{namespace: "wikidata", external_id: creator["qid"]}] ++
        if(valid_slug?(creator["artsy_artist_slug"]),
          do: [%{namespace: "artsy_artist_slug", external_id: creator["artsy_artist_slug"]}],
          else: []
        )

    {:ok, entry} =
      Entry.new(%{
        source_slug: "wikidata",
        source_id: source_id,
        object_kind: :entity,
        entity_kind: :person,
        stable_identifier: %{namespace: "wikidata", external_id: creator["qid"]},
        identifiers: identifiers,
        label: creator["name"] || creator["qid"],
        metadata: %{
          "identity_evidence" => "wikidata_exact_p170_manifest",
          "not_a_wikidata_record" => true
        },
        eligibility: :eligible,
        retention: :durable
      })

    SourceIdentity.resolve(entry).object_id
  end

  defp import_creators(candidate, artists, work_id, artwork_record, sources, run) do
    creator_by_slug =
      (candidate["creators"] || [])
      |> Enum.filter(&valid_slug?(&1["artsy_artist_slug"]))
      |> Map.new(&{&1["artsy_artist_slug"], &1})

    stats =
      Enum.reduce(artists, %{resolved: 0, links: 0, missing: 0}, fn artist, stats ->
        case creator_by_slug[artist["slug"]] do
          %{"qid" => qid} = creator when is_binary(qid) ->
            person_id = Registry.by_external_id("wikidata", qid)

            if person_id do
              case guarded_store_artist(artist, creator, sources["artsy"], run.id) do
                {:ok, artist_record} ->
                  {:ok, entry} =
                    artsy_artist_entry(artist, creator, artist_record, sources["artsy"], run.id)

                  resolution = guarded_resolve(entry)

                  if resolution && resolution.object_id == person_id do
                    linked? =
                      ensure_creator_link(
                        work_id,
                        person_id,
                        sources["artsy"].id,
                        artwork_record,
                        "artsy"
                      )

                    %{
                      stats
                      | resolved: stats.resolved + 1,
                        links: stats.links + if(linked?, do: 1, else: 0)
                    }
                  else
                    %{stats | missing: stats.missing + 1}
                  end

                {:error, :provider_disabled} ->
                  %{stats | missing: stats.missing + 1}
              end
            else
              %{stats | missing: stats.missing + 1}
            end

          _ ->
            %{stats | missing: stats.missing + 1}
        end
      end)

    {stats, %{"status" => "complete", "resolved" => stats.resolved, "missing" => stats.missing}}
  end

  defp guarded_store_artist(artist, creator, source, run_id) do
    payload = %{
      "artist" => artist,
      "wikidata_qid" => creator["qid"],
      "wikidata_p2042" => creator["artsy_artist_slug"],
      "retention" => %{"remove_on_provider_termination" => true}
    }

    case Availability.with_active_source(fn _ ->
           Sources.upsert_record(source, %{
             external_id: "artist:#{artist["id"]}",
             url: artist["permalink"],
             raw: payload,
             import_run_id: run_id
           })
         end) do
      {:ok, {:ok, record}} -> {:ok, record}
      {:error, :provider_disabled} -> {:error, :provider_disabled}
    end
  end

  defp artsy_artist_entry(artist, creator, record, source, run_id) do
    Entry.new(%{
      source_slug: source.slug,
      source_id: source.id,
      source_record_id: record.id,
      source_record_revision_id: record.current_revision.id,
      import_run_id: run_id,
      object_kind: :entity,
      entity_kind: :person,
      stable_identifier: %{namespace: "artsy_artist_id", external_id: artist["id"]},
      identifiers: [
        %{namespace: "wikidata", external_id: creator["qid"]},
        %{namespace: "artsy_artist_slug", external_id: artist["slug"]},
        %{namespace: "artsy_artist_id", external_id: artist["id"]}
      ],
      label: creator["name"] || artist["name"],
      metadata: %{"provider" => "artsy", "retention" => "disposable_cache"},
      eligibility: :eligible,
      retention: :durable
    })
  end

  defp ensure_creator_link(work_id, person_id, source_id, artwork_record, provider) do
    origin_key = "#{provider}:creator:#{work_id}:#{person_id}"

    case Repo.get_by(Assertion, source_id: source_id, origin_key: origin_key) do
      nil ->
        case Claims.assert(work_id, "authored_by", person_id, %{
               source_id: source_id,
               origin_key: origin_key,
               method: "source_relationship",
               metadata: %{
                 "provider" => provider,
                 "review" => "attributed_source_fact",
                 "identity_independent_of_artwork_provider" => provider == "wikidata_manifest"
               }
             }) do
          {:ok, claim} ->
            if artwork_record do
              revision = Claims.current_revision(claim.id)

              {:ok, _evidence} =
                Claims.add_evidence(revision.id, %{
                  source_record_revision_id: artwork_record.current_revision.id,
                  evidence_role: :supports,
                  attribution_text: "Artsy artwork creator link"
                })
            end

            true

          {:error, _reason} ->
            false
        end

      _existing ->
        false
    end
  end

  defp current_source_record(source_id, external_id) do
    Repo.one(
      from record in SourceRecord,
        join: revision in SourceRecordRevision,
        on:
          revision.source_record_id == record.id and revision.revision_key == record.content_hash,
        where: record.source_id == ^source_id and record.external_id == ^external_id,
        select:
          {record,
           map(revision, [
             :id,
             :source_record_id,
             :revision_key,
             :payload,
             :checksum,
             :observed_at,
             :import_run_id,
             :inserted_at,
             :updated_at
           ])}
    )
  end

  defp stage_map(candidate) do
    get_in(candidate, ["import", "stages"]) ||
      %{
        "wikidata" => %{"status" => "pending"},
        "artwork" => %{"status" => "pending"},
        "artists" => %{"status" => "pending", "next_cursor" => nil},
        "genes" => %{"status" => "pending", "next_cursor" => nil},
        "identity" => %{"status" => "pending"},
        "creators" => %{"status" => "pending"}
      }
  end

  defp failure_outcome(work_id, stages, stage, failure) do
    status =
      if failure.code in [
           "request_limit",
           "quota_exhausted",
           "provider_disabled",
           "collection_page_limit"
         ], do: :partial, else: :partial

    partial(
      work_id,
      Map.put(stages, stage, %{"status" => "partial", "error" => failure.code}),
      failure.code,
      failure_kind(failure.code)
    )
    |> Map.put(:status, status)
  end

  defp partial(work_id, stages, reason, kind) do
    %{
      status: :partial,
      object_id: work_id,
      reason: reason,
      failure_kind: kind,
      stages: stages,
      stop: kind in [:request_exhausted, :provider_quota, :provider_disabled]
    }
  end

  defp failure_kind("request_limit"), do: :request_exhausted
  defp failure_kind("quota_exhausted"), do: :provider_quota
  defp failure_kind("provider_disabled"), do: :provider_disabled
  defp failure_kind(_), do: :transient

  defp eligible_candidate?(candidate) do
    candidate["kind"] == "painting" and valid_qid?(candidate["qid"]) and
      valid_slug?(candidate["artsy_artwork_slug"]) and is_binary(candidate["title"]) and
      String.trim(candidate["title"]) != ""
  end

  defp valid_qid?(value), do: is_binary(value) and Regex.match?(~r/\AQ[1-9]\d*\z/, value)

  defp valid_slug?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,254}\z/, value)

  defp dedupe_source_rows(rows) do
    Enum.uniq_by(rows, fn row -> row["id"] || row["slug"] || :erlang.phash2(row) end)
  end

  defp partial_payload?(payload) do
    Enum.any?(~w(artists genes), fn key ->
      get_in(payload, ["collection_state", key, "status"]) != "complete"
    end)
  end

  defp put_collection_state(payload, key, state) do
    Map.update(payload, "collection_state", %{key => state}, fn collection_state ->
      Map.put(collection_state || %{}, key, state)
    end)
  end

  defp freshness_seconds do
    Application.get_env(:devils_dictionary, :artsy, [])[:freshness_seconds] || @freshness_seconds
  end

  defp accumulate(summary, outcome, index) do
    summary = %{summary | processed: summary.processed + 1, next_index: index + 1}

    summary =
      case outcome.status do
        :created -> %{summary | created: summary.created + 1}
        :matched -> %{summary | matched: summary.matched + 1}
        :conflict -> %{summary | conflicts: summary.conflicts + 1}
        :unavailable -> %{summary | unavailable: summary.unavailable + 1}
        :partial -> %{summary | partial: summary.partial + 1}
        :skipped -> %{summary | skipped: summary.skipped + 1}
      end

    summary
    |> Map.put(:request_exhausted, outcome[:failure_kind] == :request_exhausted)
    |> Map.put(:provider_quota_exhausted, outcome[:failure_kind] == :provider_quota)
    |> Map.put(:quota_exhausted, outcome[:failure_kind] in [:request_exhausted, :provider_quota])
    |> Map.put(:provider_disabled, outcome[:failure_kind] == :provider_disabled)
    |> Map.update!(:reproductions, &(&1 + if(outcome[:reproduction], do: 1, else: 0)))
    |> Map.update!(:creators_resolved, &(&1 + (outcome[:creator_count] || 0)))
    |> Map.update!(:creator_links, &(&1 + (outcome[:creator_links] || 0)))
    |> Map.update!(:missing_links, &(&1 + (outcome[:missing_creators] || 0)))
    |> Map.update!(:genes, &(&1 + (outcome[:gene_count] || 0)))
  end

  defp disabled_summary(manifest) do
    %{
      candidates: length(manifest["candidates"]),
      processed: 0,
      matched: 0,
      created: 0,
      conflicts: 0,
      unavailable: 0,
      missing_links: 0,
      skipped: 0,
      partial: 0,
      reproductions: 0,
      creators_resolved: 0,
      creator_links: 0,
      genes: 0,
      request_exhausted: false,
      provider_quota_exhausted: false,
      quota_exhausted: false,
      provider_disabled: true,
      requests: 0,
      retries: 0,
      next_index: 0
    }
  end

  defp maybe_save(manifest, nil), do: manifest
  defp maybe_save(manifest, path), do: Manifest.save!(manifest, path)
  defp bounded(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
