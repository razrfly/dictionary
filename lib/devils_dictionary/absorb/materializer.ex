defmodule DevilsDictionary.Absorb.Materializer do
  @moduledoc """
  Turns raw `source_records` into registry objects and assertions, in one
  transaction.

  A source module's `materialize/1` is **pure**: raw record in, plain maps out,
  no `Repo`, no network. That is what makes scorecard rows M1 (parity), M2
  (rebuild offline) and O3 (offline tests) achievable, and it is why
  `materialize/1` is unit-tested against checked-in fixtures.

  Purity costs one indirection: the output rows must reference each other before
  any of them has a database id. So `materialize/1` returns **local keys** and
  this module resolves them. The seven key names are the source's vocabulary and
  have not changed; what each one *becomes* has:

      lexemes           %{key: {lang, lemma, pos}, ..}       -> objects + lexemes + lexeme_forms
      senses            %{key: external_key, lexeme: {..}}   -> objects + senses + sense_revisions
      entries           %{key: .., lexeme: | concept: , ..}  -> objects + content_items
                                                              + content_revisions
                                                              + `defines` / `about`
                                                              + `authored_by` / `published_in`
      relations         %{from_lexeme:, from_sense:, type:}  -> assertions on the source-native
                                                                lexical predicates, or a
                                                                `pending_relations` row
      concepts          %{key: qid, ..}                      -> objects + entities
                                                              + external_identifiers
      links             %{lexeme:, sense:, concept: qid}     -> `refers_to` /
                                                                `lexeme_entity_candidate`
      concept_relations %{from_concept:, to_concept:, type:} -> `parent_taxon` / `subclass_of` /
                                                                `instance_of` / `taxon_item`

  Cross-batch references (a P171 edge names a parent another record introduces)
  are resolved against the batch first and then against the database, inside the
  same transaction; anything still unknown is counted and skipped, never raised
  on. A source that walks a parent closure therefore materializes twice — the
  second pass with `only_stale: false` — and the residual count should be zero.

  ## What changed from MVP-0, and why

  **Every object is two rows.** An `objects` row and its typed subtype, and the
  database checks at COMMIT that both exist. New identities are created in two
  steps — insert the objects, then the subtypes with the returned ids — because
  a bulk insert cannot see its own generated keys. Two concurrent batches racing
  for the same new word will have one of them rolled back by the `lexical_key`
  unique index rather than leaving an orphan; materialization is serial per
  source, so this is a documented consequence rather than a hot path.

  **Text is a revision, not a column.** A sense's gloss and a definition's body
  go to `sense_revisions` / `content_revisions`, and a new revision is written
  **only when the text actually differs**. Re-importing identical input produces
  zero new revisions, which is what M2 measures and what the Gate 0 spike proved
  on the real Wiktionary `bank` record.

  **Outputs are owned.** Every row this writes is stamped in
  `source_materialized_outputs` / `source_assertion_outputs` with the run that
  last emitted it. `reconcile/2` retires what a run stopped emitting — the
  audit's finding #1, that refresh was purely additive. Retired, never deleted,
  and only ever this source's own output: withdrawing a Wiktionary sense must
  not touch WordNet's support for the same word.

  Two rules worth stating, because both are silent when broken:

    * `on_conflict` must always UPDATE, never `:nothing` — `insert_all` returns
      no row for a conflicting entry, so `:nothing` would hand back an empty id
      map on the second run and write orphans.
    * A predicate's endpoint rules are a real foreign key, so an assertion with
      an impossible pair is refused here exactly as it is refused in a
      changeset. That is deliberate: this module writes with `insert_all`.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.SenseIdentity
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.Sources.SourceRecord

  # Postgres caps a statement at 65,535 bind parameters; the widest row here is
  # ~16 columns, so 2,000 leaves plenty of headroom.
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

  @doc "The shape `materialize/1` may return. A source emits only the kinds it has."
  def empty_output, do: @empty

  @doc """
  Materializes one record. Used by `enrich/2` and by the tests.
  """
  def run(%SourceRecord{} = record, module, opts \\ []), do: run_batch([record], module, opts)

  @doc """
  Materializes a batch of records in one transaction.

  Bulk sources call this: 120k single-record transactions would be minutes of
  commit overhead, and batching also dedupes lexemes across records (`cat`
  appears in eight WordNet synsets). Atomicity still holds per batch — no
  record is stamped without its rows.

  Options: `:run_id`, stamped on every output so `reconcile/2` can tell this
  run's work from the last one's.
  """
  def run_batch(records, module, opts \\ [])

  def run_batch([], _module, _opts), do: {:ok, %{}}

  def run_batch(records, module, opts) do
    try do
      do_run_batch(records, module, opts)
    catch
      {:materialize_failed, source_id, external_id, reason} ->
        {:error, {:materialize, {source_id, external_id, reason}}}
    end
  end

  defp do_run_batch(records, module, opts) do
    merged = collect(records, module)
    now = DateTime.utc_now()
    run_id = opts[:run_id]
    record_ids = Enum.map(records, & &1.id)
    revisions = revision_ids(record_ids)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:lexemes, fn _repo, _ -> {:ok, upsert_lexemes(merged.lexemes, now)} end)
    |> Ecto.Multi.run(:forms, fn _repo, changes ->
      {:ok, upsert_forms(merged.lexemes, changes.lexemes, revisions, now)}
    end)
    |> Ecto.Multi.run(:concepts, fn _repo, _ -> {:ok, upsert_entities(merged.concepts, now)} end)
    |> Ecto.Multi.run(:senses, fn _repo, changes ->
      {:ok,
       upsert_senses(merged.senses, changes.lexemes, records, revisions, run_id, now, module)}
    end)
    |> Ecto.Multi.run(:entries, fn _repo, changes ->
      {:ok, upsert_content(merged.entries, changes, records, revisions, run_id, now)}
    end)
    |> Ecto.Multi.run(:concept_relations, fn _repo, changes ->
      {:ok, write_entity_relations(merged, changes, records, run_id, now)}
    end)
    |> Ecto.Multi.run(:relations, fn _repo, changes ->
      {:ok, write_relations(merged, changes, records, run_id, now)}
    end)
    |> Ecto.Multi.run(:links, fn _repo, changes ->
      {:ok, write_links(merged, changes, records, run_id, now)}
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
        {kind,
         Enum.map(Map.get(out, kind, []), &stamp_record(&1, record)) ++ Map.fetch!(acc, kind)}
      end)
    end)
    |> Map.update!(:lexemes, &dedupe_by(&1, :key))
    |> Map.update!(:concepts, &dedupe_by(&1, :key))
    |> Map.update!(:senses, &dedupe_by(&1, :key))
  end

  # Every emitted row remembers which record produced it, so ownership can be
  # recorded without the adapters having to thread a record id through by hand.
  defp stamp_record(row, record) do
    row
    |> Map.put_new(:source_record_id, record.id)
    |> Map.put_new(:source_id, record.source_id)
  end

  # Later rows win, matching "replaced, never edited".
  defp dedupe_by(rows, fun) when is_function(fun, 1),
    do: rows |> Map.new(&{fun.(&1), &1}) |> Map.values()

  defp dedupe_by(rows, key), do: rows |> Map.new(&{Map.fetch!(&1, key), &1}) |> Map.values()

  # The current revision of each record being materialized. Everything derived
  # cites it, which is what makes "what did this claim actually rest on"
  # answerable after the source rewords its entry.
  defp revision_ids(record_ids) do
    from(r in "source_record_revisions",
      where: r.source_record_id in ^record_ids,
      order_by: [asc: r.source_record_id, desc: r.id],
      distinct: r.source_record_id,
      select: {r.source_record_id, r.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── identities ───────────────────────────────────────────────────────────

  # Two steps, because a bulk insert cannot see its own generated keys: find the
  # identities that already exist, mint `objects` rows for the rest, then write
  # the subtype rows against both sets of ids.
  defp mint(kind, existing_keys, wanted_keys, now) do
    # `Enum.uniq/1` is load-bearing, not tidiness: `--` removes one occurrence
    # per element, so a key listed twice stays in `fresh` twice, mints two
    # objects, and `Map.new/1` keeps only the second — leaving the first an
    # object of its kind with no subtype row, refused at COMMIT. Wikipedia lists
    # a key once per record that names it, and several records name one article.
    fresh = Enum.uniq(wanted_keys) -- Map.keys(existing_keys)

    if fresh == [] do
      existing_keys
    else
      rows =
        for _ <- fresh,
            do: %{
              kind: to_string(kind),
              lifecycle_state: "active",
              inserted_at: now,
              updated_at: now
            }

      minted =
        rows
        |> Enum.chunk_every(@chunk)
        |> Enum.flat_map(fn chunk ->
          {_n, returned} = Repo.insert_all("objects", chunk, returning: [:id])
          returned
        end)
        |> Enum.map(& &1.id)

      Map.merge(existing_keys, Map.new(Enum.zip(fresh, minted)))
    end
  end

  # ── lexemes ──────────────────────────────────────────────────────────────

  # Merge, never clobber: a lexeme may already exist because another source
  # introduced it. `metadata` merges, `origin_source_id` keeps whoever got there
  # first. `forms` are rows now and are handled separately, so the JSONB
  # fill-empty rule that made them import-order-sensitive is simply gone.
  defp lexeme_conflict do
    from(l in Lexeme,
      update: [
        set: [
          pronunciations:
            fragment(
              "CASE WHEN ? = '{}'::jsonb THEN EXCLUDED.pronunciations ELSE ? END",
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

  @doc """
  Upserts lexeme identities, returning `%{{lang, lemma, pos} => object_id}`.

  Public because the Wiktionary index pass writes 1.5 M bare rows outside the
  normal materialize path and must mint identities the same way. Two writers
  with two spellings of "create an object and its subtype" is exactly the drift
  the registry exists to prevent.
  """
  def upsert_lexemes([], _now), do: %{}

  def upsert_lexemes(rows, now) do
    keys = Enum.map(rows, & &1.key)

    lexical_keys =
      Enum.map(keys, fn {lang, lemma, pos} -> Lexeme.lexical_key(lang, lemma, pos) end)

    existing =
      from(l in Lexeme,
        where: l.lexical_key in ^lexical_keys,
        select: {l.lexical_key, l.object_id}
      )
      |> Repo.all()
      |> Map.new()
      |> then(fn found ->
        Map.new(keys, fn {lang, lemma, pos} = key ->
          {key, found[Lexeme.lexical_key(lang, lemma, pos)]}
        end)
      end)
      |> Enum.reject(&is_nil(elem(&1, 1)))
      |> Map.new()

    ids = mint(:lexeme, existing, keys, now)

    rows
    |> Enum.map(fn row ->
      {lang, lemma, pos} = row.key

      %{
        object_id: Map.fetch!(ids, row.key),
        language_tag: lang,
        lemma: lemma,
        part_of_speech: pos,
        lexical_key: Lexeme.lexical_key(lang, lemma, pos),
        slug: row[:slug] || Lexeme.slug(lemma),
        pronunciations: wrap_items(row[:pronunciations]),
        etymology: row[:etymology],
        etymology_source_id: row[:etymology_source_id],
        origin_source_id: row[:origin_source_id] || row[:source_id],
        source_ids: [],
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count(Lexeme,
      on_conflict: lexeme_conflict(),
      conflict_target: [:lexical_key]
    )

    ids
  end

  # The list of `%{"ipa" => .., "tags" => [..]}` lives under "items": the column
  # is jsonb and the schema field is a map, and a bare JSON array is legal jsonb
  # but not a legal Ecto `:map`.
  defp wrap_items(nil), do: %{}
  defp wrap_items([]), do: %{}
  defp wrap_items(list) when is_list(list), do: %{"items" => list}
  defp wrap_items(%{} = map), do: map

  # A row per form, each carrying the source revision that attested it — which
  # is what makes "which source says *oysters* is the plural" answerable, and
  # what retires the JSONB array whose fill-empty merge depended on import order.
  @doc "Upserts `lexeme_forms` rows for already-minted lexemes. See `upsert_lexemes/2`."
  def upsert_forms(lexeme_rows, ids, revisions, now) do
    rows =
      for row <- lexeme_rows,
          form <- row[:forms] || [],
          written = form["form"] || form[:form],
          is_binary(written) and written != "" do
        %{
          lexeme_id: Map.fetch!(ids, row.key),
          written_form: written,
          form_kind: form["kind"] || form[:kind] || "inflection",
          language_tag: elem(row.key, 0),
          tags: form["tags"] || form[:tags] || [],
          source_record_revision_id: revisions[row[:source_record_id]],
          inserted_at: now,
          updated_at: now
        }
      end
      |> Enum.uniq_by(&{&1.lexeme_id, &1.written_form, &1.form_kind})

    insert_count(rows, "lexeme_forms",
      on_conflict: {:replace, [:tags, :source_record_revision_id, :updated_at]},
      conflict_target: [:lexeme_id, :written_form, :form_kind]
    )
  end

  # ── entities ─────────────────────────────────────────────────────────────

  # Merge, never clobber — the same contract as `lexeme_conflict/0`, and for the
  # same reason: two sources describe one thing from different sides. Wikipedia
  # knows the title, pageid and thumbnail; Wikidata knows the taxon, the ILI and
  # P18. Whichever lands second must not blank the other's fields.
  #
  # `entity_kind` needs its own clause because it is NOT NULL: an incoming row
  # cannot say "no opinion" with a nil, and `"concept"` *is* the no-opinion
  # value, so it never overwrites a `taxon` already established by Wikidata.
  defp entity_conflict do
    from(e in "entities",
      update: [
        set: [
          entity_kind:
            fragment(
              "CASE WHEN EXCLUDED.entity_kind = 'concept' THEN ? ELSE EXCLUDED.entity_kind END",
              e.entity_kind
            ),
          preferred_label: fragment("COALESCE(?, EXCLUDED.preferred_label)", e.preferred_label),
          description: fragment("COALESCE(?, EXCLUDED.description)", e.description),
          metadata: fragment("? || EXCLUDED.metadata", e.metadata),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp upsert_entities([], _now), do: %{}

  defp upsert_entities(rows, now) do
    qids = Enum.map(rows, & &1.key)

    existing =
      from(x in "external_identifiers",
        where: x.namespace == "wikidata" and x.external_id in ^qids and x.status == "verified",
        select: {x.external_id, x.object_id}
      )
      |> Repo.all()
      |> Map.new()

    ids = mint(:entity, existing, qids, now)

    rows
    |> Enum.map(fn row ->
      %{
        object_id: Map.fetch!(ids, row.key),
        entity_kind: to_string(row[:kind] || :concept),
        preferred_label: row[:label],
        description: row[:description],
        metadata: row[:metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count("entities", on_conflict: entity_conflict(), conflict_target: [:object_id])

    # The QID is evidence about an identity, not the identity. Adding one later
    # leaves the object and every attachment unchanged, which is decision 7.
    for {qid, object_id} <- ids do
      %{
        object_id: object_id,
        namespace: "wikidata",
        external_id: qid,
        status: "verified",
        metadata: %{},
        inserted_at: now,
        updated_at: now
      }
    end
    |> insert_count("external_identifiers",
      on_conflict: {:replace, [:updated_at]},
      conflict_target: {:unsafe_fragment, "(namespace, external_id) WHERE status = 'verified'"}
    )

    ids
  end

  # ── senses ───────────────────────────────────────────────────────────────

  # Identity is matched on **content**, never on the source's own key: a
  # Wiktionary sense key is a position, and deleting one meaning from the middle
  # renumbers everything after it. `Absorb.SenseIdentity` decides whether an
  # incoming sense is one we already hold, a new one, or a case nobody should
  # decide automatically; this writes what it decides.
  defp upsert_senses([], _lexeme_ids, _records, _revisions, _run_id, _now, _module), do: %{}

  defp upsert_senses(rows, lexeme_ids, records, revisions, run_id, now, module) do
    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()
    lexeme_object_ids = rows |> Enum.map(&Map.fetch!(lexeme_ids, &1.lexeme)) |> Enum.uniq()

    held = held_senses(source_ids, lexeme_object_ids)

    {ids, states, cases} = match_senses(rows, lexeme_ids, held, stability(module))
    ids = mint(:sense, ids, Enum.map(rows, & &1.key), now)

    rows
    |> Enum.map(fn row ->
      %{
        object_id: Map.fetch!(ids, row.key),
        lexeme_id: Map.fetch!(lexeme_ids, row.lexeme),
        source_id: row.source_id,
        external_key: row.key,
        identity_state: Map.get(states, row.key, "active"),
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count("senses",
      on_conflict: {:replace, [:lexeme_id, :external_key, :identity_state, :updated_at]},
      conflict_target: [:object_id]
    )

    open_cases(cases, ids, rows, run_id, now)

    write_revisions(
      "sense_revisions",
      :sense_id,
      Enum.map(rows, fn row ->
        {Map.fetch!(ids, row.key),
         %{
           gloss: row[:gloss],
           group_key: row[:group_key],
           position: row[:position] || 0,
           tags: row[:tags] || [],
           topics: row[:topics] || [],
           examples: row[:examples] || %{},
           url: row[:url],
           metadata: row[:metadata] || %{},
           source_record_revision_id: revisions[row[:source_record_id]]
         }}
      end),
      [:gloss, :group_key, :position, :tags, :topics, :examples, :url],
      now
    )

    own_outputs(rows, ids, "sense", run_id, now)

    ids
  end

  # Every sense this source already holds for the words in this batch, with the
  # gloss its current revision carries. One query, not one per incoming sense.
  defp held_senses(source_ids, lexeme_ids) do
    from(s in "senses",
      join: r in "sense_revisions",
      on: r.sense_id == s.object_id and r.is_current,
      where: s.source_id in ^source_ids and s.lexeme_id in ^lexeme_ids,
      where: s.identity_state != "retired",
      select: %{
        object_id: s.object_id,
        lexeme_id: s.lexeme_id,
        external_key: s.external_key,
        identity_state: s.identity_state,
        gloss: r.gloss,
        metadata: r.metadata
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.lexeme_id)
  end

  # A source that keys a sense by where it sat gets content matching; one whose
  # key is a stable identifier gets its key honoured. Assuming `:positional` for
  # a source that never said costs a review case; assuming `:stable` for one
  # that lied would cost a meaning.
  defp stability(module) do
    if function_exported?(module, :sense_key_stability, 0),
      do: module.sense_key_stability(),
      else: :positional
  end

  defp match_senses(rows, lexeme_ids, held, stability) do
    rows
    |> Enum.group_by(&Map.fetch!(lexeme_ids, &1.lexeme))
    |> Enum.reduce({%{}, %{}, []}, fn {lexeme_id, group}, {ids, states, cases} ->
      decisions = SenseIdentity.decide(group, Map.get(held, lexeme_id, []), stability)

      Enum.zip(group, decisions)
      |> Enum.reduce({ids, states, cases}, fn
        {row, {:matched, object_id, _score}}, {ids, states, cases} ->
          {Map.put(ids, row.key, object_id), states, cases}

        {_row, {:new, nil}}, acc ->
          acc

        # No id is reused and no attachment moves. A person decides.
        {row, {:ambiguous, candidates, reason}}, {ids, states, cases} ->
          {ids, Map.put(states, row.key, "needs_review"), [{row, candidates, reason} | cases]}
      end)
    end)
  end

  defp open_cases([], _ids, _rows, _run_id, _now), do: 0

  defp open_cases(cases, ids, _rows, run_id, now) do
    cases
    |> Enum.map(fn {row, candidates, reason} ->
      %{
        source_id: row.source_id,
        source_record_id: row[:source_record_id],
        kind: "sense_identity",
        sense_id: Map.fetch!(ids, row.key),
        payload: %{
          "reason" => to_string(reason),
          "external_key" => to_string(row.key),
          "gloss" => row[:gloss],
          "candidates" =>
            Enum.map(candidates, fn {id, score} -> %{"sense_id" => id, "score" => score} end)
        },
        status: "open",
        opened_run_id: run_id,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count("reconciliation_cases", [])
  end

  # ── content ──────────────────────────────────────────────────────────────

  # An `entries` row becomes a content item, its revision, and the assertions
  # that say what it is about. `materialize/1` is pure and cannot look up a
  # person, so a source names its author by slug and the catalog's seed is what
  # turns that into an entity id.
  defp upsert_content([], _changes, _records, _revisions, _run_id, _now), do: 0

  defp upsert_content(rows, changes, records, revisions, run_id, now) do
    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()
    keys = Enum.map(rows, &content_key/1)

    existing =
      from(o in "source_materialized_outputs",
        where:
          o.source_record_id in ^Enum.map(records, & &1.id) and o.output_role == "content" and
            o.output_key in ^keys,
        select: {o.output_key, o.output_object_id}
      )
      |> Repo.all()
      |> Map.new()

    ids = mint(:content, existing, keys, now)
    authors = authors(rows)

    # Several records can name **one** content item, and since #74 that is the
    # point: Wikipedia's canonical publication identity is what stops one article
    # rendering six times, so six probe records now resolve to one key. Postgres
    # refuses a statement that hits the same conflict key twice, so the item is
    # written once — while `own_outputs/5` below still sees every row, because
    # each of those records really does attest it.
    unique = dedupe_by(rows, &content_key/1)

    unique
    |> Enum.map(fn row ->
      %{
        object_id: Map.fetch!(ids, content_key(row)),
        content_kind: to_string(row[:kind] || :definition),
        original_language: row[:language_tag] || "en",
        source_id: row.source_id,
        metadata: row[:item_metadata] || %{},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> insert_count("content_items",
      on_conflict: {:replace, [:content_kind, :updated_at]},
      conflict_target: [:object_id]
    )

    write_revisions(
      "content_revisions",
      :content_id,
      Enum.map(unique, fn row ->
        {Map.fetch!(ids, content_key(row)),
         %{
           body: row[:body],
           body_format: to_string(row[:body_format] || :text),
           canonical_url: row[:url],
           headword: row[:headword],
           position: row[:position] || 0,
           year: row[:year],
           rights_metadata: row[:rights] || %{},
           metadata: content_metadata(row),
           source_record_revision_id: revisions[row[:source_record_id]]
         }}
      end),
      [:body, :body_format, :canonical_url, :headword, :position, :year],
      now
    )

    own_outputs(rows, ids, "content", run_id, now, &content_key/1)

    claims =
      for row <- rows,
          {predicate, target} <- content_targets(row, changes, authors),
          not is_nil(target) do
        %{
          subject: Map.fetch!(ids, content_key(row)),
          predicate: predicate,
          object: target,
          source_id: row.source_id,
          source_record_id: row[:source_record_id],
          origin_key: "#{content_key(row)}|#{predicate}|#{target}",
          method: "source",
          confidence: nil,
          metadata: %{}
        }
      end

    write_assertions(claims, run_id, now)

    length(rows) + (source_ids != [] && 0)
  end

  # `defines` reaches the word (or the exact meaning, where the source names
  # one); `about` reaches the thing; `authored_by` and `published_in` are the
  # credits that keep a definition distinguishable from an article.
  defp content_targets(row, changes, authors) do
    [
      {"defines", row[:sense] && Map.get(changes.senses, row[:sense])},
      {"defines", is_nil(row[:sense]) && row[:lexeme] && Map.get(changes.lexemes, row[:lexeme])},
      {"about", row[:concept] && Map.get(changes.concepts, row[:concept])},
      {"authored_by", row[:author] && Map.get(authors, row[:author])},
      {"published_in", row[:edition] && Map.get(authors, row[:edition])}
    ]
    |> Enum.reject(fn {_p, target} -> target in [nil, false] end)
  end

  defp content_key(row), do: row[:key] || "#{row[:source_record_id]}##{row[:position] || 0}"

  defp content_metadata(row) do
    (row[:metadata] || %{})
    |> put_if(:pos_marker, row[:pos])
    |> put_if(:thumbnail_url, row[:thumbnail_url])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, to_string(key), value)

  # A source names its author and its edition by slug; the catalog's seed is
  # what turns that into an entity id. A curator account claiming to be a known
  # author is not automatically linked to them — that is `actors`, not this.
  defp authors(rows) do
    slugs =
      rows
      |> Enum.flat_map(&[&1[:author], &1[:edition]])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if slugs == [] do
      %{}
    else
      from(n in "object_names",
        join: e in "entities",
        on: e.object_id == n.object_id,
        where: n.name_kind == "catalog_slug" and n.name in ^slugs,
        select: {n.name, n.object_id}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  # ── revisions ────────────────────────────────────────────────────────────

  # A new revision **only when the text differs**. Re-importing identical input
  # must produce zero new revisions — M2, and the property the Gate 0 spike
  # proved on the real Wiktionary `bank` record. Comparing the fields that carry
  # meaning is what makes that true; comparing a fetch timestamp would make
  # every re-import look like a change, which is the defect the audit found.
  defp write_revisions(_table, _fk, [], _compared, _now), do: 0

  defp write_revisions(table, fk, pairs, compared, now) do
    parent_ids = Enum.map(pairs, &elem(&1, 0))

    current =
      from(r in table,
        where: field(r, ^fk) in ^parent_ids and r.is_current,
        select: {field(r, ^fk), map(r, ^([:id, :revision_number, :lifecycle_state] ++ compared))}
      )
      |> Repo.all()
      |> Map.new()

    changed =
      Enum.reject(pairs, fn {parent_id, attrs} ->
        case current[parent_id] do
          nil ->
            false

          row ->
            # A withdrawn revision is never "unchanged". The source is emitting
            # this again, and every row written here is written as active — so a
            # claim that was retired and is now re-asserted has to come back,
            # rather than staying withdrawn because its wording never moved.
            row.lifecycle_state == "active" and
              Enum.all?(compared, fn f -> same?(Map.get(row, f), Map.get(attrs, f)) end)
        end
      end)

    if changed == [] do
      0
    else
      ids = Enum.map(changed, &elem(&1, 0))

      # Currentness only. What the outgoing revision asserted is history.
      Repo.update_all(
        from(r in table, where: field(r, ^fk) in ^ids and r.is_current),
        set: [is_current: false]
      )

      rows =
        Enum.map(changed, fn {parent_id, attrs} ->
          next = ((current[parent_id] && current[parent_id].revision_number) || 0) + 1

          attrs
          |> Map.merge(%{
            fk => parent_id,
            :revision_number => next,
            :lifecycle_state => "active",
            :is_current => true,
            :inserted_at => now,
            :updated_at => now
          })
        end)

      insert_count(rows, table, [])
    end
  end

  # `[]` and nil are the same absence, and a float read back from Postgres is
  # the same number it was written as. Everything else compares as itself.
  defp same?(nil, []), do: true
  defp same?([], nil), do: true
  defp same?(nil, %{}), do: true
  defp same?(a, b), do: a == b

  # ── assertions ───────────────────────────────────────────────────────────

  @doc """
  Writes claims, upserting on `(source_id, origin_key)`.

  One helper for every claim written anywhere in the absorb — `Absorb.Linker`
  calls it too, so the ladder's rungs and the materializer share one revision
  policy, one idempotency key and one ownership rule rather than three.

  Each claim is a map of `subject`, `predicate` (a key), `object`, `source_id`,
  `origin_key`, and optionally `source_record_id`, `method`, `confidence` and
  `metadata`. A re-import updates the claim it made last time instead of making
  a second one, and writes a new revision **only if something changed**.
  """
  def write_assertions(claims, run_id \\ nil, now \\ nil)

  def write_assertions([], _run_id, _now), do: 0

  def write_assertions(claims, run_id, now) do
    # One transaction, because minting an assertion and writing its first
    # revision are two statements and `assertion_has_one_current_revision` is
    # deferred to **COMMIT**. Inside the materializer's `Ecto.Multi` this joins
    # the enclosing transaction and costs nothing; called from `Absorb.Linker`,
    # which has none of its own, it is the difference between a ladder rung and
    #
    #     assertions 1236827 has 0 current revisions, expected exactly 1
    {:ok, written} =
      Repo.transaction(fn -> do_write_assertions(claims, run_id, now) end, timeout: :infinity)

    written
  end

  defp do_write_assertions(claims, run_id, now) do
    now = now || DateTime.utc_now()
    predicates = predicate_ids(claims)

    # `assertions.origin_key` is **nullable**, and the unique index over
    # `(source_id, origin_key)` is partial — it does not cover NULLs. So a claim
    # without one has no idempotency key: it is not deduped against its siblings
    # and not matched against anything stored, because `{source_id, nil}` is not
    # an identity, it is the absence of one. Treating it as a key collapsed every
    # such claim in a batch into a single assertion.
    {keyed, unkeyed} = Enum.split_with(claims, & &1[:origin_key])

    # Deduped for the *identity*, kept whole for the *ownership*: three records
    # can assert the same edge, and each of them attests it. One assertion, three
    # rows in `source_assertion_outputs` — the same rule content items got when
    # six Wikipedia probes resolved to one article.
    unique = Enum.uniq_by(keyed, &{&1.source_id, &1.origin_key})

    existing =
      from(a in "assertions",
        where: a.origin_key in ^Enum.map(unique, & &1.origin_key),
        select: {{a.source_id, a.origin_key}, a.id}
      )
      |> Repo.all()
      |> Map.new()

    {held, fresh} =
      Enum.split_with(unique, &Map.has_key?(existing, {&1.source_id, &1.origin_key}))

    fresh = fresh ++ unkeyed

    minted =
      fresh
      |> Enum.map(
        &%{
          source_id: &1.source_id,
          origin_key: &1[:origin_key],
          inserted_at: now,
          updated_at: now
        }
      )
      |> Enum.chunk_every(@chunk)
      |> Enum.flat_map(fn chunk ->
        {_n, returned} = Repo.insert_all("assertions", chunk, returning: [:id])
        returned
      end)
      |> Enum.map(& &1.id)

    pairs =
      Enum.map(held, &{&1, Map.fetch!(existing, {&1.source_id, &1.origin_key})}) ++
        Enum.zip(fresh, minted)

    write_revisions(
      "assertion_revisions",
      :assertion_id,
      Enum.map(pairs, fn {claim, assertion_id} ->
        {assertion_id,
         %{
           subject_object_id: claim.subject,
           predicate_id: Map.fetch!(predicates, claim.predicate),
           object_object_id: claim.object,
           method: claim[:method],
           confidence: claim[:confidence],
           metadata: claim[:metadata] || %{}
         }}
      end),
      [:subject_object_id, :predicate_id, :object_object_id, :method, :confidence],
      now
    )

    # Every claim, not every identity: the ones deduped above still name the
    # record that made them.
    by_key = Map.new(pairs, fn {claim, id} -> {{claim.source_id, claim[:origin_key]}, id} end)

    own_assertions(
      Enum.map(keyed, &{&1, Map.fetch!(by_key, {&1.source_id, &1.origin_key})}) ++
        Enum.filter(pairs, fn {claim, _} -> is_nil(claim[:origin_key]) end),
      run_id,
      now
    )

    length(pairs)
  end

  defp predicate_ids(claims) do
    keys = claims |> Enum.map(& &1.predicate) |> Enum.uniq()

    from(p in "predicates", where: p.key in ^keys, select: {p.key, p.id})
    |> Repo.all()
    |> Map.new()
    |> tap(fn found ->
      case keys -- Map.keys(found) do
        [] -> :ok
        missing -> raise "unregistered predicates: #{inspect(missing)} — seed priv/predicates/"
      end
    end)
  end

  # ── relations ────────────────────────────────────────────────────────────

  # An edge whose target word exists becomes an assertion; one whose target is
  # still a string waits in `pending_relations` with its evidence. #69 §4 keeps
  # `to_lemma` forever either way, and inventing a lexeme for a lemma no source
  # listed would be exactly the identity-by-string mistake #74 exists to end.
  defp write_relations(merged, changes, records, run_id, now) do
    # A sense key names a meaning another batch may have introduced — WordNet's
    # graph is closed and its keys are deterministic, so the target is knowable
    # even when it is not in this batch. Resolved against the batch first, then
    # the database, the same way an entity QID is.
    known = Map.merge(resolve_sense_keys(merged.relations, changes, records), changes.senses)
    changes = %{changes | senses: known}

    {resolvable, pending} =
      Enum.split_with(merged.relations, fn r ->
        not is_nil(relation_target(r, changes))
      end)

    claims =
      Enum.map(resolvable, fn r ->
        %{
          subject: relation_subject(r, changes),
          predicate: to_string(r.type),
          object: relation_target(r, changes),
          source_id: r.source_id,
          source_record_id: r[:source_record_id],
          origin_key: relation_key(r),
          method: "source",
          confidence: r[:weight],
          metadata: r[:metadata] || %{}
        }
      end)
      |> Enum.reject(&is_nil(&1.subject))

    written = write_assertions(claims, run_id, now)
    drained = drop_pending(resolvable, records)
    held = write_pending(pending, changes, records, run_id, now)
    restamp_pending(pending, records, run_id, now)

    %{written: written, pending: held, drained: drained, offered: length(merged.relations)}
  end

  # An edge stops being pending the moment it becomes an assertion. WordNet's
  # graph is closed but arrives in batches, so an edge naming a synset a later
  # batch introduces waits here on the first pass and is written on the second —
  # and if the row it waited in were left behind, the lemma-matching resolver
  # would later write the same claim with a *lexeme* target instead of the
  # meaning the source named.
  defp drop_pending([], _records), do: 0

  defp drop_pending(resolved, records) do
    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()
    keys = Enum.map(resolved, &relation_key/1)

    {n, _} =
      from(p in "pending_relations",
        where: p.source_id in ^source_ids and p.origin_key in ^keys
      )
      |> Repo.delete_all()

    n
  end

  # An edge this batch could not resolve is still an edge the source **emits**.
  # It goes to `pending_relations` for the resolver to close by lemma, and if the
  # resolver closed it on an earlier run then an assertion for it already exists
  # — owned by that run, not this one. Without this, `reconcile/2` reads "not
  # stamped by the current run" as "no longer published" and withdraws it: the
  # second Wiktionary sweep retired 110,331 claims that the very next stage
  # re-asserted. Ownership passes between stages of one import; the edge is what
  # is still emitted, so the edge's key is what is re-stamped.
  defp restamp_pending([], _records, _run_id, _now), do: 0

  defp restamp_pending(pending, records, run_id, now) do
    record_ids = Enum.map(records, & &1.id)

    pending
    |> Enum.map(&relation_key/1)
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn keys, acc ->
      {n, _} =
        Repo.update_all(
          from(o in "source_assertion_outputs",
            where: o.source_record_id in ^record_ids and o.output_key in ^keys
          ),
          set: [last_seen_run_id: run_id, retired_at: nil, updated_at: now]
        )

      acc + n
    end)
  end

  defp resolve_sense_keys(relations, changes, records) do
    wanted =
      relations
      |> Enum.flat_map(&[&1[:to_sense], &1[:from_sense]])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Kernel.--(Map.keys(changes.senses))

    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()

    if wanted == [] do
      %{}
    else
      from(s in "senses",
        where: s.source_id in ^source_ids and s.external_key in ^wanted,
        select: {s.external_key, s.object_id}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp relation_subject(r, changes) do
    (r[:from_sense] && Map.get(changes.senses, r[:from_sense])) ||
      (r[:from_lexeme] && Map.get(changes.lexemes, r[:from_lexeme]))
  end

  defp relation_target(r, changes) do
    (r[:to_sense] && Map.get(changes.senses, r[:to_sense])) ||
      (r[:to_lexeme] && Map.get(changes.lexemes, r[:to_lexeme]))
  end

  defp relation_key(r) do
    subject = r[:from_sense] || inspect(r[:from_lexeme])
    target = r[:to_sense] || r[:to_lemma] || inspect(r[:to_lexeme])
    "rel|#{subject}|#{r.type}|#{target}"
  end

  defp write_pending([], _changes, _records, _run_id, _now), do: 0

  defp write_pending(rows, changes, _records, run_id, now) do
    predicates = predicate_ids(Enum.map(rows, &%{predicate: to_string(&1.type)}))

    rows
    |> Enum.map(fn r ->
      %{
        source_id: r.source_id,
        source_record_id: r[:source_record_id],
        subject_object_id: relation_subject(r, changes),
        predicate_id: Map.fetch!(predicates, to_string(r.type)),
        to_lemma: r[:to_lemma] || "",
        to_pos: r[:to_pos],
        origin_key: relation_key(r),
        confidence: r[:weight],
        method: "source",
        # The sense key the source named, kept so the lemma-matching resolver
        # knows to leave this row alone: an edge that names a *meaning* is the
        # materializer's second pass to close, not something to resolve by
        # spelling.
        metadata: pending_metadata(r),
        last_seen_run_id: run_id,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.reject(&(is_nil(&1.subject_object_id) or &1.to_lemma == ""))
    |> Enum.uniq_by(
      &{&1.source_id, &1.source_record_id, &1.subject_object_id, &1.predicate_id, &1.to_lemma,
       &1.to_pos}
    )
    |> insert_count("pending_relations",
      on_conflict: {:replace, [:confidence, :metadata, :last_seen_run_id, :updated_at]},
      conflict_target: [
        :source_id,
        :source_record_id,
        :subject_object_id,
        :predicate_id,
        :to_lemma,
        :to_pos
      ]
    )
  end

  # ── entity relations and links ───────────────────────────────────────────

  # A P171 edge names a parent another record introduces. Resolve against the
  # batch first, then the database; anything still unknown is counted and
  # skipped, never raised on, and the second pass closes it.
  defp pending_metadata(r) do
    case r[:to_sense] do
      nil -> r[:metadata] || %{}
      key -> Map.put(r[:metadata] || %{}, "to_sense", key)
    end
  end

  defp write_entity_relations(merged, changes, _records, run_id, now) do
    wanted =
      merged.concept_relations
      |> Enum.flat_map(&[&1.from_concept, &1.to_concept])
      |> Kernel.++(Enum.map(merged.concepts, & &1[:taxon_concept]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    ids = Map.merge(resolve_qids(wanted, changes.concepts), changes.concepts)

    edges =
      Enum.map(merged.concept_relations, fn r ->
        {r, Map.get(ids, r.from_concept), Map.get(ids, r.to_concept)}
      end)

    taxon_edges =
      for c <- merged.concepts,
          qid = c[:taxon_concept],
          not is_nil(qid) do
        {%{type: "taxon_item", source_id: c.source_id, source_record_id: c[:source_record_id]},
         Map.get(ids, c.key), Map.get(ids, qid)}
      end

    {resolved, skipped} =
      Enum.split_with(edges ++ taxon_edges, fn {_r, from, to} ->
        not is_nil(from) and not is_nil(to)
      end)

    claims =
      Enum.map(resolved, fn {r, from, to} ->
        %{
          subject: from,
          predicate: to_string(r.type),
          object: to,
          source_id: r.source_id,
          source_record_id: r[:source_record_id],
          origin_key: "ent|#{from}|#{r.type}|#{to}",
          method: "source",
          confidence: nil,
          metadata: if(r[:property], do: %{"property" => r.property}, else: %{})
        }
      end)

    written = write_assertions(claims, run_id, now)

    %{
      written: written,
      skipped: length(skipped),
      skipped_parent_taxon:
        Enum.count(skipped, &(elem(&1, 0).type in ["parent_taxon", :parent_taxon])),
      skipped_unchased:
        Enum.count(
          skipped,
          &(elem(&1, 0).type in ["subclass_of", :subclass_of, "instance_of", :instance_of])
        )
    }
  end

  defp resolve_qids([], _batch), do: %{}

  defp resolve_qids(qids, batch) do
    missing = qids -- Map.keys(batch)

    if missing == [] do
      %{}
    else
      from(x in "external_identifiers",
        where: x.namespace == "wikidata" and x.external_id in ^missing and x.status == "verified",
        select: {x.external_id, x.object_id}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  # A sense-backed mapping and a spelling-level guess are different claims and
  # get different predicates. The linker's `title_match` and `disambiguation`
  # rungs produce the second, never the first — that is the audit's finding #7.
  defp write_links(merged, changes, _records, run_id, now) do
    claims =
      for link <- merged.links,
          entity = Map.get(changes.concepts, link[:concept]),
          not is_nil(entity) do
        {subject, predicate} =
          case link[:sense] && Map.get(changes.senses, link[:sense]) do
            nil -> {Map.get(changes.lexemes, link[:lexeme]), "lexeme_entity_candidate"}
            sense_id -> {sense_id, "refers_to"}
          end

        %{
          subject: subject,
          predicate: predicate,
          object: entity,
          source_id: link.source_id,
          source_record_id: link[:source_record_id],
          origin_key:
            "link|#{inspect(link[:lexeme])}|#{link[:sense]}|#{link[:concept]}|#{link[:method]}",
          method: to_string(link[:method] || "source"),
          confidence: link[:confidence],
          metadata: link[:metadata] || %{}
        }
      end
      |> Enum.reject(&is_nil(&1.subject))

    write_assertions(claims, run_id, now)
  end

  # ── output ownership ─────────────────────────────────────────────────────

  # Every derived row is stamped with the run that last emitted it, so
  # `reconcile/2` can retire what a run stopped emitting — and only this
  # source's own output.
  defp own_outputs(rows, ids, role, run_id, now, key_fun \\ & &1.key) do
    rows
    |> Enum.map(fn row ->
      %{
        source_record_id: row[:source_record_id],
        output_role: role,
        output_key: to_string(key_fun.(row)),
        output_object_id: Map.fetch!(ids, key_fun.(row)),
        last_seen_run_id: run_id,
        retired_at: nil,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.reject(&is_nil(&1.source_record_id))
    |> Enum.uniq_by(&{&1.source_record_id, &1.output_role, &1.output_key})
    |> insert_count("source_materialized_outputs",
      on_conflict: {:replace, [:output_object_id, :last_seen_run_id, :retired_at, :updated_at]},
      conflict_target: [:source_record_id, :output_role, :output_key]
    )
  end

  defp own_assertions(pairs, run_id, now) do
    pairs
    |> Enum.map(fn {claim, assertion_id} ->
      %{
        source_record_id: claim[:source_record_id],
        output_key: claim[:origin_key] || "assertion:#{assertion_id}",
        assertion_id: assertion_id,
        last_seen_run_id: run_id,
        retired_at: nil,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.reject(&is_nil(&1.source_record_id))
    |> Enum.uniq_by(&{&1.source_record_id, &1.output_key})
    |> insert_count("source_assertion_outputs",
      on_conflict: {:replace, [:assertion_id, :last_seen_run_id, :retired_at, :updated_at]},
      conflict_target: [:source_record_id, :output_key]
    )
  end

  @doc """
  Retires the outputs a run stopped emitting. The audit's finding #1.

  Refresh was purely additive: a sense a source withdrew stayed in the database
  for ever, and nothing could tell it from one still attested. Everything this
  module writes is stamped with the run that last emitted it, so what a
  completed run did **not** re-stamp is what the source no longer publishes.

  Retired, never deleted — the identity keeps resolving and every attachment to
  it keeps meaning what it meant — and only ever this source's own output, so
  withdrawing a Wiktionary sense cannot remove WordNet's support for the same
  word.

  Scoped to the records the run actually visited: a scoped import that touched
  200 records must not retire the other 340,000.
  """
  def reconcile(run_id, record_ids) when is_integer(run_id) do
    now = DateTime.utc_now()

    stale_outputs =
      from(o in "source_materialized_outputs",
        where: o.source_record_id in ^record_ids,
        where: is_nil(o.retired_at),
        where: is_nil(o.last_seen_run_id) or o.last_seen_run_id != ^run_id,
        select: {o.output_role, o.output_object_id}
      )
      |> Repo.all()

    {senses, content} =
      Enum.split_with(stale_outputs, fn {role, _id} -> role == "sense" end)

    stale_assertions =
      from(o in "source_assertion_outputs",
        where: o.source_record_id in ^record_ids,
        where: is_nil(o.retired_at),
        where: is_nil(o.last_seen_run_id) or o.last_seen_run_id != ^run_id,
        select: o.assertion_id
      )
      |> Repo.all()

    for assertion_id <- stale_assertions do
      Claims.withdraw(assertion_id, reason: "no longer emitted by its source")
    end

    Repo.update_all(
      from(o in "source_materialized_outputs",
        where: o.source_record_id in ^record_ids,
        where: is_nil(o.retired_at),
        where: is_nil(o.last_seen_run_id) or o.last_seen_run_id != ^run_id
      ),
      set: [retired_at: now, updated_at: now]
    )

    Repo.update_all(
      from(o in "source_assertion_outputs",
        where: o.source_record_id in ^record_ids,
        where: is_nil(o.retired_at),
        where: is_nil(o.last_seen_run_id) or o.last_seen_run_id != ^run_id
      ),
      set: [retired_at: now, updated_at: now]
    )

    # Only now, and only what nothing still attests. The outputs are marked
    # retired first so this reads the state after the run rather than before it:
    # several records can own one object — Wikipedia's canonical article is
    # named by every probe that redirects to it — and one of them going quiet is
    # not the source withdrawing the article.
    retire_senses(unattested(Enum.map(senses, &elem(&1, 1))), now)
    retire_content(unattested(Enum.map(content, &elem(&1, 1))), now)

    %{
      senses: length(senses),
      content: length(content),
      assertions: length(stale_assertions)
    }
  end

  # The objects among these that no unretired output still points at.
  defp unattested([]), do: []

  defp unattested(object_ids) do
    still_owned =
      from(o in "source_materialized_outputs",
        where: o.output_object_id in ^object_ids and is_nil(o.retired_at),
        select: o.output_object_id,
        distinct: true
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(object_ids, &MapSet.member?(still_owned, &1))
  end

  defp retire_senses([], _now), do: 0

  defp retire_senses(ids, now) do
    Repo.update_all(
      from(s in "senses", where: s.object_id in ^ids),
      set: [identity_state: "retired", updated_at: now]
    )

    Repo.update_all(
      from(r in "sense_revisions", where: r.sense_id in ^ids and r.is_current),
      set: [lifecycle_state: "withdrawn", updated_at: now]
    )
  end

  defp retire_content([], _now), do: 0

  defp retire_content(ids, now) do
    Repo.update_all(
      from(r in "content_revisions", where: r.content_id in ^ids and r.is_current),
      set: [lifecycle_state: "withdrawn", updated_at: now]
    )
  end

  # ── stamps ───────────────────────────────────────────────────────────────

  defp stamp_source_ids(changes, records, now) do
    ids = Map.values(changes.lexemes)
    source_ids = records |> Enum.map(& &1.source_id) |> Enum.uniq()

    if ids == [] or source_ids == [] do
      0
    else
      {count, _} =
        Repo.update_all(
          from(l in Lexeme,
            where: l.object_id in ^ids and not fragment("? @> ?", l.source_ids, ^source_ids),
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
  # mixes words that gained senses with words that only had their forms touched,
  # and marking the latter enriched would quietly inflate A3 and put empty cards
  # on the word page.
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
          from(l in Lexeme, where: l.object_id in ^ids and is_nil(l.enriched_at)),
          set: [enriched_at: now, updated_at: now]
        )

      count
    end
  end

  # ── insert helpers ───────────────────────────────────────────────────────

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
      forms: changes.forms,
      concepts: map_size(changes.concepts),
      senses: map_size(changes.senses),
      entries: changes.entries,
      relations: changes.relations.written,
      relations_pending: changes.relations.pending,
      relations_drained: changes.relations.drained,
      links: changes.links,
      concept_relations: changes.concept_relations.written,
      concept_relations_skipped: changes.concept_relations.skipped,
      concept_relations_skipped_parent_taxon: changes.concept_relations.skipped_parent_taxon,
      concept_relations_skipped_unchased: changes.concept_relations.skipped_unchased,
      relations_offered: changes.relations.offered,
      concept_relations_offered: length(merged.concept_relations)
    }
  end
end
