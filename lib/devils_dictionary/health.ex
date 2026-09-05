defmodule DevilsDictionary.Health do
  @moduledoc """
  Numbers. Coverage per source within a scope, raw-vs-derived parity, unresolved
  relation targets, link histogram and conflicts, and the MVP-0 scorecard rows
  as functions (`mix dd.score`). Spec: issue #69 §7.

  S1 implements the rows S1 is judged on — A5, A9, M1, M4, R2. S3 adds the rest
  and `mix dd.score` on top of them, rather than re-deriving numbers the tasks
  have already printed once.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Health.Parity
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{ImportRun, Source, SourceRecord}

  @doc """
  **A5** — how much of a scope a source actually covers.

  A scope lexeme counts as covered when the source attests it (`source_ids`),
  which for a dump source means a record was written for its lemma. The misses
  are bucketed, because for Animals they are not random: WordNet contributes
  thousands of Linnaean binomials, and Wiktionary files those under Translingual
  rather than English, so the English index can never hold them.
  """
  def coverage(scope_slug, source_slug) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)
    source = Sources.get_source_by_slug!(source_slug)

    scoped = from sl in ScopeLexeme, join: l in Lexeme, on: l.id == sl.lexeme_id
    scoped = from [sl, _l] in scoped, where: sl.scope_id == ^scope.id

    total = Repo.aggregate(scoped, :count)

    covered =
      scoped
      |> where([_sl, l], fragment("? = ANY(?)", ^source.id, l.source_ids))
      |> Repo.aggregate(:count)

    misses =
      scoped
      |> where([_sl, l], not fragment("? = ANY(?)", ^source.id, l.source_ids))
      |> select([_sl, l], l.lemma)
      |> Repo.all()

    %{
      scope: scope_slug,
      source: source_slug,
      total: total,
      covered: covered,
      pct: pct(covered, total),
      missing: length(misses),
      missing_by_kind: Enum.frequencies_by(misses, &lemma_kind/1),
      sample: misses |> Enum.take(20)
    }
  end

  # A binomial is two capitalised-genus-plus-lowercase-species words: the
  # Linnaean convention, and the shape Wiktionary keeps out of its English
  # section.
  defp lemma_kind(lemma) do
    cond do
      Regex.match?(~r/^[A-Z][a-z]+ [a-z]+$/, lemma) -> "binomial"
      String.contains?(lemma, " ") -> "multiword"
      true -> "single_word"
    end
  end

  @doc """
  **A9** — every sense and entry can be clicked back to where it came from.

  Three acceptable answers, in the order the UI uses them: the row's own url,
  the url of the record it was materialized from, or the source's
  `url_template`. Must be 100 %.
  """
  def links_back do
    templated =
      from(s in Source, where: not is_nil(s.url_template), select: s.id)
      |> Repo.all()

    %{
      senses: linkable(Sense, templated),
      entries: linkable(Entry, templated)
    }
    |> then(fn parts ->
      total = parts.senses.total + parts.entries.total
      linked = parts.senses.linked + parts.entries.linked

      Map.merge(parts, %{total: total, linked: linked, pct: pct(linked, total)})
    end)
  end

  defp linkable(schema, templated_source_ids) do
    query =
      from row in schema,
        left_join: r in SourceRecord,
        on: r.id == row.source_record_id

    total = Repo.aggregate(from(row in schema), :count)

    linked =
      query
      |> where(
        [row, r],
        not is_nil(row.url) or not is_nil(r.url) or row.source_id in ^templated_source_ids
      )
      |> Repo.aggregate(:count)

    %{total: total, linked: linked, pct: pct(linked, total)}
  end

  @doc """
  **R2** — how many of a source's relation targets we managed to place.
  """
  def resolution(source_slug) do
    source = Sources.get_source_by_slug!(source_slug)
    by_type = Resolver.by_type(source.id)

    total = by_type |> Map.values() |> Enum.map(& &1.total) |> Enum.sum()
    resolved = by_type |> Map.values() |> Enum.map(& &1.resolved) |> Enum.sum()

    %{
      source: source_slug,
      total: total,
      resolved: resolved,
      pct: pct(resolved, total),
      by_type: by_type,
      top_unresolved: Resolver.unresolved_lemmas(source.id)
    }
  end

  @doc """
  **M1** — raw-vs-derived parity. Delegates to `Health.Parity`, which is what
  `mix dd.materialize --dry-run` runs.
  """
  defdelegate parity(source_slug, opts \\ []), to: Parity, as: :check

  @doc """
  **M4** — what `trim/1` saved on the records actually stored, read back from
  the `import_runs` row the scoped absorb wrote.

  The untrimmed payload is deliberately never stored, so this number can only
  be taken in flight; reading it back here keeps one figure rather than two.
  """
  def trim_saving(source_slug \\ "wiktionary") do
    source = Sources.get_source_by_slug!(source_slug)

    run =
      Repo.one(
        from r in ImportRun,
          where: r.source_id == ^source.id and r.status == :done,
          where: fragment("? \\? 'trim_saving_pct'", r.stats),
          order_by: [desc: r.started_at],
          limit: 1
      )

    case run do
      nil ->
        %{measured: false}

      run ->
        %{
          measured: true,
          bytes_raw: run.stats["bytes_raw"],
          bytes_trimmed: run.stats["bytes_trimmed"],
          saving_pct: run.stats["trim_saving_pct"],
          records: run.stats["records"],
          at: run.started_at
        }
    end
  end

  defp pct(_part, 0), do: 0.0
  defp pct(part, total), do: Float.round(part * 100 / total, 1)
end
