defmodule DevilsDictionary.Health do
  @moduledoc """
  Numbers. Coverage per source within a scope, raw-vs-derived parity, unresolved
  relation targets, link histogram and conflicts, and the MVP-0 scorecard rows
  as functions (`mix dd.score`). Spec: issue #69 §7.

  S1 implements the rows S1 is judged on — A5, A9, M1, M4, R2. S2 adds the
  encyclopedia rows — A6, A7, A10 and the four link rows L1–L4. S3 adds the
  rest and `mix dd.score` on top of them, rather than re-deriving numbers the
  tasks have already printed once.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
  alias DevilsDictionary.Health.{Coverage, Parity}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{ImportRun, Source, SourceRecord}

  @doc """
  **A5** — how much of a scope a source actually covers.

  A scope lexeme counts as covered when the source attests it (`source_ids`),
  which for a dump source means a record was written for its lemma. The misses
  are bucketed, because for Animals they are not random: WordNet and Wikidata
  contribute thousands of scientific names — binomials, and genus, family and
  order names — and Wiktionary files those under Translingual rather than
  English, so the English index can never hold them (A5 v2, #69 v12).
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

    # One query for the whole call, not one per miss.
    scientific_names = scientific_names()

    %{
      scope: scope_slug,
      source: source_slug,
      total: total,
      covered: covered,
      pct: pct(covered, total),
      missing: length(misses),
      missing_by_kind: Enum.frequencies_by(misses, &lemma_kind(&1, scientific_names)),
      sample: misses |> Enum.take(20)
    }
  end

  # A scientific name is what Wiktionary files as Translingual rather than
  # English: a Linnaean binomial by shape (capitalised genus, lowercase
  # species), or a name at any rank that a concept carries as
  # `taxon.scientific_name` — genus, family and order names such as
  # Archilochus, Paguridae and Therapsida (A5 v2, #69 v12).
  defp lemma_kind(lemma, scientific_names) do
    cond do
      Regex.match?(~r/^[A-Z][a-z]+ [a-z]+$/, lemma) -> "scientific_name"
      MapSet.member?(scientific_names, lemma) -> "scientific_name"
      String.contains?(lemma, " ") -> "multiword"
      true -> "single_word"
    end
  end

  defp scientific_names do
    from(c in Concept,
      where: not is_nil(fragment("?->>'scientific_name'", c.taxon)),
      distinct: true,
      select: fragment("?->>'scientific_name'", c.taxon)
    )
    |> Repo.all()
    |> MapSet.new()
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

  @doc "**A1** — every source in the catalog absorbed, counting `done` runs only."
  defdelegate source_runs(), to: Coverage, as: :sources

  @doc "**A2** — WordNet synsets and lexemes."
  defdelegate wordnet(), to: Coverage

  @doc "**A3** — the size of the English index."
  defdelegate index(lang \\ "en"), to: Coverage

  @doc "**A4** — scope membership and the reasons for it."
  defdelegate scope(scope_slug \\ "animals"), to: Coverage

  @doc "**A8** — Bierce's entries and how many of his headwords the index knew."
  defdelegate bierce(scope_slug \\ "animals"), to: Coverage

  @doc "**R1** — WordNet edges resolved at absorb."
  defdelegate wordnet_edges(), to: Coverage

  @doc "**X3** — forms and spelling variants land on the right word."
  defdelegate variants(), to: Coverage

  @doc """
  The per-source record ledger — fetched, absent, needs-materialization,
  needs-fetch, changed, last run — which `mix dd.health` prints and
  `/admin/imports` renders from the same call.
  """
  defdelegate records(scope_slug \\ "animals"), to: Coverage

  @doc """
  Everything one source page shows: the row, its pin, its ledger, what it
  materialized, its coverage of a scope, its recent runs and a few real samples.
  """
  defdelegate source_detail(slug, opts \\ []), to: Coverage

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

  # ── S2: the encyclopedia rows ────────────────────────────────────────────

  @doc """
  **A6** — Wikidata coverage.

  Two measures. The first is the row as #69 §7 writes it: every QID a link or a
  relation names must have a `concepts` row, and anything less is a dangling
  reference. The second is the amendment the S1 audit added: Wikidata's share of
  the scope reported next to Wiktionary's, and the **union**, which is expected
  to approach 100 % because the 1,995 Linnaean binomials A5 can never cover are
  exactly what Wikidata's `P225` names are.
  """
  def concept_coverage(scope_slug \\ "animals") do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    # Every QID a link or a relation names, and how many of those have no row.
    %{rows: [[referenced, dangling]]} =
      Repo.query!(
        """
        WITH refs AS (
          SELECT concept_id AS id FROM concept_links
          UNION SELECT from_concept_id FROM concept_relations
          UNION SELECT to_concept_id FROM concept_relations
        )
        SELECT count(*),
               count(*) FILTER (WHERE c.id IS NULL)
          FROM refs LEFT JOIN concepts c ON c.id = refs.id
        """,
        [],
        timeout: :infinity
      )

    total = Repo.aggregate(scope_query(scope), :count)
    wiktionary = scope_attested(scope, "wiktionary")
    # Wikidata never writes a lexeme, so its reach into the scope is measured by
    # the links that name it, not by `lexemes.source_ids`.
    linked = scope_with_concept(scope)
    union = union_covered(scope)

    %{
      referenced_qids: referenced,
      dangling: dangling,
      pct: pct(referenced - dangling, referenced),
      scope_total: total,
      wiktionary: wiktionary,
      wiktionary_pct: pct(wiktionary, total),
      wikidata_linked: linked,
      wikidata_linked_pct: pct(linked, total),
      union: union,
      union_pct: pct(union, total)
    }
  end

  @doc """
  **A7** — every concept with an English Wikipedia article has an entry or an
  absent marker. A concept we know has an article and never asked about is the
  gap this row exists to catch.

  "Answered" is the measure, not "has an entry": a disambiguation page is
  answered by its candidate list and deliberately gets no entry, because
  "Seal may refer to…" is not an encyclopedia article about a seal.
  """
  def wikipedia_coverage do
    source = Sources.get_source_by_slug!("wikipedia")

    with_sitelink =
      from(c in Concept, where: not is_nil(c.wikipedia_title)) |> Repo.aggregate(:count)

    asserted = asserted_concepts()
    asserted_answered = asserted_concepts_answered(source)

    answered =
      Repo.one!(
        from c in Concept,
          where: not is_nil(c.wikipedia_title),
          where:
            fragment("EXISTS (SELECT 1 FROM entries e WHERE e.concept_id = ?)", c.id) or
              fragment(
                "EXISTS (SELECT 1 FROM source_records r WHERE r.source_id = ? AND r.external_id = 'concept:' || ?)",
                ^source.id,
                c.qid
              ),
          select: count(c.id)
      )

    with_entry =
      Repo.one!(
        from c in Concept,
          where: not is_nil(c.wikipedia_title),
          where: fragment("EXISTS (SELECT 1 FROM entries e WHERE e.concept_id = ?)", c.id),
          select: count(c.id)
      )

    %{
      with_sitelink: with_sitelink,
      answered: answered,
      with_entry: with_entry,
      missing: with_sitelink - answered,
      pct: pct(answered, with_sitelink),
      asserted: asserted,
      asserted_answered: asserted_answered,
      asserted_pct: pct(asserted_answered, asserted)
    }
  end

  # A concept a scope word actually links to, at `auto` or `confirmed`. This is
  # the population A7 v2 grades: the 0.40 disambiguation candidates are things a
  # page merely *mentioned*, and each summary we fetch names more of them, so
  # the all-sitelinked denominator grows faster than any pass can fill it. The
  # S3 audit predicted this for the second scope and recommended exactly this
  # split; S5's `emotions` scope is where it came due (#69 v13).
  @asserted ~w(auto confirmed)

  defp asserted_concepts do
    Repo.one!(
      from c in Concept,
        where: not is_nil(c.wikipedia_title),
        where:
          fragment(
            "EXISTS (SELECT 1 FROM concept_links cl WHERE cl.concept_id = ? AND cl.status = ANY(?))",
            c.id,
            ^@asserted
          ),
        select: count(c.id)
    )
  end

  defp asserted_concepts_answered(source) do
    Repo.one!(
      from c in Concept,
        where: not is_nil(c.wikipedia_title),
        where:
          fragment(
            "EXISTS (SELECT 1 FROM concept_links cl WHERE cl.concept_id = ? AND cl.status = ANY(?))",
            c.id,
            ^@asserted
          ),
        where:
          fragment("EXISTS (SELECT 1 FROM entries e WHERE e.concept_id = ?)", c.id) or
            fragment(
              "EXISTS (SELECT 1 FROM source_records r WHERE r.source_id = ? AND r.external_id = 'concept:' || ?)",
              ^source.id,
              c.qid
            ),
        select: count(c.id)
    )
  end

  @doc """
  **A10** — images.

  Measured over the concepts a scope's words actually **link to**, not over
  every concept with an entry. The concept pass gives an entry to all 32,000
  disambiguation candidates the "may refer to" pages named, and *Cherry Bomb
  (album)* having no picture says nothing about whether *cat* does. The wider
  figures are reported beside it.
  """
  def images(scope_slug \\ "animals") do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    %{rows: [[asserted, asserted_with_image, lexemes, lexemes_with_image]]} =
      Repo.query!(
        """
        WITH asserted AS (
          SELECT DISTINCT cl.concept_id AS id
            FROM concept_links cl
            JOIN scope_lexemes sl ON sl.lexeme_id = cl.lexeme_id AND sl.scope_id = $1
           WHERE cl.status IN ('auto', 'confirmed')
        ),
        per_lexeme AS (
          SELECT sl.lexeme_id, bool_or(c.image_url IS NOT NULL) AS has_image
            FROM scope_lexemes sl
            JOIN concept_links cl
              ON cl.lexeme_id = sl.lexeme_id AND cl.status IN ('auto', 'confirmed')
            JOIN concepts c ON c.id = cl.concept_id
           WHERE sl.scope_id = $1
           GROUP BY 1
        )
        SELECT (SELECT count(*) FROM asserted),
               (SELECT count(*) FROM asserted JOIN concepts c ON c.id = asserted.id
                 WHERE c.image_url IS NOT NULL),
               (SELECT count(*) FROM per_lexeme),
               (SELECT count(*) FROM per_lexeme WHERE has_image)
        """,
        [scope.id],
        timeout: :infinity
      )

    with_entry =
      from(c in Concept,
        where: fragment("EXISTS (SELECT 1 FROM entries e WHERE e.concept_id = ?)", c.id)
      )

    entries = Repo.aggregate(with_entry, :count)

    entries_with_image =
      with_entry |> where([c], not is_nil(c.image_url)) |> Repo.aggregate(:count)

    all = Repo.aggregate(Concept, :count)
    all_with_image = from(c in Concept, where: not is_nil(c.image_url)) |> Repo.aggregate(:count)

    %{
      asserted: asserted,
      asserted_with_image: asserted_with_image,
      pct: pct(asserted_with_image, asserted),
      lexemes_linked: lexemes,
      lexemes_with_image: lexemes_with_image,
      lexemes_pct: pct(lexemes_with_image, lexemes),
      with_entry: entries,
      with_image: entries_with_image,
      entry_pct: pct(entries_with_image, entries),
      all_concepts: all,
      all_with_image: all_with_image,
      all_pct: pct(all_with_image, all)
    }
  end

  @doc """
  **L1** — the link rate, and the histogram behind it.

  Reported twice on purpose. `strict_pct` counts only what the ladder's own
  confidences reach; `pct` counts links after `Linker.corroborate/1` has raised
  the title matches a second signal agrees with. The QID rungs alone reach about
  a fifth of an Animals scope, so the difference between the two numbers *is*
  the finding.
  """
  def links(scope_slug \\ "animals", threshold \\ 0.8) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)
    total = Repo.aggregate(scope_query(scope), :count)

    linked = scope_with_link(scope, threshold)
    strict = scope_with_link(scope, threshold, strict: true)
    any = scope_with_link(scope, 0.0)
    reachable = scope_with_article(scope)

    histogram =
      Repo.all(
        from cl in ConceptLink,
          join: sl in ScopeLexeme,
          on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
          group_by: [cl.method, cl.confidence],
          order_by: [asc: cl.method, desc: cl.confidence],
          select: {cl.method, cl.confidence, count(cl.id)}
      )

    %{
      scope_total: total,
      threshold: threshold,
      linked: linked,
      pct: pct(linked, total),
      reachable: reachable,
      reachable_pct: pct(linked, reachable),
      strict_linked: strict,
      strict_pct: pct(strict, total),
      any_linked: any,
      any_pct: pct(any, total),
      histogram: histogram,
      corroboration: corroboration_counts(scope)
    }
  end

  @doc """
  **L2** — conflicts. One lexeme with two different concepts both above 0.7 is a
  disagreement, and #69 §5 says we surface it rather than pick a winner.
  """
  def conflicts(scope_slug \\ "animals", threshold \\ 0.7, limit \\ 20) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    rows =
      Repo.all(
        from cl in ConceptLink,
          join: l in Lexeme,
          on: l.id == cl.lexeme_id,
          join: sl in ScopeLexeme,
          on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
          where: cl.confidence >= ^threshold and cl.status != :rejected,
          group_by: [cl.lexeme_id, l.lemma, l.pos],
          having: count(fragment("DISTINCT ?", cl.concept_id)) > 1,
          order_by: [desc: count(fragment("DISTINCT ?", cl.concept_id))],
          select: %{
            lemma: l.lemma,
            pos: l.pos,
            concepts: count(fragment("DISTINCT ?", cl.concept_id))
          }
      )

    %{count: length(rows), sample: Enum.take(rows, limit)}
  end

  @doc """
  **L3** — how many linked concepts sit on a `parent_taxon` path to Animalia.

  Walks the stored edges, so it is a check on the absorb as much as on the
  linker: a walk cut off at `--max-depth` shows up here as a soft number.

  The population is links we **assert** (`auto` or `confirmed`). A
  `:candidate` from a "may refer to" page is a possibility, not a claim — an
  Animals scope carries about 19,000 of them, and *BYD Seal* was never going to
  reach Animalia. The figure including candidates is reported beside it.
  """
  def taxonomy(scope_slug \\ "animals", root \\ "Q729") do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    %{rows: [[linked, reaching, all_linked, all_reaching]]} =
      Repo.query!(
        """
        WITH RECURSIVE descendants(id) AS (
          SELECT c.id FROM concepts c WHERE c.qid = $2
          UNION
          SELECT r.from_concept_id FROM concept_relations r
            JOIN descendants d ON r.to_concept_id = d.id
           WHERE r.type = 'parent_taxon'
        ),
        linked AS (
          SELECT DISTINCT cl.concept_id AS id
            FROM concept_links cl
            JOIN scope_lexemes sl ON sl.lexeme_id = cl.lexeme_id AND sl.scope_id = $1
           WHERE cl.status IN ('auto', 'confirmed')
        ),
        all_linked AS (
          SELECT DISTINCT cl.concept_id AS id
            FROM concept_links cl
            JOIN scope_lexemes sl ON sl.lexeme_id = cl.lexeme_id AND sl.scope_id = $1
           WHERE cl.status <> 'rejected'
        ),
        reaching AS (
          SELECT c.id
            FROM concepts c
           WHERE c.id IN (SELECT id FROM descendants)
              OR c.taxon_concept_id IN (SELECT id FROM descendants)
        )
        SELECT (SELECT count(*) FROM linked),
               (SELECT count(*) FROM linked WHERE id IN (SELECT id FROM reaching)),
               (SELECT count(*) FROM all_linked),
               (SELECT count(*) FROM all_linked WHERE id IN (SELECT id FROM reaching))
        """,
        [scope.id, root],
        timeout: :infinity
      )

    %{
      linked_concepts: linked,
      reaching_root: reaching,
      pct: pct(reaching, linked),
      with_candidates: all_linked,
      with_candidates_reaching: all_reaching,
      with_candidates_pct: pct(all_reaching, all_linked)
    }
  end

  @doc """
  **L4** — disambiguation. Every probe that hit a "may refer to" page must have
  stored the title on the lexeme and its candidates as links; a hit with no
  candidates is the failure this row looks for.

  Counted by **lemma**, as #69 §7 words it. A probe is one fact per lemma and
  the candidate rung links nouns only, so counting lexemes would charge
  `seal/verb` for candidates that were never meant to be its.
  """
  def disambiguation(scope_slug \\ "animals") do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    hit = fn query ->
      query
      |> where([_sl, l], fragment("jsonb_exists(?, 'wikipedia_disambiguation')", l.metadata))
      |> select([_sl, l], fragment("count(DISTINCT ?)", l.lemma))
      |> Repo.one!()
    end

    hits = hit.(scope_query(scope))

    with_candidates =
      hit.(
        where(
          scope_query(scope),
          [_sl, l],
          fragment(
            "EXISTS (SELECT 1 FROM concept_links cl WHERE cl.lexeme_id = ? AND cl.method = 'disambiguation')",
            l.id
          )
        )
      )

    candidates =
      Repo.one!(
        from cl in ConceptLink,
          join: sl in ScopeLexeme,
          on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
          where: cl.method == :disambiguation,
          select: count(cl.id)
      )

    # A lemma whose only scope lexemes are adjectives or verbs can never carry a
    # candidate: a thing is not an adjective. Reported so the remainder is
    # explained rather than left as an unexplained shortfall.
    non_nominal =
      hit.(
        where(
          scope_query(scope),
          [_sl, l],
          fragment(
            "NOT EXISTS (SELECT 1 FROM lexemes n JOIN scope_lexemes s2 ON s2.lexeme_id = n.id AND s2.scope_id = ? WHERE n.lemma = ? AND n.pos = ANY(?))",
            ^scope.id,
            l.lemma,
            ^DevilsDictionary.Absorb.Linker.nominal_pos()
          )
        )
      )

    %{
      hits: hits,
      with_candidates: with_candidates,
      pct: pct(with_candidates, hits),
      non_nominal: non_nominal,
      nominal_pct: pct(with_candidates, hits - non_nominal),
      candidates: candidates,
      promoted:
        Repo.one!(
          from cl in ConceptLink,
            join: sl in ScopeLexeme,
            on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
            where: cl.method == :disambiguation and cl.confidence > 0.4,
            select: count(cl.id)
        )
    }
  end

  # ── S2 helpers ───────────────────────────────────────────────────────────

  defp scope_query(scope) do
    from sl in ScopeLexeme,
      join: l in Lexeme,
      on: l.id == sl.lexeme_id,
      where: sl.scope_id == ^scope.id
  end

  defp scope_attested(scope, source_slug) do
    source = Sources.get_source_by_slug!(source_slug)

    scope_query(scope)
    |> where([_sl, l], fragment("? = ANY(?)", ^source.id, l.source_ids))
    |> Repo.aggregate(:count)
  end

  defp scope_with_concept(scope) do
    scope_query(scope)
    |> where(
      [_sl, l],
      fragment("EXISTS (SELECT 1 FROM concept_links cl WHERE cl.lexeme_id = ?)", l.id)
    )
    |> Repo.aggregate(:count)
  end

  # L1's denominator, as amended in S2 (#69 v10): the scope lexemes English
  # Wikipedia has an article for. 6,840 Animals lemmas have none — `soup-fin`,
  # `trochid`, `prophaethontid` — and no rung can conjure an article that does
  # not exist, so measuring against the whole scope measures Wikipedia's
  # coverage of zoology rather than the linker.
  #
  # "Has an article" is a record that is not an absent marker: the probe asked,
  # and got a page back.
  defp scope_with_article(scope) do
    Repo.one(
      from l in Lexeme,
        join: sl in ScopeLexeme,
        on: sl.lexeme_id == l.id and sl.scope_id == ^scope.id,
        where:
          fragment(
            """
            EXISTS (
              SELECT 1 FROM source_records r
                JOIN sources s ON s.id = r.source_id AND s.slug = 'wikipedia'
               WHERE r.external_id = ? AND r.absent_until IS NULL
            )
            """,
            l.lemma
          ),
        select: count(l.id)
    )
  end

  # A5's denominator plus Wikidata's reach: a scope lexeme is covered when
  # Wiktionary attests it *or* a concept link names it.
  defp union_covered(scope) do
    source = Sources.get_source_by_slug!("wiktionary")

    scope_query(scope)
    |> where(
      [_sl, l],
      fragment("? = ANY(?)", ^source.id, l.source_ids) or
        fragment("EXISTS (SELECT 1 FROM concept_links cl WHERE cl.lexeme_id = ?)", l.id)
    )
    |> Repo.aggregate(:count)
  end

  defp scope_with_link(scope, threshold, opts \\ []) do
    query =
      scope_query(scope)
      |> where(
        [_sl, l],
        fragment(
          "EXISTS (SELECT 1 FROM concept_links cl WHERE cl.lexeme_id = ? AND cl.confidence >= ? AND cl.status <> 'rejected')",
          l.id,
          ^threshold
        )
      )

    # The strict reading ignores anything corroboration lifted, which is what
    # makes the two L1 numbers comparable.
    query =
      if opts[:strict] do
        where(
          query,
          [_sl, l],
          fragment(
            "EXISTS (SELECT 1 FROM concept_links cl WHERE cl.lexeme_id = ? AND cl.confidence >= ? AND cl.status <> 'rejected' AND NOT jsonb_exists(cl.metadata, 'corroboration'))",
            l.id,
            ^threshold
          )
        )
      else
        query
      end

    Repo.aggregate(query, :count)
  end

  defp corroboration_counts(scope) do
    Repo.all(
      from cl in ConceptLink,
        join: sl in ScopeLexeme,
        on: sl.lexeme_id == cl.lexeme_id and sl.scope_id == ^scope.id,
        where: fragment("jsonb_exists(?, 'corroboration')", cl.metadata),
        group_by: fragment("?->>'corroboration'", cl.metadata),
        select: {fragment("?->>'corroboration'", cl.metadata), count(cl.id)}
    )
    |> Map.new()
  end

  defp pct(_part, 0), do: 0.0
  defp pct(part, total), do: Float.round(part * 100 / total, 1)
end
