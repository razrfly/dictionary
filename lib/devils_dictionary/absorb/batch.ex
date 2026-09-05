defmodule DevilsDictionary.Absorb.Batch do
  @moduledoc """
  Pages a source's `source_records` through `Materializer.run_batch/2`.

  Every dump source needs the same loop, and two details in it are easy to get
  wrong, so it lives here rather than in each source:

    * **Keyset pagination, not `Repo.stream`.** A stream needs an enclosing
      transaction, which would fold every batch into one giant transaction and
      lose the per-batch atomicity scorecard row M3 depends on.
    * **`raw` is `load_in_query: false`**, so it has to be selected explicitly
      for exactly the page being materialized — never for the whole table.

  `only_stale: true` (the default) skips records already materialized against
  their current payload, which is the "needs materialization" predicate from
  #69 §5's terminal-state table: `materialized_at IS NULL OR < fetched_at`. A
  re-absorb bumps `fetched_at`, so changed records still come back round.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  @batch 500

  @doc """
  Materializes a source's records, in pages, and sums the counts.

  Options:

    * `:only_stale` — skip records whose `materialized_at` is current (default `true`)
    * `:where` — an extra `Ecto.Query.dynamic/1` filter on the record
    * `:batch_size` — records per transaction (default #{@batch})
    * `:on_batch` — a 1-arity callback given each batch's counts, for progress
  """
  def run(module, %Source{} = source, opts \\ []) do
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
      case Materializer.run_batch(batch, module) do
        {:ok, counts} ->
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

  defp page(source, last_id, opts) do
    Repo.all(
      from r in base(source, opts),
        where: r.id > ^last_id,
        order_by: r.id,
        limit: ^(opts[:batch_size] || @batch),
        select: %{r | raw: r.raw}
    )
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
