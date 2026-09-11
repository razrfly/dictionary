defmodule DevilsDictionary.Health do
  @moduledoc """
  Numbers. Coverage per source within a scope, raw-vs-derived parity, unresolved
  relation targets, link histogram and conflicts, and the MVP-0 scorecard rows
  as functions (`mix dd.score`). Spec: issue #69 §7.

  S1 implements the rows S1 is judged on — A5, A9, M1, M4, R2. S2 adds the
  encyclopedia rows — A6, A7, A10 and the four link rows L1–L4. S3 adds the
  rest and `mix dd.score` on top of them, rather than re-deriving numbers the
  tasks have already printed once.

  ## Two kinds of number, and they are not interchangeable (#77 §2)

  **Global integrity** takes no scope and answers for the whole corpus:
  `index/1`, `wordnet/0`, `wordnet_edges/0`, `variants/0`, `unresolved/0`,
  `parity/1`, `trim_saving/1`, and the page rows in `Health.Pages`.

  **Population coverage** takes a `scope_slug` and answers only for that
  population: `scope/1`, `bierce/1`, `coverage/2`, `records/1`,
  `concept_coverage/1`, `images/1`, `links/2`, `conflicts/3`, `taxonomy/2`,
  `disambiguation/1`.

  Every one of the second group used to default to `"animals"`, so an
  unqualified call answered for the test population and read as a whole-corpus
  result. The argument is now required. No population's pass implies the
  corpus's — print the population and the denominator with the figure.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Resolver
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Encyclopedia
  alias DevilsDictionary.Health.{Coverage, Pages, Parity}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Entity, Lexeme}
  alias DevilsDictionary.Registry.{Sense, SenseRevision}
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

    scoped = from sl in ScopeMember, join: l in Lexeme, on: l.object_id == sl.lexeme_id
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

  # `concepts.taxon` was a jsonb column of taxonomic facts; those facts are now
  # descriptive metadata on the entity, under the same key.
  defp scientific_names do
    from(e in Entity,
      where: not is_nil(fragment("? -> 'taxon' ->> 'scientific_name'", e.metadata)),
      distinct: true,
      select: fragment("? -> 'taxon' ->> 'scientific_name'", e.metadata)
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
      senses: linkable_senses(templated),
      entries: linkable_content(templated)
    }
    |> then(fn parts ->
      total = parts.senses.total + parts.entries.total
      linked = parts.senses.linked + parts.entries.linked

      Map.merge(parts, %{total: total, linked: linked, pct: pct(linked, total)})
    end)
  end

  # The row's own url is on its current revision now, and the record it came
  # from is two joins away rather than one — the revision cites a *revision* of
  # the record, which is the whole point of #74. The three acceptable answers
  # are unchanged.
  defp linkable_senses(templated) do
    base =
      from s in Sense,
        join: rev in SenseRevision,
        on: rev.sense_id == s.object_id and rev.is_current,
        left_join: srr in SourceRecordRevision,
        on: srr.id == rev.source_record_revision_id,
        left_join: r in SourceRecord,
        on: r.id == srr.source_record_id

    linked =
      base
      |> where(
        [s, rev, _srr, r],
        not is_nil(rev.url) or not is_nil(r.url) or s.source_id in ^templated
      )
      |> Repo.aggregate(:count)

    %{
      total: Repo.aggregate(Sense, :count),
      linked: linked,
      pct: pct(linked, Repo.aggregate(Sense, :count))
    }
  end

  defp linkable_content(templated) do
    base =
      from c in ContentItem,
        join: rev in ContentRevision,
        on: rev.content_id == c.object_id and rev.is_current,
        left_join: srr in SourceRecordRevision,
        on: srr.id == rev.source_record_revision_id,
        left_join: r in SourceRecord,
        on: r.id == srr.source_record_id

    total = Repo.aggregate(ContentItem, :count)

    linked =
      base
      |> where(
        [c, rev, _srr, r],
        not is_nil(rev.canonical_url) or not is_nil(r.url) or c.source_id in ^templated
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
  defdelegate scope(scope_slug), to: Coverage

  @doc "**A8** — Bierce's entries and how many of his headwords the index knew."
  defdelegate bierce(scope_slug), to: Coverage

  @doc "**R1** — WordNet edges resolved at absorb."
  defdelegate wordnet_edges(), to: Coverage

  @doc "**X3** — forms and spelling variants land on the right word."
  defdelegate variants(), to: Coverage

  @doc "**X1** — a random sample of the index renders. See `Health.Pages.word_pages/1`."
  defdelegate word_pages(sample \\ 200), to: Pages

  @doc "**U2** — the flagship words. See `Health.Pages.flagships/0`."
  defdelegate flagships(), to: Pages

  @doc "**U6** — every card links out. See `Health.Pages.cards_link_out/0`."
  defdelegate cards_link_out(), to: Pages

  @doc "**U3** — provenance everywhere. See `Health.Pages.cards_provenance/0`."
  defdelegate cards_provenance(), to: Pages

  @doc "**R3** — chains render. See `Health.Pages.chains/0`."
  defdelegate chains(), to: Pages

  @doc """
  The per-source record ledger — fetched, absent, needs-materialization,
  needs-fetch, changed, last run — which `mix dd.health` prints and
  `/admin/imports` renders from the same call.
  """
  defdelegate records(scope_slug), to: Coverage

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
  def concept_coverage(scope_slug) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    # Every QID a link or a relation names, and how many of those have no row.
    %{rows: [[referenced, dangling]]} =
      Repo.query!(
        """
        WITH refs AS (
          SELECT r.object_object_id AS id
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
           WHERE r.is_current
             AND p.key IN ('refers_to', 'lexeme_entity_candidate',
                           'parent_taxon', 'subclass_of', 'instance_of', 'taxon_item')
          UNION
          SELECT r.subject_object_id
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
           WHERE r.is_current
             AND p.key IN ('parent_taxon', 'subclass_of', 'instance_of', 'taxon_item')
        )
        SELECT count(*),
               count(*) FILTER (WHERE e.object_id IS NULL)
          FROM refs LEFT JOIN entities e ON e.object_id = refs.id
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

    with_sitelink = Repo.aggregate(sitelinked(), :count)

    asserted = asserted_concepts()
    asserted_answered = asserted_concepts_answered(source)

    answered =
      Repo.one!(
        from e in sitelinked(), where: ^answered_clause(source), select: count(e.object_id)
      )

    with_entry =
      Repo.one!(from e in sitelinked(), where: ^has_article(), select: count(e.object_id))

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
  # `concept_links.status IN ('auto','confirmed')` is now "an asserted link the
  # reviewers have not rejected", which is what it always meant;
  # `Encyclopedia.linked_lexemes_query/1` is the one definition of it.
  defp sitelinked do
    from e in Entity,
      as: :entity,
      where: not is_nil(fragment("? ->> 'wikipedia_title'", e.metadata))
  end

  defp has_article do
    dynamic(
      [e],
      fragment(
        """
        EXISTS (
          SELECT 1 FROM assertion_revisions ar
            JOIN predicates ap ON ap.id = ar.predicate_id
           WHERE ar.object_object_id = ? AND ar.is_current
             AND ar.lifecycle_state = 'active' AND ap.key = 'about'
        )
        """,
        e.object_id
      )
    )
  end

  # Answered means "we asked": an article, or a record — including the absent
  # marker a disambiguation page leaves, which is answered by its candidate list
  # and deliberately gets no article.
  defp answered_clause(source) do
    dynamic(
      [e],
      ^has_article() or
        fragment(
          """
          EXISTS (
            SELECT 1 FROM source_records r
              JOIN external_identifiers x
                ON x.object_id = ? AND x.namespace = 'wikidata' AND x.status = 'verified'
             WHERE r.source_id = ? AND r.external_id = 'concept:' || x.external_id
          )
          """,
          e.object_id,
          ^source.id
        )
    )
  end

  # `exists(subquery)` with `parent_as`, not an interpolated fragment: Ecto
  # refuses a runtime string as a fragment's first argument, and it is right to
  # — the composable form is also the one that keeps a single definition of
  # what an asserted link is.
  defp asserted_entity do
    from lk in subquery(Encyclopedia.linked_lexemes_query()),
      where: lk.entity_id == parent_as(:entity).object_id,
      select: 1
  end

  defp asserted_concepts do
    Repo.one!(
      from e in sitelinked(), where: exists(asserted_entity()), select: count(e.object_id)
    )
  end

  defp asserted_concepts_answered(source) do
    Repo.one!(
      from e in sitelinked(),
        where: exists(asserted_entity()),
        where: ^answered_clause(source),
        select: count(e.object_id)
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
  def images(scope_slug) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    %{rows: [[asserted, asserted_with_image, lexemes, lexemes_with_image]]} =
      Repo.query!(
        """
        WITH linked AS (#{Encyclopedia.linked_lexemes_sql()}),
        asserted AS (
          SELECT DISTINCT linked.entity_id AS id
            FROM linked
            JOIN scope_lexeme_members sl
              ON sl.lexeme_id = linked.lexeme_id AND sl.scope_id = $1
        ),
        per_lexeme AS (
          SELECT sl.lexeme_id,
                 bool_or(e.metadata ->> 'image_url' IS NOT NULL) AS has_image
            FROM scope_lexeme_members sl
            JOIN linked ON linked.lexeme_id = sl.lexeme_id
            JOIN entities e ON e.object_id = linked.entity_id
           WHERE sl.scope_id = $1
           GROUP BY 1
        )
        SELECT (SELECT count(*) FROM asserted),
               (SELECT count(*) FROM asserted JOIN entities e ON e.object_id = asserted.id
                 WHERE e.metadata ->> 'image_url' IS NOT NULL),
               (SELECT count(*) FROM per_lexeme),
               (SELECT count(*) FROM per_lexeme WHERE has_image)
        """,
        [scope.id],
        timeout: :infinity
      )

    with_entry = from e in Entity, where: ^has_article()

    entries = Repo.aggregate(with_entry, :count)

    entries_with_image =
      with_entry
      |> where([e], not is_nil(fragment("? ->> 'image_url'", e.metadata)))
      |> Repo.aggregate(:count)

    all = Repo.aggregate(Entity, :count)

    all_with_image =
      from(e in Entity, where: not is_nil(fragment("? ->> 'image_url'", e.metadata)))
      |> Repo.aggregate(:count)

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
  def links(scope_slug, threshold \\ 0.8) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)
    total = Repo.aggregate(scope_query(scope), :count)

    linked = scope_with_link(scope, threshold)
    strict = scope_with_link(scope, threshold, strict: true)
    any = scope_with_link(scope, 0.0)
    reachable = scope_with_article(scope)

    histogram =
      Repo.all(
        from link in subquery(Encyclopedia.linked_lexemes_query()),
          join: r in AssertionRevision,
          on: r.id == link.revision_id,
          join: sl in ScopeMember,
          on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
          group_by: [r.method, r.confidence],
          order_by: [asc: r.method, desc: r.confidence],
          select: {r.method, r.confidence, count(r.id)}
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
  def conflicts(scope_slug, threshold \\ 0.7, limit \\ 20) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    rows =
      Repo.all(
        from link in subquery(Encyclopedia.linked_lexemes_query(min_confidence: 0.0)),
          join: l in Lexeme,
          on: l.object_id == link.lexeme_id,
          join: sl in ScopeMember,
          on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
          where: link.confidence >= ^threshold,
          group_by: [link.lexeme_id, l.lemma, l.part_of_speech],
          having: count(fragment("DISTINCT ?", link.entity_id)) > 1,
          order_by: [desc: count(fragment("DISTINCT ?", link.entity_id))],
          select: %{
            lemma: l.lemma,
            pos: l.part_of_speech,
            concepts: count(fragment("DISTINCT ?", link.entity_id))
          }
      )

    %{count: length(rows), sample: Enum.take(rows, limit)}
  end

  @doc """
  **L3** — how many linked concepts sit on a `parent_taxon` path to the scope's
  root.

  Walks the stored edges, so it is a check on the absorb as much as on the
  linker: a walk cut off at `--max-depth` shows up here as a soft number.

  The population is links we **assert** (`auto` or `confirmed`). A
  `:candidate` from a "may refer to" page is a possibility, not a claim — an
  Animals scope carries about 19,000 of them, and *BYD Seal* was never going to
  reach Animalia. The figure including candidates is reported beside it.

  The root is the scope's own `rules["wikidata_root"]`, not Animalia. A scope
  without one has no taxonomy to reach — *emotions* is not under Q729 and never
  will be — and gets `%{root: nil}`, which the scorecard reports rather than
  grades. Measuring the second scope against the first scope's root is how L3
  came to read 0 % and call it a failure.
  """
  def taxonomy(scope_slug, root \\ nil) do
    scope = Lexicon.get_scope_by_slug!(scope_slug)
    root = root || scope.rules["wikidata_root"]

    if root, do: taxonomy_to_root(scope, root), else: %{root: nil}
  end

  defp taxonomy_to_root(scope, root) do
    %{rows: [[linked, reaching, all_linked, all_reaching]]} =
      Repo.query!(
        """
        WITH RECURSIVE descendants(id) AS (
          SELECT x.object_id FROM external_identifiers x
           WHERE x.namespace = 'wikidata' AND x.external_id = $2 AND x.status = 'verified'
          UNION
          SELECT r.subject_object_id
            FROM assertion_revisions r
            JOIN predicates p ON p.id = r.predicate_id
            JOIN descendants d ON r.object_object_id = d.id
           WHERE p.key = 'parent_taxon' AND r.is_current AND r.lifecycle_state = 'active'
        ),
        asserted_link AS (#{Encyclopedia.linked_lexemes_sql()}),
        -- The second population L3 reports beside the first: every link that is
        -- not rejected, including the 0.40 candidates a "may refer to" page
        -- named. *BYD Seal* was never going to reach Animalia, so grading on it
        -- would grade Wikipedia's disambiguation pages rather than the linker.
        any_link AS (#{Encyclopedia.linked_lexemes_sql(0.0)}),
        linked AS (
          SELECT DISTINCT el.entity_id AS id
            FROM asserted_link el
            JOIN scope_lexeme_members sl
              ON sl.lexeme_id = el.lexeme_id AND sl.scope_id = $1
        ),
        all_linked AS (
          SELECT DISTINCT el.entity_id AS id
            FROM any_link el
            JOIN scope_lexeme_members sl
              ON sl.lexeme_id = el.lexeme_id AND sl.scope_id = $1
        ),
        reaching AS (
          SELECT e.object_id AS id
            FROM entities e
           WHERE e.object_id IN (SELECT id FROM descendants)
              OR EXISTS (
                   SELECT 1 FROM assertion_revisions tr
                     JOIN predicates tp ON tp.id = tr.predicate_id
                    WHERE tr.subject_object_id = e.object_id AND tp.key = 'taxon_item'
                      AND tr.is_current AND tr.lifecycle_state = 'active'
                      AND tr.object_object_id IN (SELECT id FROM descendants)
                 )
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
      root: root,
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
  def disambiguation(scope_slug) do
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
            """
            EXISTS (
              SELECT 1 FROM assertion_revisions ar
                JOIN predicates ap ON ap.id = ar.predicate_id
               WHERE ar.subject_object_id = ? AND ar.is_current
                 AND ap.key = 'lexeme_entity_candidate' AND ar.method = 'disambiguation'
            )
            """,
            l.object_id
          )
        )
      )

    candidates =
      Repo.one!(
        from link in subquery(
               Encyclopedia.linked_lexemes_query(visibility: :internal, min_confidence: 0.0)
             ),
             join: r in AssertionRevision,
             on: r.id == link.revision_id,
             join: sl in ScopeMember,
             on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
             where: r.method == "disambiguation",
             select: count(r.id)
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
            "NOT EXISTS (SELECT 1 FROM lexemes n JOIN scope_lexeme_members s2 ON s2.lexeme_id = n.object_id AND s2.scope_id = ? WHERE n.lemma = ? AND n.part_of_speech = ANY(?))",
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
          from link in subquery(
                 Encyclopedia.linked_lexemes_query(visibility: :internal, min_confidence: 0.0)
               ),
               join: r in AssertionRevision,
               on: r.id == link.revision_id,
               join: sl in ScopeMember,
               on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
               where: r.method == "disambiguation" and r.confidence > 0.4,
               select: count(r.id)
        )
    }
  end

  # ── S2 helpers ───────────────────────────────────────────────────────────

  defp scope_query(scope) do
    from sl in ScopeMember,
      join: l in Lexeme,
      as: :lexeme,
      on: l.object_id == sl.lexeme_id,
      where: sl.scope_id == ^scope.id
  end

  # "This word is linked to some thing", as one correlated subquery the five
  # callers below share. `Encyclopedia.linked_lexemes_query/1` is the single
  # definition of what an asserted link is, so none of them spells the rule
  # again — which is the property the browse page and L1 depend on.
  defp linked_to_word(opts \\ []) do
    # `min_confidence: 0.0` on the base, then this function's own floor: L1
    # counts the same population at several thresholds, including zero, so it
    # must widen the shared rule explicitly rather than inherit its default.
    from(lk in subquery(Encyclopedia.linked_lexemes_query(min_confidence: 0.0)),
      where: lk.lexeme_id == parent_as(:lexeme).object_id,
      select: 1
    )
    |> then(fn q ->
      case opts[:min_confidence] do
        nil -> q
        min -> where(q, [lk], lk.confidence >= ^min)
      end
    end)
    |> then(fn q ->
      if opts[:strict], do: where(q, [lk], not lk.corroborated), else: q
    end)
  end

  defp scope_attested(scope, source_slug) do
    source = Sources.get_source_by_slug!(source_slug)

    scope_query(scope)
    |> where([_sl, l], fragment("? = ANY(?)", ^source.id, l.source_ids))
    |> Repo.aggregate(:count)
  end

  defp scope_with_concept(scope) do
    scope_query(scope)
    |> where(exists(linked_to_word()))
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
        join: sl in ScopeMember,
        on: sl.lexeme_id == l.object_id and sl.scope_id == ^scope.id,
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
        select: count(l.object_id)
    )
  end

  # A5's denominator plus Wikidata's reach: a scope lexeme is covered when
  # Wiktionary attests it *or* a concept link names it.
  # A6's union: the scope lemmas Wiktionary attests **or** something is linked
  # to. Written as two sets rather than `A OR EXISTS (…)`, because the `OR`
  # stops Postgres using a semi-join for the EXISTS and makes it re-run the
  # subquery once per scope member — 154 s on Animals' 25,383, against 176 ms
  # for the same set as a union. Both halves still read the link rule from
  # `linked_to_word/1`, so there is still one definition of what a link is.
  defp union_covered(scope) do
    source = Sources.get_source_by_slug!("wiktionary")

    attested =
      scope_query(scope)
      |> where([_sl, l], fragment("? = ANY(?)", ^source.id, l.source_ids))
      |> select([_sl, l], %{object_id: l.object_id})

    linked =
      scope_query(scope)
      |> where(exists(linked_to_word()))
      |> select([_sl, l], %{object_id: l.object_id})

    Repo.aggregate(subquery(union(attested, ^linked)), :count)
  end

  defp scope_with_link(scope, threshold, opts \\ []) do
    # The strict population is a narrower alternative, not an extra condition
    # layered on top of the ordinary population. Building both correlated
    # EXISTS branches repeated the complete public-visibility query and could
    # push a small-scope scorecard past the connection checkout timeout.
    link = linked_to_word(min_confidence: threshold, strict: opts[:strict] || false)

    scope_query(scope)
    |> where(exists(link))
    |> Repo.aggregate(:count)
  end

  defp corroboration_counts(scope) do
    Repo.all(
      from link in subquery(Encyclopedia.linked_lexemes_query()),
        join: r in AssertionRevision,
        on: r.id == link.revision_id,
        join: sl in ScopeMember,
        on: sl.lexeme_id == link.lexeme_id and sl.scope_id == ^scope.id,
        where: fragment("jsonb_exists(?, 'corroboration')", r.metadata),
        group_by: fragment("? ->> 'corroboration'", r.metadata),
        select: {fragment("? ->> 'corroboration'", r.metadata), count(r.id)}
    )
    |> Map.new()
  end

  defp pct(_part, 0), do: 0.0
  defp pct(part, total), do: Float.round(part * 100 / total, 1)
end
