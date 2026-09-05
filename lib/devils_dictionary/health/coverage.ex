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

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Catalog, ImportRun, Source}

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
