defmodule DevilsDictionary.Sources do
  @moduledoc """
  Provenance. Schemas and queries for `sources` (tier, kind, access, license,
  url template live here and nowhere else), `source_records` (the trimmed raw
  truth we fetched, with its canonical url), `people` and `import_runs`.
  Spec: issue #69 §4.
  """

  import Ecto.Query, warn: false

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{ImportRun, Source, SourceRecord}

  @doc """
  Fetches a source by its slug. Raises if the seeds have not been run.
  """
  def get_source_by_slug!(slug) do
    Repo.get_by!(Source, slug: slug)
  end

  def get_source_by_slug(slug), do: Repo.get_by(Source, slug: slug)

  def list_sources do
    Repo.all(from s in Source, order_by: s.slug)
  end

  @doc """
  Inserts or replaces a `source_record`.

  Sets `content_hash` from the payload and bumps `changed_at` when a refetch
  produced different content — that is what the "changed this week" feed reads.
  """
  def upsert_record(%Source{} = source, attrs) do
    now = DateTime.utc_now()
    raw = Map.get(attrs, :raw) || %{}
    hash = SourceRecord.content_hash(raw)

    attrs =
      attrs
      |> Map.put(:source_id, source.id)
      |> Map.put(:content_hash, hash)
      |> Map.put(:fetched_at, now)
      |> Map.put_new(:absent_until, nil)

    %SourceRecord{}
    |> SourceRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict: record_conflict(),
      conflict_target: [:source_id, :external_id],
      returning: true
    )
  end

  @doc """
  The `on_conflict` every `source_records` write must use, single or bulk.

  It is a named query rather than a `{:replace, …}` list because of one column:
  `changed_at` only moves when a refetch actually produced different content,
  and that is what the "changed this week" feed reads. A bulk absorb that rolls
  its own `{:replace, …}` list silently loses it.

  `absent_until` is taken from the incoming row, so a source that had nothing
  for a target sets the marker and a later fetch that finds something clears it
  (#69 §5's terminal states: "source-absent" is not a permanent verdict).
  """
  def record_conflict do
    from(r in SourceRecord,
      update: [
        set: [
          raw: fragment("EXCLUDED.raw"),
          url: fragment("EXCLUDED.url"),
          content_hash: fragment("EXCLUDED.content_hash"),
          fetched_at: fragment("EXCLUDED.fetched_at"),
          updated_at: fragment("EXCLUDED.updated_at"),
          absent_until: fragment("EXCLUDED.absent_until"),
          changed_at:
            fragment(
              "CASE WHEN ?.content_hash IS DISTINCT FROM EXCLUDED.content_hash THEN EXCLUDED.fetched_at ELSE ?.changed_at END",
              r,
              r
            )
        ]
      ]
    )
  end

  @doc """
  Bulk-writes `source_records`, in chunks, with `record_conflict/0`.

  Rows are plain maps needing `external_id`, `url` and `raw`, plus
  `content_hash` when the source trims: the hash must be taken on the payload
  **as fetched**, before `trim/1`, so a change to the trim never reads as a
  change at the source. A source whose trim is the identity may omit it and it
  is computed from `raw` here. A row may also carry `absent_until` to record a
  "source had nothing" marker (`raw: %{}`). `source_id` and the timestamps are
  always filled here. Returns the number of rows written.
  """
  def insert_records(%Source{} = source, rows, chunk \\ 1_000) do
    now = DateTime.utc_now()

    rows
    |> Enum.map(fn row ->
      raw = row[:raw] || %{}

      %{
        source_id: source.id,
        external_id: row.external_id,
        url: row[:url],
        raw: raw,
        content_hash: row[:content_hash] || SourceRecord.content_hash(raw),
        absent_until: row[:absent_until],
        fetched_at: now,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.uniq_by(& &1.external_id)
    |> Enum.chunk_every(chunk)
    |> Enum.reduce(0, fn batch, acc ->
      {n, _} =
        Repo.insert_all(SourceRecord, batch,
          on_conflict: record_conflict(),
          conflict_target: [:source_id, :external_id]
        )

      acc + n
    end)
  end

  @doc """
  Loads a record's `raw` payload, which is `load_in_query: false`.

  Takes a record or a bare id, because the provenance drawer (#71 U2) has an id
  and no reason to load the row twice.
  """
  def raw(%SourceRecord{id: id}), do: raw(id)

  def raw(id) when is_integer(id) do
    Repo.one(from r in SourceRecord, where: r.id == ^id, select: r.raw)
  end

  @doc """
  The metadata of a list of records, in one query, without `raw`.

  What the provenance drawer shows above the fold: the external id, the
  canonical url, the hash and the three timestamps. `raw` is deliberately left
  behind — a WordNet card cites one record per synset, and twenty payloads is
  not a panel, it is a download. The drawer opens one of them with `raw/1`.
  """
  def records(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      []
    else
      by_id =
        Repo.all(
          from r in SourceRecord,
            where: r.id in ^ids,
            select: %{
              id: r.id,
              source_id: r.source_id,
              external_id: r.external_id,
              url: r.url,
              content_hash: r.content_hash,
              fetched_at: r.fetched_at,
              changed_at: r.changed_at,
              materialized_at: r.materialized_at
            }
        )
        |> Map.new(&{&1.id, &1})

      # The caller's order is the order the card cites them in, which is the
      # order the reader sees on the page.
      Enum.flat_map(ids, fn id -> List.wrap(by_id[id]) end)
    end
  end

  @doc """
  One record by source slug and external id.

  The thing side has no `source_record_id` to follow: a concept is keyed by its
  QID, and Wikidata and Wikipedia record it under `"Q…"` and `"concept:Q…"`.
  That is a convention rather than a foreign key, which is why the thing
  panel's provenance is reported and never graded (#71 U2, row U3).
  """
  def record_by_external_id(source_slug, external_id) do
    Repo.one(
      from r in SourceRecord,
        join: s in Source,
        on: s.id == r.source_id,
        where: s.slug == ^source_slug and r.external_id == ^external_id,
        select: %{
          id: r.id,
          source_id: r.source_id,
          external_id: r.external_id,
          url: r.url,
          content_hash: r.content_hash,
          fetched_at: r.fetched_at,
          changed_at: r.changed_at,
          materialized_at: r.materialized_at
        }
    )
  end

  # ── import runs ──────────────────────────────────────────────────────────

  @doc """
  Opens an `import_runs` row in `:running`. Every mix task starts with one.
  """
  def start_run(task, opts \\ []) do
    %ImportRun{}
    |> ImportRun.changeset(%{
      task: task,
      source_id: opts[:source_id],
      scope_id: opts[:scope_id],
      status: :running,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  @doc """
  Closes a run as `:done`, merging the numbers it produced into `stats`.
  """
  def finish_run(%ImportRun{} = run, stats \\ %{}) do
    run
    |> ImportRun.changeset(%{
      status: :done,
      stats: Map.merge(run.stats || %{}, stats),
      finished_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  @doc """
  Closes a run as `:failed`, keeping whatever numbers it got to.
  """
  def fail_run(%ImportRun{} = run, error, stats \\ %{}) do
    run
    |> ImportRun.changeset(%{
      status: :failed,
      error: to_string(error) |> String.slice(0, 4000),
      stats: Map.merge(run.stats || %{}, stats),
      finished_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  def last_run(source_id) do
    Repo.one(
      from r in ImportRun,
        where: r.source_id == ^source_id,
        order_by: [desc: r.started_at],
        limit: 1
    )
  end
end
