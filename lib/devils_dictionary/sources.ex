defmodule DevilsDictionary.Sources do
  @moduledoc """
  Provenance: where a row came from, and what it looked like when we read it.

  `sources` holds tier, kind, access and licence and nothing else does.
  `source_records` is a record's stable identity; `source_record_revisions`
  holds the payloads, one per distinct content hash, and **never overwrites
  one**. That split is what makes a citation keep its meaning after the source
  is edited — #74 §B, "Extend stored source records so a cited revision is not
  overwritten".

  People used to live here too. They are entities now (`DevilsDictionary.Registry`),
  so an author and a biography subject cannot be two rows.
  """

  import Ecto.Query, warn: false

  alias DevilsDictionary.Corpus.SourceRecordRevision
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
  Records one observation of a source record.

  Upserts the record's identity, then adds a revision **only if this payload is
  new** — the revision key is the content hash, so a re-fetch that returns the
  same bytes writes nothing and `changed_at` does not move. A re-fetch that
  returns different bytes adds a revision beside the old one, and the old one
  stays citable.

  Returns `{:ok, record}` with `:current_revision` set.
  """
  def upsert_record(%Source{} = source, attrs) do
    now = DateTime.utc_now()
    raw = Map.get(attrs, :raw) || %{}
    hash = attrs[:content_hash] || SourceRecord.content_hash(raw)

    record_attrs =
      attrs
      |> Map.drop([:raw])
      |> Map.merge(%{
        source_id: source.id,
        content_hash: hash,
        fetched_at: now
      })
      |> Map.put_new(:absent_until, nil)

    Repo.transaction(fn ->
      {:ok, record} =
        %SourceRecord{}
        |> SourceRecord.changeset(record_attrs)
        |> Repo.insert(
          on_conflict: record_conflict(),
          conflict_target: [:source_id, :external_id],
          returning: true
        )

      revision = ensure_revision(record, hash, raw, now, attrs[:import_run_id])
      Map.put(record, :current_revision, revision)
    end)
  end

  @doc """
  Adds a revision for this payload if one does not already exist, and returns it.

  `on_conflict: :nothing` returns no row, so the existing revision is read back
  — a caller needs the id either way, and "nothing changed" is the common case
  by a wide margin on a re-absorb.
  """
  def ensure_revision(%SourceRecord{} = record, hash, raw, observed_at \\ nil, run_id \\ nil) do
    observed_at = observed_at || DateTime.utc_now()

    {_n, _} =
      Repo.insert_all(
        SourceRecordRevision,
        [
          %{
            source_record_id: record.id,
            revision_key: hash,
            payload: raw,
            checksum: hash,
            observed_at: observed_at,
            import_run_id: run_id,
            inserted_at: observed_at,
            updated_at: observed_at
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:source_record_id, :revision_key]
      )

    Repo.one(
      from r in SourceRecordRevision,
        where: r.source_record_id == ^record.id and r.revision_key == ^hash
    )
  end

  @doc """
  The `on_conflict` every `source_records` write must use, single or bulk.

  A named query rather than a `{:replace, …}` list because of one column:
  `changed_at` only moves when a re-fetch actually produced different content,
  and that is what the "changed this week" feed reads. A bulk absorb rolling its
  own replace list silently loses it.

  `absent_until` is taken from the incoming row, so a source that had nothing
  sets the marker and a later fetch that finds something clears it — an absence
  is a dated finding, not a permanent verdict.
  """
  def record_conflict do
    from(r in SourceRecord,
      update: [
        set: [
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
  Bulk-writes source records and their revisions, in chunks.

  Rows are plain maps needing `external_id`, `url` and `raw`, plus
  `content_hash` when the source trims — the hash must be taken on the payload
  **as fetched**, before `trim/1`. A source whose trim is the identity may omit
  it and it is computed here. A row may also carry `absent_until` to record a
  "source had nothing" marker with `raw: %{}`.

  Returns the number of records written.
  """
  def insert_records(%Source{} = source, rows, chunk \\ 1_000) do
    now = DateTime.utc_now()

    rows
    |> Enum.map(fn row ->
      raw = row[:raw] || %{}
      hash = row[:content_hash] || SourceRecord.content_hash(raw)
      {%{
         source_id: source.id,
         external_id: row.external_id,
         url: row[:url],
         content_hash: hash,
         absent_until: row[:absent_until],
         fetched_at: now,
         inserted_at: now,
         updated_at: now
       }, hash, raw}
    end)
    |> Enum.uniq_by(fn {record, _, _} -> record.external_id end)
    |> Enum.chunk_every(chunk)
    |> Enum.reduce(0, fn batch, acc ->
      acc + write_batch(source, batch, now)
    end)
  end

  # One chunk: upsert the identities, read back their ids, then bulk-insert the
  # revisions that are new. Two statements rather than one because a revision
  # needs the record id, and `insert_all` cannot return ids for rows that
  # conflicted.
  defp write_batch(source, batch, now) do
    records = Enum.map(batch, fn {record, _, _} -> record end)

    {n, _} =
      Repo.insert_all(SourceRecord, records,
        on_conflict: record_conflict(),
        conflict_target: [:source_id, :external_id]
      )

    external_ids = Enum.map(records, & &1.external_id)

    ids =
      Repo.all(
        from r in SourceRecord,
          where: r.source_id == ^source.id and r.external_id in ^external_ids,
          select: {r.external_id, r.id}
      )
      |> Map.new()

    revisions =
      for {record, hash, raw} <- batch, id = ids[record.external_id], !is_nil(id) do
        %{
          source_record_id: id,
          revision_key: hash,
          payload: raw,
          checksum: hash,
          observed_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(SourceRecordRevision, revisions,
      on_conflict: :nothing,
      conflict_target: [:source_record_id, :revision_key]
    )

    n
  end

  @doc """
  Loads a record's current payload.

  The current revision is the one whose `revision_key` equals the record's
  `content_hash` — the two are the same value by construction, so this needs no
  pointer column and cannot drift out of step with it.

  Takes a record or a bare id, because the provenance drawer (#71 U2) has an id
  and no reason to load the row twice.
  """
  def raw(%SourceRecord{id: id}), do: raw(id)

  def raw(id) when is_integer(id) do
    Repo.one(
      from rev in SourceRecordRevision,
        join: rec in assoc(rev, :source_record),
        where: rec.id == ^id and rev.revision_key == rec.content_hash,
        select: rev.payload
    )
  end

  @doc """
  Fills the virtual `raw` from the current revision, for a record or a list.

  `materialize/1` is a pure function of a record, so the payload has to be on
  the struct before an adapter sees it. The list clause does it in one query
  because a per-record load would be N+1 across a 500-record batch.
  """
  def with_raw(%SourceRecord{} = record) do
    %{record | raw: raw(record.id) || %{}}
  end

  def with_raw(records) when is_list(records) do
    ids = Enum.map(records, & &1.id)

    payloads =
      Repo.all(
        from rev in SourceRecordRevision,
          join: rec in assoc(rev, :source_record),
          where: rec.id in ^ids and rev.revision_key == rec.content_hash,
          select: {rec.id, rev.payload}
      )
      |> Map.new()

    Enum.map(records, &%{&1 | raw: Map.get(payloads, &1.id, %{})})
  end

  @doc """
  Every stored revision of a record, newest observation first.

  This is what makes a citation durable: the revision a claim cited is still
  here after the source has moved on.
  """
  def revisions(record_id) do
    Repo.all(
      from r in SourceRecordRevision,
        where: r.source_record_id == ^record_id,
        order_by: [desc: r.observed_at, desc: r.id],
        select: %{
          id: r.id,
          revision_key: r.revision_key,
          observed_at: r.observed_at,
          import_run_id: r.import_run_id
        }
    )
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
