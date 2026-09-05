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

    %SourceRecord{}
    |> SourceRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        from(r in SourceRecord,
          update: [
            set: [
              raw: fragment("EXCLUDED.raw"),
              url: fragment("EXCLUDED.url"),
              content_hash: fragment("EXCLUDED.content_hash"),
              fetched_at: fragment("EXCLUDED.fetched_at"),
              updated_at: fragment("EXCLUDED.updated_at"),
              changed_at:
                fragment(
                  "CASE WHEN ?.content_hash IS DISTINCT FROM EXCLUDED.content_hash THEN EXCLUDED.fetched_at ELSE ?.changed_at END",
                  r,
                  r
                )
            ]
          ]
        ),
      conflict_target: [:source_id, :external_id],
      returning: true
    )
  end

  @doc """
  Loads a record's `raw` payload, which is `load_in_query: false`.
  """
  def raw(%SourceRecord{id: id}) do
    Repo.one(from r in SourceRecord, where: r.id == ^id, select: r.raw)
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
