defmodule DevilsDictionary.Health.Coverage do
  @moduledoc """
  The absorb rows of #69 §7 — **A1** (every source absorbed), **A2** (WordNet is
  full), **A3** (the Wiktionary index is full), **A4** (the scope is built with
  reasons) and **A8** (Bierce is full and attached).

  S1 and S2 added the rows they were judged on to `Health` directly; these are
  the ones nothing had a home for, and they compose counters that already exist
  in `Lexicon` rather than writing new queries for numbers the tasks have
  already printed once.
  """

  import Ecto.Query

  alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink, ConceptRelation}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, ScopeLexeme, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Catalog, ImportRun, Source, SourceRecord}

  @doc """
  **A1** — every source in the catalog has a row and a finished absorb.

  Counts **`done`** runs only. `import_runs` also holds failed dev retries and
  one run stopped on purpose, and a row that counted those would say a source
  had been absorbed when it had not.
  """
  def sources do
    expected = Catalog.sources()

    rows =
      for spec <- expected do
        source = Sources.get_source_by_slug(spec.slug)

        %{
          slug: spec.slug,
          present: not is_nil(source),
          runs: source && done_runs(source.id),
          last_done: source && last_done_at(source.id),
          snapshot: source && snapshot_pin(source)
        }
      end

    absorbed = Enum.count(rows, &(&1.present and (&1.runs || 0) > 0))
    pinned = Enum.count(rows, &(&1.snapshot not in [nil, false]))

    %{
      expected: length(expected),
      present: Enum.count(rows, & &1.present),
      absorbed: absorbed,
      pinned: pinned,
      sources: rows
    }
  end

  defp done_runs(source_id) do
    Repo.aggregate(
      from(r in ImportRun, where: r.source_id == ^source_id and r.status == :done),
      :count
    )
  end

  defp last_done_at(source_id) do
    Repo.one(
      from r in ImportRun,
        where: r.source_id == ^source_id and r.status == :done,
        order_by: [desc: r.finished_at],
        limit: 1,
        select: r.finished_at
    )
  end

  # What pins this source in time (#69 decision 8: pinned snapshots, re-absorbed
  # by hand). A dump pins the file it was cut from and a book its edition, both
  # on the source row. An API has no such file — what pins it is the day we
  # asked, which is exactly what its last finished run records.
  @pins ~w(dump_date snapshot_date gutenberg_id)

  defp snapshot_pin(%Source{access: :api} = source) do
    case last_done_at(source.id) do
      nil -> nil
      at -> "fetched=#{at |> DateTime.to_date() |> Date.to_iso8601()}"
    end
  end

  defp snapshot_pin(%Source{config: config}) do
    Enum.find_value(@pins, fn key -> config[key] && "#{key}=#{config[key]}" end)
  end

  @doc """
  The record ledger the import dashboard shows: per source, how many
  `source_records` we hold, how many of those are "the source had nothing"
  markers, how many still need materializing, and how many changed on a refetch.

  `mix dd.health` and `/admin/imports` both read this one function, so the two
  can never disagree — which is what the task's moduledoc has promised since S3.

  `needs_fetch` is `nil` for a dump or a book, and deliberately so: everything
  in the file is either fetched or not in it, and a zero there would read as an
  answer rather than as "the question does not apply". For the two API sources it
  is #69 §5's "needs fetch" terminal state — no record, and no absent marker
  still in date — over the population that is actually wanted, which
  `needs_fetch_of` names:

    * **Wikipedia**: the scope's lemmas, one title probe each.
    * **Wikidata**: the concepts reached by an **asserted** link (`auto` or
      `confirmed`), the same population A10 and L3 report on. Counting every
      concept instead would read 27,742, but ~28,000 of the concepts are
      disambiguation candidates the S3 audit already noted will mostly never be
      asserted; of the ones that are, four are unfetched. A dashboard column
      that says 27,742 when the outstanding work is four is a worse number.
  """
  def records(scope_slug \\ "animals") do
    ledger = record_counts()
    runs = last_runs()

    for source <- Sources.list_sources() do
      counts = Map.get(ledger, source.id, %{records: 0, absent: 0, needs_mat: 0, changed: 0})

      %{
        slug: source.slug,
        name: source.name,
        access: source.access,
        tier: source.tier,
        records: counts.records,
        absent: counts.absent,
        needs_materialization: counts.needs_mat,
        changed: counts.changed,
        needs_fetch: needs_fetch(source, scope_slug),
        needs_fetch_of: needs_fetch_of(source),
        last_run: Map.get(runs, source.id)
      }
    end
  end

  # One grouped aggregate over all 271k records rather than four counts per
  # source. Measured at 40 ms, which is why the dashboard needs no cache.
  defp record_counts do
    from(r in SourceRecord,
      group_by: r.source_id,
      select: {
        r.source_id,
        %{
          records: count(r.id),
          absent: filter(count(r.id), not is_nil(r.absent_until)),
          needs_mat:
            filter(
              count(r.id),
              is_nil(r.materialized_at) or r.materialized_at < r.fetched_at
            ),
          changed: filter(count(r.id), not is_nil(r.changed_at))
        }
      }
    )
    |> Repo.all()
    |> Map.new()
  end

  defp last_runs do
    from(r in ImportRun,
      distinct: r.source_id,
      order_by: [asc: r.source_id, desc: r.started_at],
      select: {r.source_id, %{task: r.task, status: r.status, at: r.started_at, id: r.id}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Wikipedia's targets are the scope's lemmas; Wikidata's are the QIDs a link or
  # a relation already referenced. The left join is on the records that *answer*
  # the question — any real record, or an absent marker that has not expired —
  # so what is left is #69 §5's "needs fetch" terminal state exactly.
  defp needs_fetch(%Source{slug: "wikipedia", id: id}, scope_slug) do
    now = DateTime.utc_now()

    case Lexicon.get_scope_by_slug(scope_slug) do
      nil ->
        nil

      scope ->
        Repo.one(
          from l in Lexeme,
            join: sl in ScopeLexeme,
            on: sl.lexeme_id == l.id and sl.scope_id == ^scope.id,
            left_join: r in SourceRecord,
            on:
              r.source_id == ^id and r.external_id == l.lemma and
                (is_nil(r.absent_until) or r.absent_until > ^now),
            where: is_nil(r.id),
            select: count(fragment("DISTINCT ?", l.lemma))
        )
    end
  end

  defp needs_fetch(%Source{slug: "wikidata", id: id}, _scope_slug) do
    now = DateTime.utc_now()

    Repo.one(
      from c in Concept,
        join: cl in ConceptLink,
        on: cl.concept_id == c.id and cl.status in [:auto, :confirmed],
        left_join: r in SourceRecord,
        on:
          r.source_id == ^id and r.external_id == c.qid and
            (is_nil(r.absent_until) or r.absent_until > ^now),
        where: is_nil(r.id),
        select: count(c.id, :distinct)
    )
  end

  defp needs_fetch(%Source{}, _scope_slug), do: nil

  defp needs_fetch_of(%Source{slug: "wikipedia"}), do: "scope lemmas"
  defp needs_fetch_of(%Source{slug: "wikidata"}), do: "asserted concepts"
  defp needs_fetch_of(%Source{}), do: nil

  @doc """
  Everything `/sources/:slug` shows about one source: the row itself, what pins
  it in time, its record ledger, what it has materialized, how much of a scope it
  attests, its recent runs, and a few real rows to look at.

  The coverage figure is `Health.coverage/2`'s, unchanged, so the source page and
  the scorecard's A5 cannot disagree.
  """
  def source_detail(slug, opts \\ []) do
    source = Sources.get_source_by_slug!(slug)
    scope_slug = Keyword.get(opts, :scope, "animals")
    sample_limit = Keyword.get(opts, :samples, 5)

    %{
      source: source,
      snapshot: snapshot_pin(source),
      ledger: Enum.find(records(scope_slug), &(&1.slug == slug)),
      materialized: materialized_counts(source),
      coverage: scope_slug && DevilsDictionary.Health.coverage(scope_slug, slug),
      runs: recent_runs(source.id),
      senses: sample_senses(source, sample_limit),
      entries: sample_entries(source, sample_limit)
    }
  end

  defp materialized_counts(%Source{id: id}) do
    %{
      senses: Repo.aggregate(from(x in Sense, where: x.source_id == ^id), :count),
      entries: Repo.aggregate(from(e in Entry, where: e.source_id == ^id), :count),
      relations: Repo.aggregate(from(r in LexicalRelation, where: r.source_id == ^id), :count),
      concept_relations:
        Repo.aggregate(from(r in ConceptRelation, where: r.source_id == ^id), :count),
      concept_links: Repo.aggregate(from(cl in ConceptLink, where: cl.source_id == ^id), :count),
      lexemes_introduced:
        Repo.aggregate(from(l in Lexeme, where: l.origin_source_id == ^id), :count)
    }
  end

  defp recent_runs(source_id, limit \\ 10) do
    Repo.all(
      from r in ImportRun,
        where: r.source_id == ^source_id,
        order_by: [desc: r.started_at],
        limit: ^limit
    )
  end

  # Real rows, not fixtures: a source page that showed invented samples would be
  # the one page in the app that lies about what was absorbed.
  defp sample_senses(%Source{id: id}, limit) do
    Repo.all(
      from x in Sense,
        join: l in Lexeme,
        on: l.id == x.lexeme_id,
        where: x.source_id == ^id and not is_nil(x.gloss),
        order_by: [asc: x.id],
        limit: ^limit,
        select: %{lemma: l.lemma, pos: l.pos, slug: l.slug, gloss: x.gloss, url: x.url}
    )
  end

  defp sample_entries(%Source{id: id}, limit) do
    Repo.all(
      from e in Entry,
        where: e.source_id == ^id,
        order_by: [asc: e.id],
        limit: ^limit,
        select: %{headword: e.headword, pos: e.pos, body: e.body, url: e.url, year: e.year}
    )
  end

  @doc """
  **A2** — WordNet is the plus edition: synset groups and distinct lexemes with
  senses. The base edition holds 107,519 synsets and fails this row, which is
  why it is measured rather than assumed.
  """
  def wordnet do
    source = Sources.get_source_by_slug!("wordnet")

    %{
      synsets: Lexicon.count_sense_groups(source.id),
      lexemes: Lexicon.count_lexemes_with_senses(source.id),
      wants_synsets: 120_000,
      wants_lexemes: 155_000
    }
  end

  @doc """
  **A3** — the full English index: every Wiktionary headword is a lexeme row.
  The count of rows carrying `forms` is *report*, not a threshold; it is what
  makes `monkeys` land on *monkey* without a record of its own.
  """
  def index(lang \\ "en") do
    total = Lexicon.count_lexemes(lang)

    with_forms =
      Repo.aggregate(
        from(l in Lexeme, where: l.lang == ^lang and fragment("? <> '[]'::jsonb", l.forms)),
        :count
      )

    enriched =
      Repo.aggregate(
        from(l in Lexeme, where: l.lang == ^lang and not is_nil(l.enriched_at)),
        :count
      )

    %{total: total, with_forms: with_forms, enriched: enriched, wants: 1_200_000}
  end

  @doc """
  **A4** — the scope exists, every member records why it is in, and the counts
  per reason are the finding.
  """
  def scope(scope_slug \\ "animals") do
    scope = Lexicon.get_scope_by_slug!(scope_slug)

    %{
      scope: scope_slug,
      total: Lexicon.count_scope_lexemes(scope),
      without_reason: Lexicon.count_scope_lexemes_without_reason(scope),
      by_reason: Lexicon.scope_reason_counts(scope),
      wants: 7_500
    }
  end

  @doc """
  **A8** — Bierce is full, and every entry hangs off a word.

  Two numbers, because only one of them carries information. *Attached* is
  100 % by construction: `materialize/1` creates the lexeme when the index
  lacks it, so an entry without one cannot exist. What is worth knowing is the
  **index hit rate** — how many of Bierce's headwords were words some other
  source had already attested, which is measured by `origin_source_id`, since
  the materializer's lexeme merge keeps the first writer.
  """
  def bierce(scope_slug \\ "animals") do
    source = Sources.get_source_by_slug!("bierce")

    entries = from e in Entry, where: e.source_id == ^source.id

    total = Repo.aggregate(entries, :count)
    attached = Repo.aggregate(from(e in entries, where: not is_nil(e.lexeme_id)), :count)

    known =
      Repo.aggregate(
        from(e in entries,
          join: l in Lexeme,
          on: l.id == e.lexeme_id,
          where: is_nil(l.origin_source_id) or l.origin_source_id != ^source.id
        ),
        :count
      )

    in_scope =
      Repo.aggregate(
        from(e in entries,
          join: sl in "scope_lexemes",
          on: sl.lexeme_id == e.lexeme_id,
          join: s in "scopes",
          on: s.id == sl.scope_id and s.slug == ^scope_slug
        ),
        :count
      )

    %{
      entries: total,
      attached: attached,
      attached_pct: pct(attached, total),
      known_to_the_index: known,
      index_hit_pct: pct(known, total),
      introduced_by_bierce: total - known,
      in_scope: in_scope,
      authored: Repo.aggregate(from(e in entries, where: not is_nil(e.author_id)), :count),
      wants_entries: 997
    }
  end

  @doc """
  **R1** — WordNet's edges are resolved at absorb, not by `dd.resolve`: it is a
  closed graph, so every target is a synset we already hold. Must be 100 %.
  """
  def wordnet_edges do
    source = Sources.get_source_by_slug!("wordnet")

    relations = from r in LexicalRelation, where: r.source_id == ^source.id

    total = Repo.aggregate(relations, :count)
    resolved = Repo.aggregate(from(r in relations, where: not is_nil(r.to_sense_id)), :count)

    %{total: total, resolved: resolved, pct: pct(resolved, total)}
  end

  @doc """
  **X3** — an inflected form and a spelling variant land on the word they
  belong to.

  Probes rather than counts, because that is how #69 §7 words the row: it names
  `/define/monkeys` and a known variant. Each probe reports what
  `Lexicon.lookup/1` actually returned, so a regression names itself.
  """
  @variant_probes [
    {"monkeys", "monkey", "an inflected form"},
    {"cats", "cat", "an inflected form"},
    {"geese", "goose", "an irregular plural"},
    {"spat", "spat", "a form that is also a headword keeps its own page"}
  ]

  def variants do
    probes =
      for {input, expected, why} <- @variant_probes do
        landed = input |> Lexicon.lookup() |> landing()
        %{input: input, expected: expected, landed: landed, ok: landed == expected, why: why}
      end

    %{probes: probes, passed: Enum.count(probes, & &1.ok), total: length(probes)}
  end

  defp landing(%{lexemes: [%Lexeme{lemma: lemma} | _]}), do: String.downcase(lemma)
  defp landing(_), do: nil

  defp pct(_part, 0), do: 0.0
  defp pct(part, total), do: Float.round(part * 100 / total, 1)
end
