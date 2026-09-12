defmodule DevilsDictionary.SourceIdentity.Backfill do
  @moduledoc """
  Bounded, resumable reconciliation for durable CineGraph film identities.

  Old discovery rows are rebuilt from their retained preview and source record.
  The same `SourceIdentity` resolver used during live ingestion does the work,
  so a rerun is idempotent and conflicts enter the normal reconciliation queue.
  This backfill never calls a remote API and never deletes or merges objects.
  """

  import Ecto.Query

  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Discovery.Result
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Resolution
  alias DevilsDictionary.Sources

  @default_limit 100
  @max_limit 1_000

  @doc "Reconciles one deterministic batch and returns per-state counts plus a checkpoint."
  def run(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> bounded_limit!()
    after_id = Keyword.get(opts, :after_id)

    results =
      Result
      |> join(:inner, [result], run in assoc(result, :run))
      |> join(:inner, [_result, run], mapping in assoc(run, :mapping))
      |> join(:inner, [_result, _run, mapping], source in assoc(mapping, :source))
      |> where([_result, _run, _mapping, source], source.slug == "cinegraph")
      |> after_result(after_id)
      |> order_by([result], asc: result.id)
      |> limit(^limit)
      |> preload([_result, run, mapping, _source], run: {run, mapping: {mapping, :source}})
      |> preload(:source_record)
      |> Repo.all()

    summary =
      Enum.reduce(results, empty_summary(), fn result, summary ->
        resolution = reconcile_result(result)

        summary
        |> Map.update!(:scanned, &(&1 + 1))
        |> Map.update!(resolution.state, &(&1 + 1))
      end)

    Map.put(summary, :next_after, if(length(results) == limit, do: List.last(results).id))
  end

  @doc "Refreshes legacy Wikidata film records through bounded, deduplicated Oban jobs."
  def wikidata(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> bounded_limit!()

    records =
      DevilsDictionary.Sources.SourceRecord
      |> join(:inner, [record], source in assoc(record, :source))
      |> where(
        [record, source],
        source.slug == "wikidata" and source.active and record.display_allowed
      )
      |> after_result(Keyword.get(opts, :after_id))
      |> order_by([record], asc: record.id)
      |> limit(^limit)
      |> Repo.all()

    summary =
      Enum.reduce(records, %{scanned: 0, queued: 0, current: 0, skipped: 0}, fn record, acc ->
        raw = Sources.raw(record) || %{}
        adapter = DevilsDictionary.Absorb.Sources.Wikidata
        {:ok, materialized} = adapter.materialize(%{record | raw: raw})
        concept = materialized |> Map.get(:concepts, []) |> List.first() || %{}

        state =
          if concept[:work_kind] == "film" do
            if raw["_film_identity_version"] == 1 do
              # Replay even an already-materialized record to register its crosswalks.
              {:ok, _} = DevilsDictionary.Absorb.Materializer.run(%{record | raw: raw}, adapter)
              :current
            else
              %{"source" => "wikidata", "target" => record.external_id}
              |> DevilsDictionary.Workers.EnrichWorker.new(
                unique: [
                  period: :infinity,
                  fields: [:worker, :args],
                  states: [:available, :scheduled, :executing, :retryable]
                ]
              )
              |> Oban.insert!()

              :queued
            end
          else
            :skipped
          end

        acc |> Map.update!(:scanned, &(&1 + 1)) |> Map.update!(state, &(&1 + 1))
      end)

    Map.put(summary, :next_after, if(length(records) == limit, do: List.last(records).id))
  end

  defp reconcile_result(result) do
    source = result.run.mapping.source
    record = ensure_record(result, source)
    raw = Sources.raw(record) || %{}

    item = %{
      external_namespace: result.external_namespace,
      external_id: result.external_id,
      identifiers:
        raw["identifiers"] ||
          [%{namespace: result.external_namespace, external_id: result.external_id}],
      preview_metadata: result.preview_metadata,
      match_details: result.match_details
    }

    resolution =
      case CineGraph.identity_record(item) do
        {:ok, entry} ->
          SourceIdentity.resolve(%{
            entry
            | source_id: source.id,
              source_record_id: record.id,
              source_record_revision_id: current_revision_id(record)
          })

        {:error, reason} ->
          %Resolution{state: :insufficient_evidence, reason: to_string(reason)}
      end

    result
    |> Result.changeset(%{
      object_id: resolution.object_id,
      source_record_id: record.id,
      resolution_state: resolution.state
    })
    |> Repo.update!()

    resolution
  end

  defp ensure_record(%Result{source_record: nil} = result, source) do
    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "#{result.external_namespace}:#{result.external_id}",
        url: result.preview_metadata["source_url"],
        raw: %{
          "external_namespace" => result.external_namespace,
          "external_id" => result.external_id,
          "preview_metadata" => result.preview_metadata,
          "match_details" => result.match_details
        }
      })

    record
  end

  defp ensure_record(%Result{source_record: record}, _source), do: record

  defp current_revision_id(record) do
    Repo.one!(
      from revision in SourceRecordRevision,
        where:
          revision.source_record_id == ^record.id and
            revision.revision_key == ^record.content_hash,
        select: revision.id
    )
  end

  defp after_result(query, nil), do: query

  defp after_result(query, id) when is_integer(id) and id > 0,
    do: where(query, [result], result.id > ^id)

  defp after_result(_query, _id), do: raise(ArgumentError, "after_id must be a positive integer")

  defp bounded_limit!(limit) when is_integer(limit) and limit in 1..@max_limit, do: limit

  defp bounded_limit!(_limit),
    do: raise(ArgumentError, "limit must be between 1 and #{@max_limit}")

  defp empty_summary do
    %{
      scanned: 0,
      matched: 0,
      newly_created: 0,
      insufficient_evidence: 0,
      conflicting_identifiers: 0,
      next_after: nil
    }
  end
end
