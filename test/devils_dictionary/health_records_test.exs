defmodule DevilsDictionary.HealthRecordsTest do
  @moduledoc """
  The record ledger behind `/admin/imports` and the `RECORDS` section of
  `mix dd.health` — one function, so the page and the task cannot drift.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.WordFixtures, except: [record!: 2, record!: 3]

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Claims, Health, Repo}
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp record!(source, external_id, attrs \\ []) do
    now = DateTime.utc_now()

    Repo.insert!(
      struct(
        %SourceRecord{
          source_id: source.id,
          external_id: external_id,
          raw: %{},
          content_hash: external_id,
          fetched_at: now,
          materialized_at: now
        },
        attrs
      )
    )
  end

  defp ledger(rows, slug), do: Enum.find(rows, &(&1.slug == slug))

  test "records, absent markers, stale materializations and changes, per source", ctx do
    wordnet = ctx.sources["wordnet"]
    now = DateTime.utc_now()

    record!(wordnet, "oewn-1-n")
    record!(wordnet, "oewn-2-n", changed_at: now)
    record!(wordnet, "oewn-3-n", materialized_at: nil)
    record!(wordnet, "oewn-4-n", materialized_at: DateTime.add(now, -60, :second))
    record!(wordnet, "oewn-5-n", absent_until: DateTime.add(now, 3600, :second))

    row = ledger(Health.records("animals"), "wordnet")

    assert row.records == 5
    assert row.absent == 1
    assert row.changed == 1
    # nil and "older than the fetch" are both #69 §5's needs-materialization.
    assert row.needs_materialization == 2
  end

  test "a source with no records at all still gets a row", ctx do
    row = ledger(Health.records("animals"), "bierce")

    assert row.records == 0
    assert row.last_run == nil
    assert row.access == :static
    assert ctx.sources["bierce"].tier == :aristocracy
  end

  describe "needs_fetch" do
    test "is nil for a dump or a book, because the file is the answer", ctx do
      rows = Health.records("animals")

      for slug <- ~w(wordnet wiktionary bierce) do
        assert ledger(rows, slug).needs_fetch == nil
        assert ledger(rows, slug).needs_fetch_of == nil
      end

      assert ctx.sources["wordnet"].access == :dump
    end

    test "counts the scope lemmas Wikipedia has not answered", ctx do
      wikipedia = ctx.sources["wikipedia"]

      for lemma <- ~w(cat dog oyster), do: word!(ctx, lemma)

      assert ledger(Health.records("animals"), "wikipedia").needs_fetch == 3

      # A real record answers it; so does an absent marker still in date.
      record!(wikipedia, "cat")
      record!(wikipedia, "dog", absent_until: DateTime.add(DateTime.utc_now(), 3600, :second))
      # An expired marker does not: it is due for a retry.
      record!(wikipedia, "oyster", absent_until: DateTime.add(DateTime.utc_now(), -1, :second))

      row = ledger(Health.records("animals"), "wikipedia")
      assert row.needs_fetch == 1
      assert row.needs_fetch_of == "scope lemmas"
    end

    test "counts asserted concepts Wikidata has not answered, not every concept", ctx do
      wikidata = ctx.sources["wikidata"]

      asserted = concept!("Q146", "cat")
      candidate = concept!("Q1", "CAT scan")
      lexeme = word!(ctx, "cat")

      {:ok, _} =
        Claims.assert(lexeme.object_id, "lexeme_entity_candidate", asserted.object_id, %{
          method: "title_match",
          confidence: 0.9
        })

      # Below `Encyclopedia.asserted_floor/0`: a possibility, not a claim, and
      # chasing every one of them is what grew the table to 90,481 rows.
      {:ok, _} =
        Claims.assert(lexeme.object_id, "lexeme_entity_candidate", candidate.object_id, %{
          method: "disambiguation",
          confidence: 0.4
        })

      row = ledger(Health.records("animals"), "wikidata")
      assert row.needs_fetch == 1
      assert row.needs_fetch_of == "asserted entities"

      record!(wikidata, "Q146")
      assert ledger(Health.records("animals"), "wikidata").needs_fetch == 0
    end
  end

  describe "source_detail/2" do
    test "the row, its pin, its ledger and its coverage of the scope", ctx do
      record!(ctx.sources["bierce"], "CAT/n")

      detail = Health.source_detail("bierce", scope: "animals")

      assert detail.source.slug == "bierce"
      assert detail.snapshot == "gutenberg_id=972"
      assert detail.ledger.records == 1
      assert detail.coverage.source == "bierce"
      assert detail.materialized.entries == 0
      assert detail.runs == []
    end

    # #77 §2: no population selected is a state, not a cue to answer for
    # Animals. Everything the source owns still answers; only the claim about a
    # population is withheld.
    test "without a scope it answers for the source and makes no coverage claim", ctx do
      record!(ctx.sources["bierce"], "CAT/n")

      detail = Health.source_detail("bierce")

      assert detail.source.slug == "bierce"
      assert detail.snapshot == "gutenberg_id=972"
      assert detail.ledger.records == 1
      assert detail.materialized.entries == 0
      refute detail.coverage
    end

    # Wikipedia's needs-fetch population *is* the scope's lemmas, so with no
    # population it is not applicable rather than zero. Wikidata's was never
    # scoped and still answers.
    test "the ledger withholds only the figure that needs a population" do
      [wikipedia] = Enum.filter(Health.records(nil), &(&1.slug == "wikipedia"))
      [wikidata] = Enum.filter(Health.records(nil), &(&1.slug == "wikidata"))

      assert wikipedia.needs_fetch_of == "scope lemmas"
      refute wikipedia.needs_fetch
      assert wikidata.needs_fetch_of == "asserted entities"
      assert is_integer(wikidata.needs_fetch)
    end
  end
end
