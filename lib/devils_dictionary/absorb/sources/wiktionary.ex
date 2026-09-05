defmodule DevilsDictionary.Absorb.Sources.Wiktionary do
  @moduledoc """
  English Wiktionary, via the Kaikki raw wiktextract dump.

  Two passes, and S0b only runs the first:

    * **index** (`--index`) — stream all ~2.7M records, keep the English ones,
      and write one bare `lexemes` row per (lemma, pos) with its inflected
      `forms`. This is decision #3: the full English index exists from day one,
      so every word has a page even if nothing else has been absorbed about it.
      Bare rows have `enriched_at` nil and no `source_record`.

    * **scoped** (`--scope`) — trimmed raw records plus senses, pronunciations,
      etymology and relations, for the lemmas in a scope. Lands in S1.

  The dump is 2.6 GB compressed and ~23 GB expanded, so it is streamed and never
  written to disk (see `DevilsDictionary.Absorb.GzipLines`).

  ## Why the index stores categories

  The Animals scope rule matches Wiktionary entries carrying a category in the
  `en:Animals` tree, but the dump has no category *hierarchy* — just flat strings
  per entry, mixing grammar labels ("English countable nouns") with topical ones
  ("en:Corvids"). The tree is walked once over the API and pinned into
  `scopes.rules` (`mix dd.scope.categories`); the per-entry side is kept here, in
  `lexemes.metadata["wikt_categories"]`, narrowed to the `en:`-prefixed topical
  ones (a few per record at most).

  That is a small deviation from #69, which describes the index row as carrying
  only `forms`. It buys a lot: without it, every scope build would need a second
  full pass over the 2.6 GB dump. With it, building any future scope is one SQL
  query against a GIN index — which is what scorecard E2 actually promises.
  """

  @behaviour DevilsDictionary.Absorb.Source

  alias DevilsDictionary.Absorb.GzipLines
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  # Fields we never materialize. Dropping them before storing takes a typical
  # record from ~146 KB to ~28 KB (scorecard M4 wants >= 50%).
  @trim ~w(translations descendants etymology_templates head_templates)

  # A cheap reject before the expensive JSON decode. Verified against the real
  # dump's serialization, which puts a space after the colon. It can only
  # over-accept (a nested occurrence), never under-accept, and the decoded
  # record is re-checked properly.
  @en_marker ~S("lang_code": "en")

  @decode_chunk 500
  @insert_chunk 2_000

  # The dump holds ~2.7M records across all languages. Multi-member gzip
  # truncates *silently* with inflateInit/31, so a short read must be an error
  # rather than a quietly tiny index.
  @expect_min_lines 2_000_000

  @impl true
  def slug, do: "wiktionary"

  @impl true
  def rate_limit_ms, do: 0

  @doc """
  Drops the parts of a record we never materialize.

  Kept deliberately blunt — four top-level keys — so it is obvious what was
  thrown away and easy to prove nothing materialized was lost.
  """
  @impl true
  def trim(raw) when is_map(raw), do: Map.drop(raw, @trim)

  @doc """
  The fields this source never keeps.
  """
  def trimmed_keys, do: @trim

  @impl true
  def materialize(_record) do
    raise """
    Wiktionary materialize/1 lands in S1 (scoped absorb).
    S0b runs the index pass only: mix dd.absorb wiktionary --index
    """
  end

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope \\ nil, opts \\ [])

  def absorb(_scope, opts) do
    if opts[:index] do
      index(opts)
    else
      raise """
      Scoped Wiktionary absorb lands in S1. For now:
        mix dd.absorb wiktionary --index
      """
    end
  end

  defp index(opts) do
    source = Sources.get_source_by_slug!(slug())
    path = opts[:path] || source.config["dump_file"]

    unless File.exists?(path) do
      raise """
      Wiktionary dump not found at #{path}.
      Download it first (2.6 GB):
        curl -L -C - -o #{path} #{source.config["dump_url"]}
      """
    end

    if opts[:rebuild_indexes], do: drop_load_indexes()

    stats =
      path
      |> GzipLines.stream!()
      |> then(fn stream ->
        case opts[:limit] do
          nil -> stream
          n -> Stream.take(stream, n)
        end
      end)
      |> Stream.chunk_every(@decode_chunk)
      |> Task.async_stream(&project_chunk(&1, source.id),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(new_stats(), fn {:ok, {rows, counts}}, acc ->
        acc
        |> merge_counts(counts)
        |> buffer(rows)
      end)
      |> flush()

    if opts[:rebuild_indexes], do: create_load_indexes()

    if is_nil(opts[:limit]) and stats.lines < @expect_min_lines do
      raise """
      gzip stream ended after #{stats.lines} lines, expected at least #{@expect_min_lines}.
      Multi-member gzip files truncate silently with inflateInit/31 — check `gzip -t #{path}`.
      """
    end

    {:ok,
     %{
       lines: stats.lines,
       en_records: stats.en,
       form_of_records: stats.form_of,
       with_categories: stats.with_categories,
       lexemes_written: stats.written
     }}
  end

  # ── projection (pure) ────────────────────────────────────────────────────

  defp project_chunk(lines, source_id) do
    Enum.reduce(lines, {[], {length(lines), 0, 0, 0}}, fn line,
                                                          {rows, {n, en, form_of, with_cats}} ->
      if :binary.match(line, @en_marker) == :nomatch do
        {rows, {n, en, form_of, with_cats}}
      else
        # strings: :copy is not optional. Without it every retained lemma is a
        # sub-binary pinning its whole ~2 MB parent chunk, and a batched load
        # pins gigabytes.
        case Jason.decode(line, strings: :copy) do
          {:ok, %{"lang_code" => "en"} = record} ->
            row = index_row(record, source_id)
            cats = row.metadata["wikt_categories"] || []

            {[row | rows],
             {n, en + 1, form_of + if(form_of?(record), do: 1, else: 0),
              with_cats + if(cats == [], do: 0, else: 1)}}

          _ ->
            {rows, {n, en, form_of, with_cats}}
        end
      end
    end)
    |> then(fn {rows, {n, en, form_of, with_cats}} ->
      {rows, %{lines: n, en: en, form_of: form_of, with_categories: with_cats}}
    end)
  end

  @doc """
  Projects one raw Kaikki record onto a bare index row. Pure; unit tested.
  """
  def index_row(record, source_id) do
    lemma = record["word"]

    %{
      lang: "en",
      lemma: lemma,
      pos: record["pos"] || "unknown",
      slug: Lexeme.slug(lemma),
      forms: forms(record),
      pronunciations: [],
      etymology: nil,
      origin_source_id: source_id,
      source_ids: [source_id],
      metadata: metadata(record),
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  defp forms(record) do
    (record["forms"] || [])
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "form")))
    |> Enum.map(&Map.take(&1, ["form", "tags"]))
  end

  @doc """
  The `en:`-prefixed topical categories on a record, entry- and sense-level.
  """
  def categories(record) do
    sense_categories = Enum.flat_map(record["senses"] || [], &(&1["categories"] || []))

    ((record["categories"] || []) ++ sense_categories)
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "en:")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp metadata(record) do
    case categories(record) do
      [] -> %{}
      cats -> %{"wikt_categories" => cats}
    end
  end

  @doc """
  Whether a record is an inflected form of another word ("dogs" -> "dog")
  rather than a headword in its own right. Reported by scorecard row A3.
  """
  def form_of?(record) do
    Enum.any?(record["senses"] || [], fn sense ->
      Map.has_key?(sense, "form_of") or
        Enum.any?(sense["tags"] || [], &(&1 == "form-of"))
    end)
  end

  # ── buffered writing ─────────────────────────────────────────────────────

  defp new_stats,
    do: %{lines: 0, en: 0, form_of: 0, with_categories: 0, written: 0, buffer: [], buffered: 0}

  defp merge_counts(acc, counts) do
    %{
      acc
      | lines: acc.lines + counts.lines,
        en: acc.en + counts.en,
        form_of: acc.form_of + counts.form_of,
        with_categories: acc.with_categories + counts.with_categories
    }
  end

  defp buffer(acc, rows) do
    acc = %{acc | buffer: [rows | acc.buffer], buffered: acc.buffered + length(rows)}
    if acc.buffered >= @insert_chunk, do: flush(acc), else: acc
  end

  defp flush(%{buffered: 0} = acc), do: %{acc | buffer: []}

  defp flush(acc) do
    written =
      acc.buffer
      |> Enum.concat()
      # The unique index cannot help inside a single statement: Postgres rejects
      # a batch that hits the same conflict key twice.
      |> Enum.uniq_by(&{&1.lang, &1.lemma, &1.pos})
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.reduce(0, fn chunk, written ->
        {n, _} =
          Repo.insert_all(Lexeme, chunk,
            placeholders: %{now: DateTime.utc_now()},
            on_conflict: index_conflict(),
            conflict_target: [:lang, :lemma, :pos]
          )

        written + n
      end)

    %{acc | buffer: [], buffered: 0, written: acc.written + written}
  end

  # Merge rather than clobber: WordNet may have created the lexeme first, and it
  # sets neither forms nor categories. `origin_source_id` keeps whoever got here
  # first; `source_ids` accumulates everyone who attests the word.
  defp index_conflict do
    import Ecto.Query

    from(l in Lexeme,
      update: [
        set: [
          forms: fragment("EXCLUDED.forms"),
          metadata: fragment("? || EXCLUDED.metadata", l.metadata),
          origin_source_id:
            fragment("COALESCE(?, EXCLUDED.origin_source_id)", l.origin_source_id),
          source_ids:
            fragment(
              "(SELECT array_agg(DISTINCT x) FROM unnest(? || EXCLUDED.source_ids) AS x)",
              l.source_ids
            ),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # A live gin_trgm_ops index makes a 1.4M-row load several times slower.
  defp drop_load_indexes do
    Repo.query!("SET maintenance_work_mem = '1GB'")
    Repo.query!("DROP INDEX IF EXISTS lexemes_lemma_trgm_index")
    Repo.query!("DROP INDEX IF EXISTS lexemes_forms_index")
    Repo.query!("DROP INDEX IF EXISTS lexemes_metadata_index")
  end

  defp create_load_indexes do
    Repo.query!("SET maintenance_work_mem = '1GB'")

    Repo.query!(
      "CREATE INDEX lexemes_lemma_trgm_index ON lexemes USING gin (lemma gin_trgm_ops)",
      [],
      timeout: :infinity
    )

    Repo.query!("CREATE INDEX lexemes_forms_index ON lexemes USING gin (forms)", [],
      timeout: :infinity
    )

    Repo.query!("CREATE INDEX lexemes_metadata_index ON lexemes USING gin (metadata)", [],
      timeout: :infinity
    )
  end
end
