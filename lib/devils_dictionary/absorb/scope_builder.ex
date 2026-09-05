defmodule DevilsDictionary.Absorb.ScopeBuilder do
  @moduledoc """
  Turns a scope's rules into `scope_lexemes` rows, recording why each lemma
  matched.

  A scope is data (#69 §3): the rules live in `scopes.rules`, membership is by
  lemma, and a lemma matching more than one rule keeps every reason. Adding a
  scope is a row and a task run, not a code change — scorecard E2.

  The three Animals rules, and what each needs:

    * `wordnet_closure` — the hyponym closure of `oewn-00015568-n`. Runs as a
      recursive CTE over `lexical_relations`, not over the dump, because the
      WordNet absorb already inverted `hypernym` into stored `:hyponym` edges.
      So scope building works with the dump deleted and the network off.

    * `wiktionary_category` — lemmas whose entry carries a category in the
      `en:Animals` tree. Matches `lexemes.metadata["wikt_categories"]`, written
      by the index pass, against the category list frozen into `scopes.rules`
      by `mix dd.scope.categories`.

    * `wikidata_taxon` — lemmas that are the scientific name (`P225`) or an
      English common name (`P1843`) of a Wikidata taxon whose `P171` chain
      reaches Animalia. Runs as a recursive CTE **downward** over the stored
      `parent_taxon` edges from `scopes.rules["wikidata_root"]`, so it is
      offline like the other two. Skips itself, loudly, until `concepts` exist.

  #69 §3 also asks this rule for an enwiki sitelink. It is applied, but the
  count without it is reported alongside, because the sitelink usually sits on
  the *everyday* concept rather than on the taxon item — *Felis catus*
  (Q20980826) has none, while *Cat* (Q146) does. Reporting both is what makes
  the difference visible instead of arguable.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia.Concept
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Scope, ScopeLexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources

  @rules ~w(wordnet_closure wiktionary_category wikidata_taxon)
  @chunk 5_000

  @doc """
  Builds a scope. Returns per-rule counts and the resulting size.

  Options:

    * `:reset` — delete the scope's rows first. Without it, `reasons` only ever
      accumulate, so a rule that stopped matching would leave ghosts behind.
  """
  def build(%Scope{} = scope, opts \\ []) do
    if opts[:reset] do
      Repo.delete_all(from sl in ScopeLexeme, where: sl.scope_id == ^scope.id)
    end

    results = Map.new(@rules, fn rule -> {rule, apply_rule(rule, scope)} end)

    stats =
      results
      |> Map.new(fn
        {rule, {:ok, ids}} -> {rule, %{"status" => "ok", "matched" => length(ids)}}
        {rule, {:skip, reason}} -> {rule, %{"status" => "skipped", "reason" => reason}}
      end)
      |> annotate_taxon_rule(scope, results)

    for {rule, {:ok, ids}} <- results, do: write(scope, rule, ids)

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
              SELECT r.to_group_key
                FROM lexical_relations r
                JOIN senses s ON s.id = r.from_sense_id AND s.source_id = $2
                JOIN closure c ON s.group_key = c.group_key
               WHERE r.source_id = $2
                 AND r.type = 'hyponym'
                 AND r.to_group_key IS NOT NULL
            )
            SELECT DISTINCT s2.lexeme_id
              FROM closure c
              JOIN senses s2 ON s2.group_key = c.group_key AND s2.source_id = $2
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
            SELECT id FROM lexemes
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

      not Repo.exists?(from(c in Concept, where: c.qid == ^root)) ->
        {:skip, "no concepts absorbed yet: run mix dd.absorb wikidata --scope #{scope.slug}"}

      true ->
        {:ok, taxon_lexeme_ids(root, sitelink: true)}
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
          SELECT c.id FROM concepts c WHERE c.qid = $1
          UNION
          SELECT r.from_concept_id
            FROM concept_relations r
            JOIN descendants d ON r.to_concept_id = d.id
           WHERE r.type = 'parent_taxon'
        ),
        names AS (
          SELECT lower(c.taxon->>'scientific_name') AS name
            FROM descendants d JOIN concepts c ON c.id = d.id
           WHERE c.taxon->>'scientific_name' IS NOT NULL
             AND ($2 = false OR c.wikipedia_title IS NOT NULL)
          UNION
          SELECT lower(n) AS name
            FROM descendants d
            JOIN concepts c ON c.id = d.id
           CROSS JOIN LATERAL jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(c.taxon->'common_names') = 'array'
                  THEN c.taxon->'common_names' ELSE '[]'::jsonb END) AS n
           WHERE ($2 = false OR c.wikipedia_title IS NOT NULL)
        )
        SELECT DISTINCT l.id
          FROM names JOIN lexemes l ON lower(l.lemma) = names.name
         WHERE names.name <> ''
        """,
        [root, sitelink],
        timeout: :infinity
      )

    Enum.map(rows, &hd/1)
  end

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
        Repo.insert_all(ScopeLexeme, rows,
          on_conflict: union_reasons(),
          conflict_target: [:scope_id, :lexeme_id]
        )

      acc + n
    end)
  end

  defp union_reasons do
    from(sl in ScopeLexeme,
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
