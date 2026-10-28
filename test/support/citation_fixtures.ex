defmodule DevilsDictionary.CitationFixtures do
  @moduledoc "Exact local observations; no provider or model request."
  alias DevilsDictionary.{Repo, Sources}
  alias DevilsDictionary.Sources.Source
  alias DevilsDictionary.Discovery.{Mapping, Run, Result, Policy}
  alias DevilsDictionary.Curation.{Digest, Shelf}

  def observation!(world, slug \\ "guardian", opts \\ []) do
    source = Repo.get_by!(Source, slug: slug)
    actor = DevilsDictionary.CurationFixtures.actor!(world.reviewer)
    token = System.unique_integer([:positive])
    provider = Enum.find(DevilsDictionary.Discovery.Providers.all(), &(&1.slug() == slug))

    mapping =
      %Mapping{}
      |> Mapping.create_changeset(%{
        mapping_key: "citation-fixture-#{token}",
        version: 1,
        target_object_id: world.love.object_id,
        source_id: source.id,
        operation: "search",
        parameters: %{},
        configured_by_actor_id: actor.id,
        enabled: true
      })
      |> Repo.insert!()

    now = DateTime.utc_now()
    observed = DateTime.add(now, -Keyword.get(opts, :age, 0))
    policy = Policy.for!(slug)
    seconds = Keyword.get(opts, :seconds, policy.retention_seconds)
    expiry = DateTime.add(observed, seconds)
    legacy = Keyword.get(opts, :legacy, false)

    run =
      %Run{}
      |> Run.create_changeset(%{
        mapping_id: mapping.id,
        adapter_version: provider.adapter_version(),
        request_parameters: %{},
        request_key: "citation-fixture-#{token}",
        position_key: "root",
        page_context: Ecto.UUID.generate(),
        page: 0,
        status: :pending
      })
      |> Repo.insert!()

    run =
      run
      |> Run.lifecycle_changeset(%{
        status: :succeeded,
        started_at: observed,
        completed_at: observed,
        refresh_after: DateTime.add(observed, 60),
        expires_at: expiry,
        completion_reason: :results,
        result_count: 1,
        retention_seconds: if(legacy, do: nil, else: seconds),
        retention_policy_sha256: if(legacy, do: nil, else: Shelf.policy_hash(policy))
      })
      |> Repo.update!()

    external_id = Keyword.get(opts, :external_id, "article-#{token}")
    namespace = Keyword.get(opts, :namespace, "guardian_article")

    metadata =
      Keyword.get(opts, :metadata, %{
        "title" => "A distinctive headline with five particular unusual words",
        "source_url" => "https://example.test/#{external_id}",
        "published_at" => DateTime.to_iso8601(DateTime.truncate(observed, :second))
      })

    matches = %{
      "kind" => "attestation",
      "matches" => [%{"text" => "A distinctive discovery snippet for this fixture."}]
    }

    raw = %{
      "external_namespace" => namespace,
      "external_id" => external_id,
      "identifiers" => [],
      "preview_metadata" => metadata,
      "match_details" => matches
    }

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: namespace <> ":" <> external_id,
        url: metadata["source_url"],
        raw: raw
      })

    revision = record.current_revision

    if not legacy do
      Repo.query!(
        "UPDATE source_record_revisions SET discovery_retain_until=$2,discovery_last_observed_at=$3,discovery_retention_policy_sha256=$4 WHERE id=$1",
        [revision.id, expiry, observed, run.retention_policy_sha256]
      )
    end

    result =
      %Result{}
      |> Result.changeset(%{
        run_id: run.id,
        external_namespace: namespace,
        external_id: external_id,
        object_id: Keyword.get(opts, :object_id),
        source_record_id: record.id,
        source_record_revision_id: if(legacy, do: nil, else: revision.id),
        position: 0,
        match_details: matches,
        preview_metadata: metadata,
        display_allowed: true,
        resolution_state: :insufficient_evidence
      })
      |> Repo.insert!()

    spec = %{
      result: result.id,
      run: run.id,
      revision: revision.id,
      checksum: revision.checksum,
      expires_at: DateTime.to_iso8601(expiry),
      shelf_kind: Shelf.kind(slug)
    }

    %{
      source: source,
      run: run,
      mapping: mapping,
      result: result,
      record: record,
      revision: revision,
      spec: spec,
      raw: raw,
      actor: actor,
      digest: Digest.sha256(namespace <> ":" <> external_id)
    }
  end
end
