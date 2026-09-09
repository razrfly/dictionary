defmodule DevilsDictionary.Health.Parity do
  @moduledoc """
  **M1** — does the database still *mean* what the raw records say it means?

  Parity is the check that keeps "raw first" honest. Every derived row is a pure
  function of a source record's payload, so re-running that function and diffing
  the result against the database will find anything dropped by a half-finished
  run, a schema change, or a source module that quietly stopped emitting a
  field.

  It runs `materialize/1` and **writes nothing** — no network either, which is
  what makes it usable as the offline check in `mix dd.materialize --dry-run`.

  ## What changed, and why it had to

  The MVP-0 version compared by **natural key presence**: for each emitted
  sense, does a row with that `(source_id, external_id)` exist? The 7 September
  audit's probe showed what that misses — replacing **every gloss in the
  database with the string `CORRUPTED`** still returned zero gaps, because every
  key was still present. A check that a corrupted corpus passes is not a check.

  So M1 now compares four things, and the first is the one that matters:

    * **content** — the emitted gloss, group key, position, tags and url against
      the sense's *current revision*; the emitted body, headword, year and
      format against the content item's. This is what fails on `CORRUPTED`.
    * **presence** — an output the record implies that the database does not
      hold at all.
    * **endpoints** — an assertion whose current revision points somewhere other
      than where `materialize/1` says it should.
    * **stale outputs** — a row this source still owns for this record that the
      record no longer implies. Additive refresh was the audit's finding #1, and
      this is the reading that catches it: `reconcile/2` should have retired it.

  Identity is resolved through `source_materialized_outputs` /
  `source_assertion_outputs` rather than by re-deriving a natural key, because
  in this model a source's own key is provenance and not identity — a
  Wiktionary sense key is a position, and the whole point of #74 is that
  position is not what a meaning is.

  A record is also a gap when it has never been materialized, or was
  materialized before its current payload was fetched.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb
  alias DevilsDictionary.Absorb.{Batch, Materializer}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @page 200
  @examples 20

  @doc """
  Checks one source. Options: `:limit` to stop after N records (a smoke test),
  `:batch_size`.

  Returns totals plus up to twenty example gaps, each `{external_id, detail}`.
  """
  def check(source_slug, opts \\ []) do
    source = Sources.get_source_by_slug!(source_slug)
    module = Absorb.source_module!(source_slug)

    zero = %{
      source: source_slug,
      records: 0,
      stale: 0,
      missing_senses: 0,
      missing_relations: 0,
      missing_entries: 0,
      missing_concepts: 0,
      missing_concept_relations: 0,
      mismatched: 0,
      wrong_endpoints: 0,
      unretired: 0,
      gaps: 0,
      examples: []
    }

    source
    |> Batch.stream(only_stale: false, batch_size: opts[:batch_size] || @page)
    |> then(fn stream ->
      case opts[:limit] do
        nil -> stream
        n -> Stream.take(stream, ceil(n / (opts[:batch_size] || @page)))
      end
    end)
    |> Enum.reduce(zero, fn page, acc -> check_page(page, module, acc) end)
  end

  defp check_page(records, module, acc) do
    outs = Enum.map(records, fn record -> {record, materialize!(module, record)} end)
    record_ids = Enum.map(records, & &1.id)

    owned = owned_outputs(record_ids)
    owned_assertions = owned_assertions(record_ids)

    sense_content = sense_content(owned, "sense")
    item_content = content_content(owned, "content")
    endpoints = assertion_endpoints(owned_assertions)
    entities = known_entities(outs)
    known = {known_lexemes(outs), known_senses(outs)}

    Enum.reduce(outs, acc, fn {record, out}, acc ->
      keys = Map.get(owned, record.id, %{})
      assertion_keys = Map.get(owned_assertions, record.id, %{})

      senses = check_senses(out, keys, sense_content)
      entries = check_entries(out, keys, item_content)
      concepts = check_concepts(out, entities)
      relations = check_relations(out, assertion_keys, endpoints, known)
      concept_relations = check_entity_relations(out, assertion_keys, entities)

      unretired = unretired(out, keys, assertion_keys)
      stale? = stale?(record)

      mismatched = senses.mismatched + entries.mismatched

      missing = [
        senses.missing,
        relations.missing,
        entries.missing,
        concepts.missing,
        concept_relations.missing
      ]

      gap? =
        stale? or mismatched > 0 or relations.wrong > 0 or unretired > 0 or
          Enum.any?(missing, &(&1 != []))

      acc
      |> Map.update!(:records, &(&1 + 1))
      |> Map.update!(:stale, &(&1 + if(stale?, do: 1, else: 0)))
      |> Map.update!(:missing_senses, &(&1 + length(senses.missing)))
      |> Map.update!(:missing_relations, &(&1 + length(relations.missing)))
      |> Map.update!(:missing_entries, &(&1 + length(entries.missing)))
      |> Map.update!(:missing_concepts, &(&1 + length(concepts.missing)))
      |> Map.update!(:missing_concept_relations, &(&1 + length(concept_relations.missing)))
      |> Map.update!(:mismatched, &(&1 + mismatched))
      |> Map.update!(:wrong_endpoints, &(&1 + relations.wrong))
      |> Map.update!(:unretired, &(&1 + unretired))
      |> Map.update!(:gaps, &(&1 + if(gap?, do: 1, else: 0)))
      |> add_example(gap?, record, %{
        stale: stale?,
        senses: senses,
        entries: entries,
        concepts: concepts,
        relations: relations,
        concept_relations: concept_relations,
        unretired: unretired
      })
    end)
  end

  # ── what the database owns for these records ─────────────────────────────

  defp owned_outputs(record_ids) do
    from(o in "source_materialized_outputs",
      where: o.source_record_id in ^record_ids and is_nil(o.retired_at),
      select: {o.source_record_id, o.output_role, o.output_key, o.output_object_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_r, role, key, id} -> {{role, key}, id} end)
    |> Map.new(fn {record_id, pairs} -> {record_id, Map.new(pairs)} end)
  end

  defp owned_assertions(record_ids) do
    from(o in "source_assertion_outputs",
      where: o.source_record_id in ^record_ids and is_nil(o.retired_at),
      select: {o.source_record_id, o.output_key, o.assertion_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_r, key, id} -> {key, id} end)
    |> Map.new(fn {record_id, pairs} -> {record_id, Map.new(pairs)} end)
  end

  # The current revision of every owned sense, as the fields `materialize/1`
  # emits. This is the half the corruption probe has to fail on.
  defp sense_content(owned, role) do
    ids = object_ids(owned, role)

    if ids == [] do
      %{}
    else
      from(r in "sense_revisions",
        where: r.sense_id in ^ids and r.is_current,
        select:
          {r.sense_id,
           %{
             gloss: r.gloss,
             group_key: r.group_key,
             position: r.position,
             tags: r.tags,
             url: r.url
           }}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp content_content(owned, role) do
    ids = object_ids(owned, role)

    if ids == [] do
      %{}
    else
      from(r in "content_revisions",
        where: r.content_id in ^ids and r.is_current,
        select:
          {r.content_id,
           %{
             body: r.body,
             headword: r.headword,
             year: r.year,
             position: r.position,
             body_format: r.body_format
           }}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp object_ids(owned, role) do
    for {_record_id, keys} <- owned,
        {{r, _key}, id} <- keys,
        r == role,
        do: id
  end

  defp assertion_endpoints(owned) do
    ids = for {_record_id, keys} <- owned, {_key, id} <- keys, do: id

    if ids == [] do
      %{}
    else
      from(r in "assertion_revisions",
        join: p in "predicates",
        on: p.id == r.predicate_id,
        where: r.assertion_id in ^ids and r.is_current,
        select:
          {r.assertion_id,
           %{
             subject: r.subject_object_id,
             object: r.object_object_id,
             predicate: p.key,
             lifecycle: r.lifecycle_state
           }}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  # ── the five comparisons ─────────────────────────────────────────────────

  defp check_senses(out, keys, content) do
    Enum.reduce(out.senses, %{missing: [], mismatched: 0, wrong: []}, fn sense, acc ->
      case Map.get(keys, {"sense", to_string(sense.key)}) do
        nil ->
          %{acc | missing: [sense.key | acc.missing]}

        object_id ->
          expected = %{
            gloss: sense[:gloss],
            group_key: sense[:group_key],
            position: sense[:position] || 0,
            tags: sense[:tags] || [],
            url: sense[:url]
          }

          if matches?(Map.get(content, object_id), expected) do
            acc
          else
            %{acc | mismatched: acc.mismatched + 1, wrong: [sense.key | acc.wrong]}
          end
      end
    end)
  end

  defp check_entries(out, keys, content) do
    Enum.reduce(out.entries, %{missing: [], mismatched: 0, wrong: []}, fn entry, acc ->
      key = content_key(entry)

      case Map.get(keys, {"content", key}) do
        nil ->
          %{acc | missing: [key | acc.missing]}

        object_id ->
          expected = %{
            body: entry[:body],
            headword: entry[:headword],
            year: entry[:year],
            position: entry[:position] || 0,
            body_format: to_string(entry[:body_format] || :text)
          }

          if matches?(Map.get(content, object_id), expected) do
            acc
          else
            %{acc | mismatched: acc.mismatched + 1, wrong: [key | acc.wrong]}
          end
      end
    end)
  end

  defp check_concepts(out, entities) do
    missing =
      out.concepts
      |> Enum.map(& &1.key)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(entities, &1))

    %{missing: missing}
  end

  # A relation is present when its assertion exists and points where it should.
  # An edge whose target word we do not hold is legitimately absent — it is in
  # `pending_relations`, which is a different question and R2's, not M1's.
  defp check_relations(out, assertion_keys, endpoints, known) do
    Enum.reduce(out.relations, %{missing: [], wrong: 0}, fn relation, acc ->
      key = relation_key(relation)
      resolvable? = resolvable?(relation, known)

      case {Map.get(assertion_keys, key), resolvable?} do
        {nil, false} -> acc
        {nil, true} -> %{acc | missing: [key | acc.missing]}
        {assertion_id, _} -> check_endpoint(acc, endpoints[assertion_id], relation)
      end
    end)
  end

  defp check_endpoint(acc, nil, _relation), do: %{acc | wrong: acc.wrong + 1}

  defp check_endpoint(acc, actual, relation) do
    if actual.predicate == to_string(relation.type), do: acc, else: %{acc | wrong: acc.wrong + 1}
  end

  defp check_entity_relations(out, assertion_keys, entities) do
    missing =
      out.concept_relations
      |> Enum.flat_map(fn relation ->
        with from_id when not is_nil(from_id) <- Map.get(entities, relation.from_concept),
             to_id when not is_nil(to_id) <- Map.get(entities, relation.to_concept) do
          key = "ent|#{from_id}|#{relation.type}|#{to_id}"
          if Map.has_key?(assertion_keys, key), do: [], else: [key]
        else
          _ -> []
        end
      end)

    %{missing: missing}
  end

  # The audit's finding #1, read from the other side: a row this source still
  # owns for this record that the record no longer implies. A completed run
  # should have retired it.
  defp unretired(out, keys, assertion_keys) do
    implied =
      MapSet.new(
        Enum.map(out.senses, &{"sense", to_string(&1.key)}) ++
          Enum.map(out.entries, &{"content", content_key(&1)})
      )

    implied_assertions = MapSet.new(Enum.map(out.relations, &relation_key/1))

    stale_outputs = Enum.reject(Map.keys(keys), &MapSet.member?(implied, &1))

    stale_assertions =
      assertion_keys
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "rel|"))
      |> Enum.reject(&MapSet.member?(implied_assertions, &1))

    length(stale_outputs) + length(stale_assertions)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # nil and "" are the same absence, nil and [] are the same emptiness, and a
  # value the database rounded is still the value. Everything else is compared
  # as itself — which is the whole point: `CORRUPTED` is not the gloss.
  defp matches?(nil, _expected), do: false

  defp matches?(actual, expected) do
    Enum.all?(expected, fn {field, want} -> same?(Map.get(actual, field), want) end)
  end

  defp same?(nil, nil), do: true
  defp same?(nil, ""), do: true
  defp same?("", nil), do: true
  defp same?(nil, []), do: true
  defp same?([], nil), do: true
  defp same?(a, b) when is_atom(b), do: a == to_string(b)
  defp same?(a, b), do: a == b

  # An edge is only *expected* to be an assertion when its target exists. A
  # WordNet edge names a synset a later record introduces, and a Wiktionary edge
  # names a lemma that may not be in the index at all; both are legitimately in
  # `pending_relations` until then, which is R2's question and not M1's.
  defp resolvable?(relation, {lexemes, senses}) do
    cond do
      relation[:to_sense] -> MapSet.member?(senses, relation[:to_sense])
      relation[:to_lemma] -> MapSet.member?(lexemes, String.downcase(relation.to_lemma))
      true -> false
    end
  end

  defp known_senses(outs) do
    keys =
      outs
      |> Enum.flat_map(fn {_r, out} ->
        out.relations |> Enum.map(& &1[:to_sense]) |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq()

    if keys == [] do
      MapSet.new()
    else
      from(s in "senses", where: s.external_key in ^keys, select: s.external_key)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp known_lexemes(outs) do
    lemmas =
      outs
      |> Enum.flat_map(fn {_r, out} ->
        out.relations |> Enum.map(& &1[:to_lemma]) |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq()

    if lemmas == [] do
      MapSet.new()
    else
      downcased = Enum.map(lemmas, &String.downcase/1)

      from(l in "lexemes",
        where: fragment("lower(?)", l.lemma) in ^downcased,
        select: fragment("lower(?)", l.lemma)
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp known_entities(outs) do
    qids =
      outs
      |> Enum.flat_map(fn {_r, out} ->
        Enum.map(out.concepts, & &1.key) ++
          Enum.flat_map(out.concept_relations, &[&1.from_concept, &1.to_concept])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if qids == [] do
      %{}
    else
      from(x in "external_identifiers",
        where: x.namespace == "wikidata" and x.external_id in ^qids and x.status == "verified",
        select: {x.external_id, x.object_id}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp content_key(entry),
    do: to_string(entry[:key] || "#{entry[:source_record_id]}##{entry[:position] || 0}")

  defp relation_key(relation) do
    subject = relation[:from_sense] || inspect(relation[:from_lexeme])
    target = relation[:to_sense] || relation[:to_lemma] || inspect(relation[:to_lexeme])
    "rel|#{subject}|#{relation.type}|#{target}"
  end

  # `<` on two DateTime structs is Erlang term order — which compares the `day`
  # field before `month` before `year`, alphabetically — so it answers almost at
  # random. This is the same predicate `Absorb.Batch` expresses in SQL, and the
  # two have to agree.
  defp stale?(%{materialized_at: nil}), do: true

  defp stale?(%{materialized_at: materialized, fetched_at: fetched}),
    do: DateTime.compare(materialized, fetched) == :lt

  defp materialize!(module, record) do
    case module.materialize(record) do
      {:ok, out} ->
        Materializer.empty_output()
        |> Map.merge(out)
        |> Map.update!(:senses, &stamp(&1, record))
        |> Map.update!(:entries, &stamp(&1, record))
        |> Map.update!(:relations, &stamp(&1, record))

      {:error, reason} ->
        raise "materialize failed for #{record.external_id}: #{inspect(reason)}"
    end
  end

  defp stamp(rows, record), do: Enum.map(rows, &Map.put_new(&1, :source_record_id, record.id))

  defp add_example(acc, false, _record, _detail), do: acc

  defp add_example(%{examples: examples} = acc, true, _record, _detail)
       when length(examples) >= @examples,
       do: acc

  defp add_example(acc, true, record, d) do
    detail =
      %{}
      |> put_unless_empty(:stale, d.stale && true)
      |> put_unless_empty(:missing_senses, Enum.take(d.senses.missing, 3))
      |> put_unless_empty(:corrupted_senses, Enum.take(d.senses.wrong, 3))
      |> put_unless_empty(:missing_entries, Enum.take(d.entries.missing, 3))
      |> put_unless_empty(:corrupted_entries, Enum.take(d.entries.wrong, 3))
      |> put_unless_empty(:missing_concepts, Enum.take(d.concepts.missing, 3))
      |> put_unless_empty(:missing_relations, length(d.relations.missing))
      |> put_unless_empty(:wrong_endpoints, d.relations.wrong)
      |> put_unless_empty(:missing_concept_relations, length(d.concept_relations.missing))
      |> put_unless_empty(:unretired, d.unretired)

    %{acc | examples: acc.examples ++ [{record.external_id, detail}]}
  end

  defp put_unless_empty(map, _key, value) when value in [nil, false, [], 0], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
