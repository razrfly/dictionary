defmodule DevilsDictionary.Absorb.Materializer do
  @moduledoc """
  Turns raw `source_records` into normalized rows, inside one transaction.

  A source module's `materialize/1` is **pure**: raw record in, plain maps out,
  no `Repo`, no network. That is what makes scorecard rows M1 (parity), M2
  (re-materialize offline) and O3 (offline tests) achievable, and it is why
  `materialize/1` is unit-tested against checked-in fixtures.

  Purity costs one indirection: the output rows must reference each other before
  any of them has a database id. So `materialize/1` returns **local keys** and
  this module resolves them:

      lexemes   %{key: {lang, lemma, pos}, lemma: .., pos: .., ..}
      senses    %{key: external_id, lexeme: {lang, lemma, pos}, ..}
      entries   %{lexeme: {lang, lemma, pos} | nil, concept: qid | nil, ..}
      relations %{from_lexeme: {..}, from_sense: external_id | nil, to_lemma: ..}
      concepts  %{key: qid, qid: qid, taxon_concept: qid | nil, ..}
      links     %{lexeme: {..}, sense: external_id | nil, concept: qid, ..}
      concept_relations %{from_concept: qid, to_concept: qid, type: .., property: ..}

  Concept-to-concept references (`concept_relations` and `concepts.taxon_concept_id`)
  reach outside the batch: a P171 edge names a parent that another record
  introduces. Those qids are resolved against the batch first and then against
  the database, inside the same transaction; anything still unknown is counted
  and skipped, never raised on. A source that walks a parent closure therefore
  materializes twice — the second pass with `only_stale: false` — and the
  residual count should be zero.

  Every write is an upsert on the unique keys of issue #69 §4, so running this
  twice is a no-op (M2). Every write and the record's `materialized_at` stamp
  happen in one `Ecto.Multi`, so a record can never be marked materialized
  without its rows, and a failure leaves neither (M3).

  Two rules worth stating, because both are silent when broken:

    * `on_conflict` must always UPDATE, never `:nothing` — `insert_all` returns
      no row for a conflicting entry, so `:nothing` would hand back an empty id
      map on the second run and write orphans.
    * The two expression unique indexes (`coalesce(from_sense_id, 0)` and
      `coalesce(sense_id, 0)`) cannot be named by column list, so their
      `conflict_target` is an `:unsafe_fragment` that must match the migration
      character for character.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.SourceRecord

  # Postgres caps a statement at 65,535 bind parameters; the widest row here is
  # ~14 columns, so 2,000 leaves plenty of headroom.
  @chunk 2_000

  @empty %{
    lexemes: [],
    senses: [],
    entries: [],
    relations: [],
    concepts: [],
    links: [],
    concept_relations: []
  }

  @doc """
  Materializes one record. Used by `enrich/2` and by the tests.
  """
  def run(%SourceRecord{} = record, module), do: run_batch([record], module)

  @doc """
  Materializes a batch of records in one transaction.

  Bulk sources call this: 120k single-record transactions would be minutes of
  commit overhead, and batching also dedupes lexemes across records (`cat`
  appears in eight WordNet synsets). Atomicity still holds per batch — no
  record is stamped without its rows.
  """
  def run_batch([], _module), do: {:ok, %{}}

  def run_batch(records, module) do
    try do
      do_run_batch(records, module)
    catch
      {:materialize_failed, source_id, external_id, reason} ->
        {:error, {:materialize, {source_id, external_id, reason}}}
    end
  end

  defp do_run_batch(records, module) do
    merged = collect(records, module)
    now = DateTime.utc_now()
    record_ids = Enum.map(records, & &1.id)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:lexemes, fn _repo, _ -> {:ok, upsert_lexemes(merged.lexemes, now)} end)
    |> Ecto.Multi.run(:concepts, fn _repo, _ -> {:ok, upsert_concepts(merged.concepts, now)} end)
    |> Ecto.Multi.run(:taxon_concepts, fn _repo, changes ->
      {:ok, link_taxon_concepts(merged.concepts, changes.concepts, now)}
    end)
    |> Ecto.Multi.run(:concept_relations, fn _repo, changes ->
      {:ok, upsert_concept_relations(merged.concept_relations, changes.concepts, now)}
    end)
    |> Ecto.Multi.run(:senses, fn _repo, changes ->
      {:ok, upsert_senses(merged.senses, changes.lexemes, now)}
    end)
    |> Ecto.Multi.run(:entries, fn _repo, changes ->
      {:ok, upsert_entries(merged.entries, changes, now)}
    end)
    |> Ecto.Multi.run(:relations, fn _repo, changes ->
      {:ok, upsert_relations(merged.relations, changes, now)}
    end)
    |> Ecto.Multi.run(:links, fn _repo, changes ->
      {:ok, upsert_links(merged.links, changes, now)}
    end)
    |> Ecto.Multi.run(:source_ids, fn _repo, changes ->
      {:ok, stamp_source_ids(changes, records, now)}
    end)
    |> Ecto.Multi.run(:enriched, fn _repo, changes ->
      {:ok, stamp_enriched_at(merged, changes, now)}
    end)
    |> Ecto.Multi.update_all(
      :materialized,
      from(r in SourceRecord, where: r.id in ^record_ids),
      set: [materialized_at: now, updated_at: now]
    )
    |> Repo.transaction(timeout: :infinity)
    |> case do
      {:ok, changes} -> {:ok, counts(changes, merged)}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  # ── collect ──────────────────────────────────────────────────────────────

  defp collect(records, module) do
    records
    |> Enum.reduce(@empty, fn record, acc ->
      out =
        case module.materialize(record) do
          {:ok, out} ->
            out

          {:error, reason} ->
            throw({:materialize_failed, record.source_id, record.external_id, reason})
        end

      Map.new(@empty, fn {kind, _} ->
        {kind, Map.get(out, kind, []) ++ Map.fetch!(acc, kind)}
      end)
    end)
    |> Map.update!(:lexemes, &dedupe_by(&1, :key))
    |> Map.update!(:concepts, &dedupe_by(&1, :key))
    |> Map.update!(:senses, &dedupe_by(&1, :key))
  end

  # Later rows win, matching "replaced, never edited".
  defp dedupe_by(rows, key), do: rows |> Map.new(&{Map.fetch!(&1, key), &1}) |> Map.values()

  # ── lexemes ──────────────────────────────────────────────────────────────

  # Merge, never clobber: a lexeme may already exist because another source
  # introduced it. `forms` only fills an empty slot, `metadata` merges,
  # `origin_source_id` keeps whoever got there first.
  defp lexeme_conflict do
    from(l in Lexeme,
      update: [
        set: [
          forms:
            fragment("CASE WHEN ? = '[]'::jsonb THEN EXCLUDED.forms ELSE ? END", l.forms, l.forms),
          pronunciations:
            fragment(
              "CASE WHEN ? = '[]'::jsonb THEN EXCLUDED.pronunciations ELSE ? END",
              l.pronunciations,
              l.pronunciations
            ),
          metadata: fragment("? || EXCLUDED.metadata", l.metadata),
          etymology: fragment("COALESCE(?, EXCLUDED.etymology)", l.etymology),
          etymology_source_id:
            fragment("COALESCE(?, EXCLUDED.etymology_source_id)", l.etymology_source_id),
          origin_source_id:
            fragment("COALESCE(?, EXCLUDED.origin_source_id)", l.origin_source_id),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp upsert_lexemes([], _now), do: %{}

  defp upsert_lexemes(rows, now) do
    rows
    |> Enum.map(fn row ->
      {lang, lemma, pos} = row.key

      %{
        lang: lang,
        lemma: lemma,
        pos: pos,
        slug: row[:slug] || Lexeme.slug(lemma),
        forms: row[:forms] || [],
        pronunciations: row[:pronunciations] || [],
        etymology: row[:etymology],
        etymology_source_id: row[:etymology_source_id],
        origin_source_id: row[:origin_source_id],
        source_ids: [],
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_returning(Lexeme,
      on_conflict: lexeme_conflict(),
      conflict_target: [:lang, :lemma, :pos],
      returning: [:id, :lang, :lemma, :pos]
    )
    |> Map.new(fn r -> {{r.lang, r.lemma, r.pos}, r.id} end)
  end

  # ── concepts ─────────────────────────────────────────────────────────────

  # Merge, never clobber — the same contract as `lexeme_conflict/0`, and for the
  # same reason: two sources describe one concept from different sides.
  # Wikipedia knows the title, pageid and thumbnail; Wikidata knows the taxon,
  # the ILI and P18. Whichever lands second must not blank the other's columns.
  #
  # `kind` needs its own clause because it is NOT NULL with a default, so an
  # incoming row cannot say "no opinion" with a nil. `"thing"` *is* the no-opinion
  # value, so it never overwrites a `taxon` already established by Wikidata.
  defp concept_conflict do
    from(c in Concept,
      update: [
        set: [
          label: fragment("COALESCE(EXCLUDED.label, ?)", c.label),
          description: fragment("COALESCE(EXCLUDED.description, ?)", c.description),
          kind:
            fragment("CASE WHEN EXCLUDED.kind = 'thing' THEN ? ELSE EXCLUDED.kind END", c.kind),
          wikipedia_title: fragment("COALESCE(EXCLUDED.wikipedia_title, ?)", c.wikipedia_title),
          wikipedia_pageid:
            fragment("COALESCE(EXCLUDED.wikipedia_pageid, ?)", c.wikipedia_pageid),
          image_url: fragment("COALESCE(EXCLUDED.image_url, ?)", c.image_url),
          image_attribution:
            fragment("COALESCE(EXCLUDED.image_attribution, ?)", c.image_attribution),
          wordnet_ili: fragment("COALESCE(EXCLUDED.wordnet_ili, ?)", c.wordnet_ili),
          taxon: fragment("? || EXCLUDED.taxon", c.taxon),
          metadata: fragment("? || EXCLUDED.metadata", c.metadata),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp upsert_concepts([], _now), do: %{}

  defp upsert_concepts(rows, now) do
    rows
    |> Enum.map(fn row ->
      %{
        qid: row.qid,
        label: row[:label],
        description: row[:description],
        kind: row[:kind] || :thing,
        wikipedia_title: row[:wikipedia_title],
        wikipedia_pageid: row[:wikipedia_pageid],
        image_url: row[:image_url],
        image_attribution: row[:image_attribution],
        wordnet_ili: row[:wordnet_ili],
        taxon: row[:taxon] || %{},
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_returning(Concept,
      on_conflict: concept_conflict(),
      conflict_target: [:qid],
      returning: [:id, :qid]
    )
    |> Map.new(fn r -> {r.qid, r.id} end)
  end

  # `concepts.taxon_concept_id` points at another concept (Q146 cat → Q20980826
  # Felis catus), so it cannot be part of the insert: the target may not exist
  # until a later record introduces it.
  defp link_taxon_concepts(rows, concept_ids, now) do
    pairs =
      for row <- rows,
          target = row[:taxon_concept],
          not is_nil(target),
          do: {row.qid, target}

    if pairs == [] do
      0
    else
      ids = resolve_qids(concept_ids, Enum.flat_map(pairs, fn {a, b} -> [a, b] end))

      pairs
      |> Enum.flat_map(fn {from, to} ->
        with from_id when not is_nil(from_id) <- Map.get(ids, from),
             to_id when not is_nil(to_id) <- Map.get(ids, to),
             true <- from_id != to_id do
          [{from_id, to_id}]
        else
          _ -> []
        end
      end)
      |> Enum.reduce(0, fn {from_id, to_id}, acc ->
        {n, _} =
          Repo.update_all(
            from(c in Concept, where: c.id == ^from_id),
            set: [taxon_concept_id: to_id, updated_at: now]
          )

        acc + n
      end)
    end
  end

  # ── concept relations ────────────────────────────────────────────────────

  defp upsert_concept_relations([], _concept_ids, _now), do: %{written: 0, skipped: 0}

  defp upsert_concept_relations(rows, concept_ids, now) do
    qids = Enum.flat_map(rows, &[&1.from_concept, &1.to_concept])
    ids = resolve_qids(concept_ids, qids)

    {resolved, skipped} =
      Enum.split_with(rows, fn row ->
        from_id = Map.get(ids, row.from_concept)
        to_id = Map.get(ids, row.to_concept)
        not is_nil(from_id) and not is_nil(to_id) and from_id != to_id
      end)

    written =
      resolved
      |> Enum.map(fn row ->
        %{
          source_id: row.source_id,
          from_concept_id: Map.fetch!(ids, row.from_concept),
          to_concept_id: Map.fetch!(ids, row.to_concept),
          type: row.type,
          property: row[:property],
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.uniq_by(&{&1.source_id, &1.from_concept_id, &1.to_concept_id, &1.type})
      |> insert_count(ConceptRelation,
        on_conflict: {:replace, [:property, :updated_at]},
        conflict_target: [:from_concept_id, :to_concept_id, :type, :source_id]
      )

    # A skip is a parent no record has introduced *yet*. Counted rather than
    # swallowed, so `Wikidata.absorb/2` knows whether another pass is owed and
    # M1 does not have to discover it later.
    %{written: written, skipped: length(skipped)}
  end

  # Batch first, then one query for whatever the batch did not introduce.
  defp resolve_qids(concept_ids, qids) do
    missing = qids |> Enum.uniq() |> Enum.reject(&Map.has_key?(concept_ids, &1))

    from_db =
      if missing == [] do
        %{}
      else
        Repo.all(from c in Concept, where: c.qid in ^missing, select: {c.qid, c.id})
        |> Map.new()
      end

    Map.merge(from_db, concept_ids)
  end

  # ── senses ───────────────────────────────────────────────────────────────

  defp upsert_senses([], _lexeme_ids, _now), do: %{}

  defp upsert_senses(rows, lexeme_ids, now) do
    rows
    |> Enum.map(fn row ->
      %{
        lexeme_id: Map.fetch!(lexeme_ids, row.lexeme),
        source_id: row.source_id,
        source_record_id: row[:source_record_id],
        external_id: row.key,
        group_key: row[:group_key],
        gloss: row[:gloss],
        url: row[:url],
        position: row[:position] || 0,
        tags: row[:tags] || [],
        topics: row[:topics] || [],
        examples: row[:examples] || [],
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_returning(Sense,
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:source_id, :external_id],
      returning: [:id, :external_id]
    )
    |> Map.new(fn r -> {r.external_id, r.id} end)
  end

  # ── entries ──────────────────────────────────────────────────────────────

  defp upsert_entries([], _changes, _now), do: 0

  defp upsert_entries(rows, changes, now) do
    rows
    |> Enum.map(fn row ->
      %{
        source_id: row.source_id,
        source_record_id: row[:source_record_id],
        lexeme_id: row[:lexeme] && Map.fetch!(changes.lexemes, row.lexeme),
        concept_id: row[:concept] && Map.fetch!(changes.concepts, row.concept),
        author_id: row[:author_id],
        headword: row[:headword],
        pos: row[:pos],
        body: row[:body],
        body_format: row[:body_format] || :text,
        url: row[:url],
        thumbnail_url: row[:thumbnail_url],
        year: row[:year],
        position: row[:position] || 0,
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count(Entry,
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:source_record_id, :position]
    )
  end

  # ── lexical relations ────────────────────────────────────────────────────

  defp upsert_relations([], _changes, _now), do: 0

  defp upsert_relations(rows, changes, now) do
    rows
    |> Enum.map(fn row ->
      %{
        source_id: row.source_id,
        from_lexeme_id: Map.fetch!(changes.lexemes, row.from_lexeme),
        from_sense_id: row[:from_sense] && Map.get(changes.senses, row.from_sense),
        to_lemma: row.to_lemma,
        to_pos: row[:to_pos],
        to_lexeme_id: nil,
        to_sense_id: nil,
        to_group_key: row[:to_group_key],
        type: row.type,
        subtype: row[:subtype],
        weight: row[:weight] || 1.0,
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    # Dedupe in-process too: the unique index cannot help inside one statement,
    # and Postgres rejects a batch that hits the same key twice.
    |> Enum.uniq_by(&{&1.source_id, &1.from_lexeme_id, &1.from_sense_id, &1.to_lemma, &1.type})
    |> insert_count(LexicalRelation,
      on_conflict: {:replace, [:subtype, :weight, :metadata, :to_group_key, :updated_at]},
      conflict_target:
        {:unsafe_fragment,
         "(source_id, from_lexeme_id, coalesce(from_sense_id, 0), to_lemma, type)"}
    )
  end

  # ── concept links ────────────────────────────────────────────────────────

  defp upsert_links([], _changes, _now), do: 0

  defp upsert_links(rows, changes, now) do
    rows
    |> Enum.map(fn row ->
      %{
        lexeme_id: Map.fetch!(changes.lexemes, row.lexeme),
        sense_id: row[:sense] && Map.get(changes.senses, row.sense),
        concept_id: Map.fetch!(changes.concepts, row.concept),
        source_id: row[:source_id],
        method: row.method,
        confidence: row[:confidence],
        status: row[:status] || :auto,
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.uniq_by(&{&1.lexeme_id, &1.sense_id, &1.concept_id, &1.method})
    |> insert_count(ConceptLink,
      on_conflict: {:replace, [:confidence, :status, :metadata, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(lexeme_id, coalesce(sense_id, 0), concept_id, method)"}
    )
  end

  # ── cached columns ───────────────────────────────────────────────────────

  # `lexemes.source_ids` is the cached "who attests this word" array; it makes
  # "crowd-only words" a filter rather than a join.
  defp stamp_source_ids(changes, records, now) do
    ids = Map.values(changes.lexemes)
    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()

    if ids == [] or source_ids == [] do
      0
    else
      {count, _} =
        Repo.update_all(
          from(l in Lexeme,
            where: l.id in ^ids and not fragment("? @> ?", l.source_ids, ^source_ids),
            update: [
              set: [
                source_ids:
                  fragment(
                    "(SELECT array_agg(DISTINCT x) FROM unnest(? || ?::bigint[]) AS x)",
                    l.source_ids,
                    ^source_ids
                  ),
                updated_at: ^now
              ]
            ]
          ),
          []
        )

      count
    end
  end

  # A lexeme is "enriched" once a source has said something *about it*. Bare
  # index rows keep `enriched_at` nil, which is what A3 and the "bare rows"
  # filter read.
  #
  # Per lexeme, not per batch. WordNet gets away with the cruder version because
  # every synset yields a sense for every member, but a scoped Wiktionary batch
  # mixes words that gained senses with words that only had their `forms`
  # touched, and marking the latter enriched would quietly inflate A3 and put
  # empty cards on the word page.
  defp stamp_enriched_at(merged, changes, now) do
    keys =
      Enum.map(merged.senses, & &1.lexeme) ++
        (merged.entries |> Enum.map(& &1[:lexeme]) |> Enum.reject(&is_nil/1))

    ids =
      keys
      |> Enum.uniq()
      |> Enum.map(&Map.get(changes.lexemes, &1))
      |> Enum.reject(&is_nil/1)

    if ids == [] do
      0
    else
      {count, _} =
        Repo.update_all(
          from(l in Lexeme, where: l.id in ^ids and is_nil(l.enriched_at)),
          set: [enriched_at: now, updated_at: now]
        )

      count
    end
  end

  # ── insert helpers ───────────────────────────────────────────────────────

  defp insert_returning(rows, schema, opts) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      {_n, returned} = Repo.insert_all(schema, chunk, opts)
      returned || []
    end)
  end

  defp insert_count(rows, schema, opts) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} = Repo.insert_all(schema, chunk, opts)
      acc + n
    end)
  end

  defp counts(changes, merged) do
    %{
      lexemes: map_size(changes.lexemes),
      concepts: map_size(changes.concepts),
      senses: map_size(changes.senses),
      entries: changes.entries,
      relations: changes.relations,
      links: changes.links,
      concept_relations: changes.concept_relations.written,
      concept_relations_skipped: changes.concept_relations.skipped,
      relations_offered: length(merged.relations),
      concept_relations_offered: length(merged.concept_relations)
    }
  end
end
