defmodule DevilsDictionary.Absorb.Batch do
  @moduledoc """
  Pages a source's `source_records` through `Materializer.run_batch/2`.

  Every dump source needs the same loop, and two details in it are easy to get
  wrong, so it lives here rather than in each source:

    * **Keyset pagination, not `Repo.stream`.** A stream needs an enclosing
      transaction, which would fold every batch into one giant transaction and
      lose the per-batch atomicity scorecard row M3 depends on.
    * **`raw` is virtual**, so it is filled from the record's current revision
      after each page loads rather than selected
      for exactly the page being materialized — never for the whole table.

  `only_stale: true` (the default) skips records already materialized against
  their current payload, which is the "needs materialization" predicate from
  #69 §5's terminal-state table: `materialized_at IS NULL OR < fetched_at`. A
  re-absorb bumps `fetched_at`, so changed records still come back round.

  ## Every batch is stamped, and every batch reconciles

  This is where the audit's finding #1 stops being a test and starts being the
  import path. Each batch is materialized under a run id and then
  `Materializer.reconcile/2` retires whatever that run did **not** re-stamp for
  the records it just visited — scoped to those records, so a scoped import
  that touched 200 of them cannot retire the other 340,000.

  A caller that already owns a run passes `:run_id`; one that does not gets a
  `materialize` run opened and finished here. Doing it at this level rather than
  in each source is deliberate: an unstamped output is invisible until a refresh
  silently keeps something a source withdrew, and that is not a mistake a new
  source should be able to make by forgetting a keyword.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  @batch 500

  @doc """
  Materializes a source's records, in pages, and sums the counts.

  Options:

    * `:only_stale` — skip records whose `materialized_at` is current (default `true`)
    * `:where` — an extra `Ecto.Query.dynamic/1` filter on the record
    * `:batch_size` — records per transaction (default #{@batch})
    * `:on_batch` — a 1-arity callback given each batch's counts, for progress
    * `:run_id` — the run every output is stamped with; one is opened if absent
    * `:reconcile` — set `false` to stamp without retiring (default `true`)
  """
  def run(module, %Source{} = source, opts \\ []) do
    own = if opts[:run_id], do: nil, else: Sources.start_run("materialize", source_id: source.id)
    run_id = opts[:run_id] || own.id

    counts = do_run(module, source, opts, run_id)

    if own, do: Sources.finish_run(own, Map.new(counts, fn {k, v} -> {to_string(k), v} end))

    counts
  end

  defp do_run(module, source, opts, run_id) do
    zero = %{
      records: 0,
      lexemes: 0,
      concepts: 0,
      senses: 0,
      entries: 0,
      relations: 0,
      links: 0,
      concept_relations: 0,
      concept_relations_skipped: 0,
      concept_relations_skipped_parent_taxon: 0,
      concept_relations_skipped_unchased: 0
    }

    source
    |> stream(opts)
    |> Enum.reduce(zero, fn batch, acc ->
      case Materializer.run_batch(batch, module, run_id: run_id) do
        {:ok, counts} ->
          if Keyword.get(opts, :reconcile, true) do
            record_ids = Enum.map(batch, & &1.id)
            Materializer.reconcile(run_id, record_ids)
            refresh_shared_content(module, record_ids, run_id)
          end

          if cb = opts[:on_batch], do: cb.(counts)

          acc
          |> Map.update!(:records, &(&1 + length(batch)))
          |> Map.update!(:lexemes, &(&1 + counts.lexemes))
          |> Map.update!(:concepts, &(&1 + counts.concepts))
          |> Map.update!(:senses, &(&1 + counts.senses))
          |> Map.update!(:entries, &(&1 + counts.entries))
          |> Map.update!(:relations, &(&1 + counts.relations))
          |> Map.update!(:links, &(&1 + counts.links))
          |> Map.update!(:concept_relations, &(&1 + counts.concept_relations))
          |> Map.update!(:concept_relations_skipped, &(&1 + counts.concept_relations_skipped))
          |> Map.update!(
            :concept_relations_skipped_parent_taxon,
            &(&1 + counts.concept_relations_skipped_parent_taxon)
          )
          |> Map.update!(
            :concept_relations_skipped_unchased,
            &(&1 + counts.concept_relations_skipped_unchased)
          )

        {:error, reason} ->
          raise "materialize failed for #{module.slug()}: #{inspect(reason)}"
      end
    end)
  end

  @doc """
  A lazy stream of record pages, `raw` loaded, ordered by id.
  """
  def stream(%Source{} = source, opts \\ []) do
    Stream.unfold(0, fn last_id ->
      case page(source, last_id, opts) do
        [] -> nil
        records -> {records, List.last(records).id}
      end
    end)
  end

  @doc """
  How many records the same options would visit. Used by the progress lines and
  by `mix dd.materialize --dry-run`.
  """
  def count(%Source{} = source, opts \\ []) do
    Repo.aggregate(base(source, opts), :count)
  end

  # `raw` is virtual now — the payload lives in `source_record_revisions` so a
  # cited revision is never overwritten — so it is filled after the page loads
  # rather than selected. `Sources.with_raw/1` does it in one query for the
  # whole page, because `materialize/1` is a pure function of a record and the
  # payload has to be on the struct before an adapter sees it.
  # If the selected observation disappears, an unchanged surviving observation
  # must replace it even in a stale-only import. Do not wait for a full replay.
  defp refresh_shared_content(module, changed_records, run_id) do
    records =
      Repo.query!(
        """
        SELECT DISTINCT chosen.id FROM content_revisions cr
        JOIN source_record_revisions rr ON rr.id=cr.source_record_revision_id
        CROSS JOIN LATERAL (
          SELECT sr.id FROM source_materialized_outputs o
          JOIN source_records sr ON sr.id=o.source_record_id
          WHERE o.output_object_id=cr.content_id AND o.output_role='content' AND o.retired_at IS NULL
          ORDER BY sr.external_id COLLATE "C" LIMIT 1
        ) chosen
        WHERE cr.is_current AND rr.source_record_id=ANY($1)
          AND NOT EXISTS (SELECT 1 FROM source_materialized_outputs own
            WHERE own.source_record_id=rr.source_record_id AND own.output_object_id=cr.content_id
              AND own.output_role='content' AND own.retired_at IS NULL)
        """,
        [changed_records]
      ).rows
      |> Enum.map(&hd/1)

    if records != [] do
      batch = Repo.all(from r in SourceRecord, where: r.id in ^records) |> Sources.with_raw()

      case Materializer.run_batch(batch, module, run_id: run_id) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "shared publication refresh failed: #{inspect(reason)}"
      end
    end
  end

  defp page(source, last_id, opts) do
    Repo.all(
      from r in base(source, opts),
        where: r.id > ^last_id,
        order_by: r.id,
        limit: ^(opts[:batch_size] || @batch)
    )
    |> Sources.with_raw()
  end

  defp base(source, opts) do
    query = from(r in SourceRecord, where: r.source_id == ^source.id)

    query =
      if Keyword.get(opts, :only_stale, true) do
        from r in query,
          where: is_nil(r.materialized_at) or r.materialized_at < r.fetched_at
      else
        query
      end

    case opts[:where] do
      nil -> query
      dynamic -> from(r in query, where: ^dynamic)
    end
  end
end
