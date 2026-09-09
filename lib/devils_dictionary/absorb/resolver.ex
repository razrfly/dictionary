defmodule DevilsDictionary.Absorb.Resolver do
  @moduledoc """
  Turns edges whose other end was a string into assertions, and points spelling
  variants at the word they are variants of.

  `materialize/1` is pure and per record, so when Wiktionary says *cat* has the
  hypernym *feline* all it can write is the string. That edge lands in
  `pending_relations` (see `DevilsDictionary.Claims.PendingRelation` for why it
  cannot be an assertion with a missing endpoint), and this pass drains it as
  soon as the target word exists. An unresolved edge stays a perfectly good
  edge; it stays where it is and is reported.

  WordNet needs none of this: its graph is closed and its sense ids are
  deterministic, so `Sources.Wordnet` resolves inside the absorb and this pass
  never sees its rows. Scorecard row R1 is WordNet's; **R2** is this module's,
  and wants >= 80 % of Wiktionary's edges resolved.

  ## Picking one target out of many

  `feline` exists as a noun and an adjective, so `lower(to_lemma)` alone is
  ambiguous. The order of preference is: the pos the source stated, then an
  exact-case lemma match (so *Turkey* does not answer for *turkey*), then a
  plain part-of-speech priority, then the oldest row. Deterministic, and it
  never invents a link the source did not imply.

  ## The cycle check, corrected

  MVP-0 refused to close a two-lexeme cycle by testing, per row, whether the
  target already pointed back. Both halves of a reciprocal pair are updated by
  the *same statement*, so neither sees the other's write and both land —
  which is how five reciprocal canonical pairs came to exist. The fix is not a
  better predicate: it is to break ties within the batch itself, keeping the
  edge from the higher object id to the lower, so a pair can only ever produce
  one arrow. The per-row check stays as well, for pairs formed across runs.
  """

  import Ecto.Query

  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.Repo

  # Big enough that the planner picks index scans, small enough that no single
  # statement locks a million rows.
  @window 200_000

  @pos_priority ~w(noun verb adj adv name phrase)

  @doc """
  Drains resolvable pending edges into assertions, then links canonical variants.

  Options: `:source_id` to restrict to one source, `:run_id` to stamp output
  ownership. Returns the numbers `mix dd.resolve` prints and scorecard row R2
  reads.
  """
  def run(opts \\ []) do
    source_id = opts[:source_id]

    resolved = resolve_targets(source_id, opts[:run_id])
    canonical = link_canonical()

    %{
      resolved: resolved,
      canonical: canonical,
      by_type: by_type(source_id),
      unresolved_lemmas: unresolved_lemmas(source_id)
    }
  end

  @doc """
  Writes an assertion for every pending edge whose target word now exists.

  `DISTINCT ON` picks one target per pending row by the preference order above.
  The assertion and its first revision are written in one statement pair inside
  a transaction per window, and the pending row is deleted only when its
  assertion exists — so an interrupted run resumes rather than losing edges.

  The revision's endpoint kinds are filled by the `assertion_revisions_kinds`
  trigger and checked against `predicate_endpoint_rules` by a real foreign key,
  which is what makes this raw SQL safe to write.
  """
  def resolve_targets(source_id \\ nil, run_id \\ nil) do
    {min_id, max_id} = id_range(source_id)

    if is_nil(min_id) do
      0
    else
      min_id
      |> id_windows(max_id)
      |> Enum.reduce(0, fn {from, to}, acc ->
        acc + resolve_window(source_id, run_id, from, to)
      end)
    end
  end

  # One `DISTINCT ON` to choose the target, then the same three-step write the
  # materializer uses: identities, revisions, ownership. In Elixir rather than
  # one CTE because `assertions.origin_key` is nullable and the partial unique
  # index does not cover NULLs — pairing an inserted row back to its pending row
  # through `ON CONFLICT … RETURNING` would join every null-key row to every
  # other. The transaction is what makes it atomic; the CTE was only shorter.
  defp resolve_window(source_id, run_id, from, to) do
    {:ok, n} =
      Repo.transaction(
        fn ->
          case matched(source_id, from, to) do
            [] ->
              0

            matched ->
              now = DateTime.utc_now()
              ids = insert_assertions(matched, now)

              write_revisions(matched, ids, now)
              write_ownership(matched, ids, run_id, now)

              {n, _} =
                from(p in "pending_relations", where: p.id in ^Enum.map(matched, & &1.pending_id))
                |> Repo.delete_all()

              n
          end
        end,
        timeout: :infinity
      )

    n
  end

  defp matched(source_id, from, to) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT ON (p.id)
               p.id, p.source_id, p.source_record_id, p.origin_key,
               p.subject_object_id, p.predicate_id, p.confidence, p.method, p.metadata,
               l.object_id
          FROM pending_relations p
          JOIN lexemes l
            ON l.language_tag = 'en' AND lower(l.lemma) = lower(p.to_lemma)
         WHERE p.id >= $1 AND p.id < $2
           AND ($3::bigint IS NULL OR p.source_id = $3)
         ORDER BY p.id,
                  (l.part_of_speech = p.to_pos) DESC NULLS LAST,
                  (l.lemma = p.to_lemma) DESC,
                  array_position($4::text[], l.part_of_speech) NULLS LAST,
                  l.object_id
        """,
        [from, to, source_id, @pos_priority],
        timeout: :infinity
      )

    for [id, src, record, key, subject, predicate, confidence, method, metadata, target] <- rows do
      %{
        pending_id: id,
        source_id: src,
        source_record_id: record,
        origin_key: key,
        subject_object_id: subject,
        predicate_id: predicate,
        confidence: confidence,
        method: method,
        metadata: metadata || %{},
        target_id: target
      }
    end
  end

  defp insert_assertions(matched, now) do
    rows =
      Enum.map(matched, fn m ->
        %{
          source_id: m.source_id,
          origin_key: m.origin_key,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_, inserted} = Repo.insert_all("assertions", rows, returning: [:id])
    Enum.map(inserted, & &1.id)
  end

  defp write_revisions(matched, ids, now) do
    rows =
      Enum.zip_with(matched, ids, fn m, assertion_id ->
        %{
          assertion_id: assertion_id,
          revision_number: 1,
          subject_object_id: m.subject_object_id,
          predicate_id: m.predicate_id,
          object_object_id: m.target_id,
          confidence: m.confidence,
          method: m.method,
          metadata: m.metadata,
          lifecycle_state: "active",
          is_current: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all("assertion_revisions", rows)
  end

  # Ownership, so a later run that no longer emits this edge can retire it — and
  # retire only its own, never another source's support.
  defp write_ownership(matched, ids, run_id, now) do
    rows =
      matched
      |> Enum.zip(ids)
      |> Enum.reject(fn {m, _} -> is_nil(m.source_record_id) end)
      |> Enum.map(fn {m, assertion_id} ->
        %{
          source_record_id: m.source_record_id,
          output_key: m.origin_key || "assertion:#{assertion_id}",
          assertion_id: assertion_id,
          last_seen_run_id: run_id,
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.uniq_by(&{&1.source_record_id, &1.output_key})

    Repo.insert_all("source_assertion_outputs", rows,
      on_conflict: {:replace, [:assertion_id, :last_seen_run_id, :retired_at, :updated_at]},
      conflict_target: [:source_record_id, :output_key]
    )
  end

  @doc """
  Points spelling variants and inflected entries at their canonical lexeme.

  `alt_of` wins over `form_of` when a word has both: *oistre* is a variant
  spelling of *oyster* (an identity), while *oysters* is an inflection of it (a
  form). Only fills an empty slot, never overwrites an editor's choice, and
  refuses to close a two-lexeme cycle — see the moduledoc for why the batch has
  to break its own ties rather than test for one.
  """
  def link_canonical do
    %{num_rows: n} =
      Repo.query!(
        """
        UPDATE lexemes v
           SET canonical_lexeme_id = c.target_id, updated_at = now()
          FROM (
            SELECT DISTINCT ON (r.subject_object_id)
                   r.subject_object_id AS lexeme_id, r.object_object_id AS target_id
              FROM assertion_revisions r
              JOIN predicates p ON p.id = r.predicate_id
             WHERE p.key IN ('alt_of', 'form_of')
               AND r.is_current AND r.lifecycle_state = 'active'
               AND r.object_object_id <> r.subject_object_id
               -- Within one statement, keep only the arrow that runs from the
               -- higher object id to the lower. A reciprocal pair offers two
               -- rows and this admits exactly one of them, so the batch cannot
               -- close a cycle against itself.
               AND NOT EXISTS (
                 SELECT 1
                   FROM assertion_revisions back
                   JOIN predicates bp ON bp.id = back.predicate_id
                  WHERE bp.key IN ('alt_of', 'form_of')
                    AND back.is_current AND back.lifecycle_state = 'active'
                    AND back.subject_object_id = r.object_object_id
                    AND back.object_object_id = r.subject_object_id
                    AND r.subject_object_id < r.object_object_id
               )
             ORDER BY r.subject_object_id, (p.key = 'alt_of') DESC, r.id
          ) c
         WHERE v.object_id = c.lexeme_id
           AND v.canonical_lexeme_id IS NULL
           -- And the same test across runs, where the other half already landed.
           AND NOT EXISTS (
             SELECT 1 FROM lexemes t
              WHERE t.object_id = c.target_id AND t.canonical_lexeme_id = v.object_id
           )
        """,
        [],
        timeout: :infinity
      )

    n
  end

  @doc """
  Resolved and unresolved edge counts per predicate. Scorecard row R2 wants the
  unresolved side *reported* by type, not just totalled.

  Resolved comes from the assertions, unresolved from `pending_relations` — the
  two halves of what used to be one nullable column, so the totals still add up.
  """
  def by_type(source_id \\ nil) do
    resolved =
      from(r in "assertion_revisions",
        join: p in "predicates",
        on: p.id == r.predicate_id,
        join: a in "assertions",
        on: a.id == r.assertion_id,
        where: r.is_current and p.source_native,
        group_by: p.key,
        select: {p.key, count(r.id)}
      )
      |> restrict_source(source_id)
      |> Repo.all()
      |> Map.new()

    unresolved =
      from(p in "pending_relations",
        join: pr in "predicates",
        on: pr.id == p.predicate_id,
        group_by: pr.key,
        select: {pr.key, count(p.id)}
      )
      |> then(fn q ->
        if source_id, do: where(q, [p], p.source_id == ^source_id), else: q
      end)
      |> Repo.all()
      |> Map.new()

    for key <- Enum.uniq(Map.keys(resolved) ++ Map.keys(unresolved)), into: %{} do
      got = Map.get(resolved, key, 0)
      missing = Map.get(unresolved, key, 0)
      {key, %{total: got + missing, resolved: got, unresolved: missing}}
    end
  end

  defp restrict_source(query, nil), do: query
  defp restrict_source(query, source_id), do: where(query, [_r, _p, a], a.source_id == ^source_id)

  @doc """
  The most-referenced targets we still cannot place — the list to read when R2
  falls short.
  """
  def unresolved_lemmas(source_id \\ nil, limit \\ 20) do
    from(p in "pending_relations",
      group_by: p.to_lemma,
      order_by: [desc: count(p.id)],
      limit: ^limit,
      select: {p.to_lemma, count(p.id)}
    )
    |> then(fn q -> if source_id, do: where(q, [p], p.source_id == ^source_id), else: q end)
    |> Repo.all()
  end

  defp id_range(source_id) do
    from(p in "pending_relations", select: {min(p.id), max(p.id)})
    |> then(fn q -> if source_id, do: where(q, [p], p.source_id == ^source_id), else: q end)
    |> Repo.one()
  end

  defp id_windows(min_id, max_id) do
    Stream.unfold(min_id, fn
      from when from > max_id -> nil
      from -> {{from, from + @window}, from + @window}
    end)
  end

  @doc """
  Lexemes that carry no senses of their own but resolve to one that does — what
  `Lexicon.lookup/1` follows. Exposed for tests and the health page.
  """
  def canonical_of(%Lexeme{canonical_lexeme_id: nil}), do: nil
  def canonical_of(%Lexeme{canonical_lexeme_id: id}), do: Repo.get(Lexeme, id)
end
