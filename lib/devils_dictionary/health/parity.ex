defmodule DevilsDictionary.Health.Parity do
  @moduledoc """
  **M1** — does the database still hold everything `materialize/1` says the raw
  records imply?

  Parity is the check that keeps "raw first" honest. Every derived row is a pure
  function of a `source_records.raw` payload, so re-running that function and
  diffing the result against the database will find anything that was dropped by
  a half-finished run, a schema change, or a source module that quietly stopped
  emitting a field.

  It runs `materialize/1` and **writes nothing** — no network either, which is
  what makes it usable as the offline check in `mix dd.materialize --dry-run`.

  The comparison is by natural key, not by count, because counts hide swaps:

    * senses — `(source_id, external_id)`
    * relations — `(from_lexeme_id, from_sense_id, to_lemma, type)`
    * entries — `(source_record_id, position)`
    * concepts — `qid`
    * concept relations — `(from_concept_id, to_concept_id, type)`, and only
      once both ends resolve: a P171 edge whose parent has not been fetched is
      legitimately absent, and `Materializer` skips it for the same reason.

  Without the last two, `--dry-run` on Wikidata would compare nothing at all and
  report a clean bill by construction — that source emits no senses, relations
  or entries.

  A record is also a gap when it has never been materialized, or was
  materialized before its current payload was fetched.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb
  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptRelation}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @page 200

  @doc """
  Checks one source. Options: `:limit` to stop after N records (a smoke test),
  `:batch_size`.

  Returns totals plus up to 20 example gaps, each `{external_id, kind, detail}`.
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
    |> Enum.reduce(zero, fn page, acc -> check_page(page, module, source, acc) end)
  end

  defp check_page(records, module, source, acc) do
    outs = Enum.map(records, fn record -> {record, materialize!(module, record)} end)

    lexeme_ids = lexeme_ids(outs)
    sense_ids = sense_ids(outs, source)
    actual_relations = actual_relations(source, lexeme_ids)
    actual_entries = actual_entries(records)
    concept_ids = concept_ids(outs)
    actual_concept_relations = actual_concept_relations(source, concept_ids)

    Enum.reduce(outs, acc, fn {record, out}, acc ->
      missing_senses =
        out.senses
        |> Enum.map(& &1.key)
        |> Enum.reject(&Map.has_key?(sense_ids, &1))

      missing_relations =
        out.relations
        |> Enum.map(&relation_key(&1, lexeme_ids, sense_ids))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(actual_relations, &1))

      missing_entries =
        out.entries
        |> Enum.map(&{record.id, &1[:position] || 0})
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(actual_entries, &1))

      missing_concepts =
        out.concepts
        |> Enum.map(& &1.qid)
        |> Enum.uniq()
        |> Enum.reject(&Map.has_key?(concept_ids, &1))

      # Only an edge whose two ends both exist can be missing. One that names a
      # parent nobody has fetched is skipped here exactly as `Materializer`
      # skips it, or every leaf taxon would read as a gap.
      missing_concept_relations =
        out.concept_relations
        |> Enum.flat_map(fn relation ->
          with from_id when not is_nil(from_id) <- Map.get(concept_ids, relation.from_concept),
               to_id when not is_nil(to_id) <- Map.get(concept_ids, relation.to_concept) do
            [{from_id, to_id, relation.type}]
          else
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(actual_concept_relations, &1))

      stale? = stale?(record)

      missing = [
        missing_senses,
        missing_relations,
        missing_entries,
        missing_concepts,
        missing_concept_relations
      ]

      gap? = stale? or Enum.any?(missing, &(&1 != []))

      acc
      |> Map.update!(:records, &(&1 + 1))
      |> Map.update!(:stale, &(&1 + if(stale?, do: 1, else: 0)))
      |> Map.update!(:missing_senses, &(&1 + length(missing_senses)))
      |> Map.update!(:missing_relations, &(&1 + length(missing_relations)))
      |> Map.update!(:missing_entries, &(&1 + length(missing_entries)))
      |> Map.update!(:missing_concepts, &(&1 + length(missing_concepts)))
      |> Map.update!(:missing_concept_relations, &(&1 + length(missing_concept_relations)))
      |> Map.update!(:gaps, &(&1 + if(gap?, do: 1, else: 0)))
      |> add_example(gap?, record, stale?, missing)
    end)
  end

  # Every qid the page mentions, on either end of an edge, resolved once.
  defp concept_ids(outs) do
    qids =
      outs
      |> Enum.flat_map(fn {_r, out} ->
        Enum.map(out.concepts, & &1.qid) ++
          Enum.flat_map(out.concept_relations, &[&1.from_concept, &1.to_concept])
      end)
      |> Enum.uniq()

    if qids == [] do
      %{}
    else
      from(c in Concept, where: c.qid in ^qids, select: {c.qid, c.id})
      |> Repo.all()
      |> Map.new()
    end
  end

  defp actual_concept_relations(_source, concept_ids) when map_size(concept_ids) == 0,
    do: MapSet.new()

  defp actual_concept_relations(source, concept_ids) do
    ids = Map.values(concept_ids)

    from(r in ConceptRelation,
      where: r.source_id == ^source.id and r.from_concept_id in ^ids,
      select: {r.from_concept_id, r.to_concept_id, r.type}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # `<` on two DateTime structs is Erlang term order — which compares the
  # `day` field before `month` before `year`, alphabetically — so it answers
  # almost at random. This is the same predicate `Absorb.Batch` expresses in
  # SQL, and the two have to agree.
  defp stale?(%{materialized_at: nil}), do: true

  defp stale?(%{materialized_at: materialized, fetched_at: fetched}),
    do: DateTime.compare(materialized, fetched) == :lt

  # A source emits only the kinds it has — Wikidata returns concepts and nothing
  # else, an absent marker returns an empty map — so the shape is filled in here
  # exactly as `Materializer.collect/2` fills it.
  @empty %{
    lexemes: [],
    senses: [],
    entries: [],
    relations: [],
    concepts: [],
    links: [],
    concept_relations: []
  }

  defp materialize!(module, record) do
    case module.materialize(record) do
      {:ok, out} -> Map.merge(@empty, out)
      {:error, reason} -> raise "materialize failed for #{record.external_id}: #{inspect(reason)}"
    end
  end

  # One lookup per page for the (lang, lemma, pos) triples the page mentions.
  # Anything absent stays absent from the map, which makes its relations count
  # as missing — correctly, since a relation cannot exist without its lexeme.
  defp lexeme_ids(outs) do
    keys =
      outs
      |> Enum.flat_map(fn {_r, out} -> Enum.map(out.lexemes, & &1.key) end)
      |> Enum.uniq()

    lemmas = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(keys)

    from(l in Lexeme, where: l.lemma in ^lemmas, select: {l.lang, l.lemma, l.pos, l.id})
    |> Repo.all()
    |> Enum.filter(fn {lang, lemma, pos, _id} -> MapSet.member?(wanted, {lang, lemma, pos}) end)
    |> Map.new(fn {lang, lemma, pos, id} -> {{lang, lemma, pos}, id} end)
  end

  defp sense_ids(outs, source) do
    keys =
      outs
      |> Enum.flat_map(fn {_r, out} -> Enum.map(out.senses, & &1.key) end)
      |> Enum.uniq()

    from(s in Sense,
      where: s.source_id == ^source.id and s.external_id in ^keys,
      select: {s.external_id, s.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp actual_relations(_source, lexeme_ids) when map_size(lexeme_ids) == 0, do: MapSet.new()

  defp actual_relations(source, lexeme_ids) do
    ids = Map.values(lexeme_ids)

    from(r in LexicalRelation,
      where: r.source_id == ^source.id and r.from_lexeme_id in ^ids,
      select: {r.from_lexeme_id, r.from_sense_id, r.to_lemma, r.type}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp actual_entries(records) do
    ids = Enum.map(records, & &1.id)

    from(e in Entry,
      where: e.source_record_id in ^ids,
      select: {e.source_record_id, e.position}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp relation_key(relation, lexeme_ids, sense_ids) do
    {
      Map.get(lexeme_ids, relation.from_lexeme),
      relation[:from_sense] && Map.get(sense_ids, relation.from_sense),
      relation.to_lemma,
      relation.type
    }
  end

  defp add_example(acc, false, _record, _stale, _missing), do: acc

  defp add_example(%{examples: examples} = acc, true, _record, _stale, _missing)
       when length(examples) >= 20,
       do: acc

  defp add_example(acc, true, record, stale?, missing) do
    [senses, relations, entries, concepts, concept_relations] = missing

    detail =
      %{}
      |> put_unless_empty(:stale, stale? && true)
      |> put_unless_empty(:senses, Enum.take(senses, 3))
      |> put_unless_empty(:relations, length(relations))
      |> put_unless_empty(:entries, length(entries))
      |> put_unless_empty(:concepts, Enum.take(concepts, 3))
      |> put_unless_empty(:concept_relations, length(concept_relations))

    %{acc | examples: acc.examples ++ [{record.external_id, detail}]}
  end

  defp put_unless_empty(map, _key, value) when value in [nil, false, [], 0], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
