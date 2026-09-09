defmodule DevilsDictionary.Absorb.ScopeBuilder do
  @moduledoc """
  Turns a scope's rules into `scope_lexeme_members` rows, recording why each
  lemma matched.

  A scope is data (#69 §3): the rules live in `scopes.rules`, membership is by
  lemma, and a lemma matching more than one rule keeps every reason. Adding a
  scope is a row and a task run, not a code change — scorecard E2.

  The four rules, and what each needs:

    * `wordnet_closure` — the hyponym closure of `oewn-00015568-n`. Runs as a
      recursive CTE over the stored `hyponym` assertions, not over the dump,
      because the WordNet absorb already inverted `hypernym` into stored
      `hyponym` edges. So scope building works with the dump deleted and the
      network off.

    * `wiktionary_category` — lemmas whose entry carries a category in the
      `en:Animals` tree. Matches `lexemes.metadata["wikt_categories"]`, written
      by the index pass, against the category list frozen into `scopes.rules`
      by `mix dd.scope.categories`.

    * `wikidata_taxon` — lemmas that are the scientific name (`P225`) or an
      English common name (`P1843`) of a Wikidata taxon whose `P171` chain
      reaches Animalia. Runs as a recursive CTE **downward** over the stored
      `parent_taxon` edges from `scopes.rules["wikidata_root"]`, so it is
      offline like the other two. Skips itself, loudly, until `concepts` exist.

    * `explicit_lemmas` — a named list, for a bounded pilot that no closure or
      category tree describes. #74 asks for `priv/scopes/culture.json` over
      *nepotism*, *bank* and *egomaniac*, and none of the other three rules
      would ever produce those three words together. Every member still records
      its reason, so an explicit scope is as inspectable as a derived one.

  #69 §3 also asks the taxon rule for an enwiki sitelink. It is applied, but the
  count without it is reported alongside, because the sitelink usually sits on
  the *everyday* concept rather than on the taxon item — *Felis catus*
  (Q20980826) has none, while *Cat* (Q146) does. Reporting both is what makes
  the difference visible instead of arguable.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Scope, ScopeMember}
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @rules ~w(wordnet_closure wiktionary_category wikidata_taxon explicit_lemmas)
  @chunk 5_000

  @doc """
  Builds a scope. Returns per-rule counts and the resulting size.

  Options:

    * `:reset` — delete the scope's rows first. Without it, `reasons` only ever
      accumulate, so a rule that stopped matching would leave ghosts behind.
  """
  def build(%Scope{} = scope, opts \\ []) do
    if opts[:reset] do
      Repo.delete_all(from sl in ScopeMember, where: sl.scope_id == ^scope.id)
    end

    results = Map.new(@rules, fn rule -> {rule, apply_rule(rule, scope)} end)

    stats =
      results
      |> Map.new(fn
        {rule, {:ok, ids}} ->
          {rule, %{"status" => "ok", "matched" => length(ids)}}

        # A rule may report as well as match. `explicit_lemmas` names the lemmas
        # the index does not hold, so a typo in the scope file reads as a typo
        # rather than as a small scope.
        {rule, {:ok, ids, extra}} ->
          {rule, Map.merge(%{"status" => "ok", "matched" => length(ids)}, extra)}

        {rule, {:skip, reason}} ->
          {rule, %{"status" => "skipped", "reason" => reason}}
      end)
      |> annotate_taxon_rule(scope, results)

    for {rule, result} <- results, ids = matched(result), ids != [] do
      write(scope, rule, ids)
    end

    total = Lexicon.count_scope_lexemes(scope)
    reasons = Lexicon.scope_reason_counts(scope)
    without = Lexicon.count_scope_lexemes_without_reason(scope)

    Lexicon.update_scope(scope, %{
      stats:
        Map.merge(stats, %{
          "total" => total,
          "built_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
    })

    %{rules: stats, total: total, reasons: reasons, without_reason: without}
  end

  # ── rules ────────────────────────────────────────────────────────────────

  defp apply_rule("wordnet_closure", scope) do
    roots = scope.rules["wordnet_roots"] || []
    source = Sources.get_source_by_slug("wordnet")

    cond do
      roots == [] ->
        {:skip, "no wordnet_roots in scopes.rules"}

      is_nil(source) ->
        {:skip, "wordnet source not seeded"}

      true ->
        %{rows: rows} =
          Repo.query!(
            """
            WITH RECURSIVE closure(group_key) AS (
              SELECT unnest($1::text[])
              UNION
              SELECT trev.group_key
                FROM assertion_revisions r
                JOIN predicates p ON p.id = r.predicate_id AND p.key = 'hyponym'
                JOIN senses s ON s.object_id = r.subject_object_id AND s.source_id = $2
                JOIN sense_revisions srev
                  ON srev.sense_id = s.object_id AND srev.is_current
                JOIN closure c ON srev.group_key = c.group_key
                JOIN senses ts ON ts.object_id = r.object_object_id AND ts.source_id = $2
                JOIN sense_revisions trev
                  ON trev.sense_id = ts.object_id AND trev.is_current
               WHERE r.is_current AND r.lifecycle_state = 'active'
                 AND trev.group_key IS NOT NULL
            )
            SELECT DISTINCT s2.lexeme_id
              FROM closure c
              JOIN sense_revisions r2 ON r2.group_key = c.group_key AND r2.is_current
              JOIN senses s2 ON s2.object_id = r2.sense_id AND s2.source_id = $2
            """,
            [roots, source.id],
            timeout: :infinity
          )

        {:ok, Enum.map(rows, &hd/1)}
    end
  end

  defp apply_rule("wiktionary_category", scope) do
    case scope.rules["wiktionary_categories"] || [] do
      [] ->
        {:skip, "no wiktionary_categories pinned; run mix dd.scope.categories"}

      categories ->
        %{rows: rows} =
          Repo.query!(
            """
            SELECT object_id FROM lexemes
             WHERE metadata->'wikt_categories' ?| $1::text[]
            """,
            [categories],
            timeout: :infinity
          )

        {:ok, Enum.map(rows, &hd/1)}
    end
  end

  defp apply_rule("wikidata_taxon", scope) do
    root = scope.rules["wikidata_root"]

    cond do
      is_nil(root) ->
        {:skip, "no wikidata_root in scopes.rules"}

      is_nil(Encyclopedia.by_qid(root)) ->
        {:skip, "no entities absorbed yet: run mix dd.absorb wikidata --scope #{scope.slug}"}

      true ->
        {:ok, taxon_lexeme_ids(root, sitelink: true)}
    end
  end

  # #74's fourth rule. A bounded pilot — `culture` is *nepotism*, *bank* and
  # *egomaniac* — that no closure or category tree describes. Matched
  # case-insensitively on the lemma, across every part of speech, because a
  # scope is a set of words and *bank* the verb belongs with *bank* the noun.
  #
  # A lemma the index does not hold is not silently dropped: it is reported, so
  # a typo in the file reads as a typo rather than as a small scope.
  defp apply_rule("explicit_lemmas", scope) do
    case scope.rules["explicit_lemmas"] || [] do
      [] ->
        {:skip, "no explicit_lemmas in scopes.rules"}

      lemmas ->
        downcased = Enum.map(lemmas, &String.downcase/1)

        found =
          Repo.all(
            from l in Lexeme,
              where: fragment("lower(?)", l.lemma) in ^downcased,
              select: {fragment("lower(?)", l.lemma), l.object_id}
          )

        missing = downcased -- Enum.map(found, &elem(&1, 0))

        if missing == [] do
          {:ok, Enum.map(found, &elem(&1, 1))}
        else
          {:ok, Enum.map(found, &elem(&1, 1)), %{"not_in_index" => missing}}
        end
    end
  end

  # ── writing ──────────────────────────────────────────────────────────────

  # #69 §3's enwiki-sitelink requirement is applied, and the count without it is
  # reported next to it. The taxon item usually has no article of its own, so
  # the gap between these two numbers is the finding, not a rounding error.
  defp annotate_taxon_rule(stats, scope, results) do
    case results["wikidata_taxon"] do
      {:ok, _ids} ->
        without = length(taxon_lexeme_ids(scope.rules["wikidata_root"], sitelink: false))
        update_in(stats, ["wikidata_taxon"], &Map.put(&1, "matched_without_sitelink", without))

      _ ->
        stats
    end
  end

  @doc """
  Lexemes named by a taxon under `root`, by scientific name or English common
  name.

  `sitelink: false` drops #69 §3's enwiki requirement, which is how the two
  numbers in the build report are produced.
  """
  def taxon_lexeme_ids(root, opts \\ []) do
    sitelink = Keyword.get(opts, :sitelink, true)

    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE descendants(id) AS (
          SELECT x.object_id FROM external_identifiers x
           WHERE x.namespace = 'wikidata' AND x.external_id = $1 AND x.status = 'verified'
          UNION
          SELECT r.subject_object_id
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id AND p.key = 'parent_taxon'
            JOIN descendants d ON r.object_object_id = d.id
           WHERE r.is_current AND r.lifecycle_state = 'active'
        ),
        names AS (
          SELECT lower(e.metadata->'taxon'->>'scientific_name') AS name
            FROM descendants d JOIN entities e ON e.object_id = d.id
           WHERE e.metadata->'taxon'->>'scientific_name' IS NOT NULL
             AND ($2 = false OR e.metadata->>'wikipedia_title' IS NOT NULL)
          UNION
          SELECT lower(n) AS name
            FROM descendants d
            JOIN entities e ON e.object_id = d.id
           CROSS JOIN LATERAL jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(e.metadata->'taxon'->'common_names') = 'array'
                  THEN e.metadata->'taxon'->'common_names' ELSE '[]'::jsonb END) AS n
           WHERE ($2 = false OR e.metadata->>'wikipedia_title' IS NOT NULL)
        )
        SELECT DISTINCT l.object_id
          FROM names JOIN lexemes l ON lower(l.lemma) = names.name
         WHERE names.name <> ''
        """,
        [root, sitelink],
        timeout: :infinity
      )

    Enum.map(rows, &hd/1)
  end

  defp matched({:ok, ids}), do: ids
  defp matched({:ok, ids, _extra}), do: ids
  defp matched({:skip, _reason}), do: []

  defp write(_scope, _rule, []), do: 0

  defp write(scope, rule, lexeme_ids) do
    now = DateTime.utc_now()

    lexeme_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn chunk, acc ->
      rows =
        Enum.map(chunk, fn id ->
          %{
            scope_id: scope.id,
            lexeme_id: id,
            reasons: [rule],
            inserted_at: now,
            updated_at: now
          }
        end)

      {n, _} =
        Repo.insert_all(ScopeMember, rows,
          on_conflict: union_reasons(),
          conflict_target: [:scope_id, :lexeme_id]
        )

      acc + n
    end)
  end

  defp union_reasons do
    from(sl in ScopeMember,
      update: [
        set: [
          reasons:
            fragment(
              "(SELECT array_agg(DISTINCT x) FROM unnest(? || EXCLUDED.reasons) AS x)",
              sl.reasons
            ),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end
end
