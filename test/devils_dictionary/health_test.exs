defmodule DevilsDictionary.HealthTest do
  @moduledoc """
  The S1 scorecard rows, each against a small hand-built graph so the expected
  number is obvious by inspection.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.{Health, Lexicon, Repo, Sources}
  alias DevilsDictionary.Lexicon.ScopeMember
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.Sense
  alias DevilsDictionary.WordFixtures
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  defp lexeme!(lemma, source_ids) do
    {:ok, lexeme} =
      Registry.create_lexeme(%{
        language_tag: "en",
        lemma: lemma,
        part_of_speech: "noun",
        source_ids: source_ids
      })

    lexeme
  end

  defp scoped!(scope, lexeme, reasons \\ ["wordnet_closure"]) do
    Repo.insert!(%ScopeMember{
      scope_id: scope.id,
      lexeme_id: lexeme.object_id,
      reasons: reasons
    })
  end

  defp revision_id(record) do
    Repo.one!(
      from r in DevilsDictionary.Corpus.SourceRecordRevision,
        where: r.source_record_id == ^record.id,
        select: r.id
    )
  end

  defp sense!(lexeme, source, attrs) do
    {:ok, sense} =
      Registry.create_sense(
        Map.merge(
          %{lexeme_id: lexeme.object_id, source_id: source.id},
          Map.new(attrs)
        )
      )

    sense
  end

  describe "coverage/2 (A5)" do
    test "counts the scope lexemes a source attests, and buckets the misses", ctx do
      wordnet = ctx.sources["wordnet"].id
      wiktionary = ctx.sources["wiktionary"].id

      scoped!(ctx.animals, lexeme!("cat", [wordnet, wiktionary]))
      scoped!(ctx.animals, lexeme!("dog", [wordnet, wiktionary]))
      scoped!(ctx.animals, lexeme!("Cimex lectularius", [wordnet]))
      scoped!(ctx.animals, lexeme!("dusky-footed wood rat", [wordnet]))
      scoped!(ctx.animals, lexeme!("soupfin", [wordnet]))

      # A genus is a scientific name too (A5 v2): the shape says nothing, the
      # concept's `taxon.scientific_name` does.
      scoped!(ctx.animals, lexeme!("Cimex", [wordnet]))

      {:ok, _} =
        Registry.create_entity(%{
          entity_kind: :taxon,
          preferred_label: "Cimex",
          metadata: %{"taxon" => %{"scientific_name" => "Cimex", "rank" => "genus"}}
        })

      result = Health.coverage("animals", "wiktionary")

      assert result.total == 6
      assert result.covered == 2
      assert result.pct == 33.3
      assert result.missing == 4

      assert result.missing_by_kind == %{
               "scientific_name" => 2,
               "multiword" => 1,
               "single_word" => 1
             }
    end

    test "a fully covered scope is 100%", ctx do
      scoped!(ctx.animals, lexeme!("cat", [ctx.sources["wiktionary"].id]))

      assert Health.coverage("animals", "wiktionary").pct == 100.0
    end
  end

  describe "links_back/0 (A9)" do
    test "a sense with its own url counts as linked", ctx do
      source = ctx.sources["wordnet"]
      lexeme = lexeme!("cat", [source.id])

      sense!(lexeme, source,
        external_key: "oewn-1-n#cat",
        gloss: "a cat",
        url: "https://en-word.net/id/oewn-1-n"
      )

      assert %{senses: %{total: 1, linked: 1}, pct: 100.0} = Health.links_back()
    end

    test "a sense with no url of its own falls back to its record, then the template",
         ctx do
      source = ctx.sources["wordnet"]
      lexeme = lexeme!("cat", [source.id])

      record =
        WordFixtures.record!(ctx, "wordnet",
          external_id: "oewn-1-n",
          url: "https://en-word.net/id/oewn-1-n"
        )

      sense!(lexeme, source,
        external_key: "oewn-1-n#cat",
        gloss: "a cat",
        source_record_revision_id: revision_id(record)
      )

      # Every seeded source has a url_template, so even a bare sense links back;
      # that is exactly what A9 allows as the last resort.
      assert Health.links_back().pct == 100.0
    end
  end

  describe "resolution/1 (R2)" do
    test "reports nothing rather than dividing by zero on an empty source", _ctx do
      assert %{total: 0, resolved: 0, pct: +0.0} = Health.resolution("wiktionary")
    end
  end

  describe "trim_saving/1 (M4)" do
    test "says so plainly when no scoped absorb has run", _ctx do
      assert %{measured: false} = Health.trim_saving("wiktionary")
    end

    test "reads the figures back from the absorb's import run", ctx do
      source = ctx.sources["wiktionary"]

      Sources.start_run("absorb", source_id: source.id)
      |> Sources.finish_run(%{
        "bytes_raw" => 1000,
        "bytes_trimmed" => 190,
        "trim_saving_pct" => 81.0,
        "records" => 3
      })

      assert %{measured: true, saving_pct: 81.0, records: 3} = Health.trim_saving("wiktionary")
    end
  end

  describe "parity/1 (M1)" do
    test "a materialized record has no gaps", ctx do
      source = ctx.sources["wordnet"]
      raw = Fixtures.one_raw("wordnet", "oyster")

      Sources.insert_records(source, [%{external_id: raw["id"], url: "https://x", raw: raw}])

      record =
        Repo.one!(from r in SourceRecord, where: r.source_id == ^source.id)
        |> Sources.with_raw()

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Wordnet)

      assert %{gaps: 0, stale: 0, missing_senses: 0, missing_relations: 0} =
               Health.parity("wordnet")
    end

    test "a record that was never materialized is a gap", ctx do
      source = ctx.sources["wordnet"]
      raw = Fixtures.one_raw("wordnet", "oyster")

      Sources.insert_records(source, [%{external_id: raw["id"], url: "https://x", raw: raw}])

      result = Health.parity("wordnet")

      assert result.records == 1
      assert result.stale == 1
      assert result.gaps == 1
      assert result.missing_senses > 0
    end

    test "a record materialized after it was fetched is not stale", ctx do
      # A DateTime is a struct, and `<` on structs is Erlang term order, which
      # compares `day` before `month` before `year`. A record fetched on the
      # 30th and materialized on the 2nd of the next month must still be fresh.
      source = ctx.sources["wordnet"]
      raw = Fixtures.one_raw("wordnet", "oyster")

      Sources.insert_records(source, [%{external_id: raw["id"], url: "https://x", raw: raw}])

      record =
        Repo.one!(from r in SourceRecord, where: r.source_id == ^source.id)
        |> Sources.with_raw()

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Wordnet)

      Repo.update_all(
        from(r in SourceRecord, where: r.id == ^record.id),
        set: [
          fetched_at: ~U[2026-01-30 10:00:00.000000Z],
          materialized_at: ~U[2026-02-02 10:00:00.000000Z]
        ]
      )

      assert Health.parity("wordnet").stale == 0
    end

    test "a sense cannot be deleted behind the materializer's back at all", ctx do
      source = ctx.sources["wordnet"]
      raw = Fixtures.one_raw("wordnet", "oyster")

      Sources.insert_records(source, [%{external_id: raw["id"], url: "https://x", raw: raw}])

      record =
        Repo.one!(from r in SourceRecord, where: r.source_id == ^source.id)
        |> Sources.with_raw()

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Wordnet)

      # MVP-0 tested that deleting the senses showed up as a gap. In this model
      # the deletion itself is refused: an identity is retired, never deleted
      # out from under the claims that point at it, and the Gate 0 spike found
      # the subtype-delete gap the hard way. So the stronger assertion replaces
      # the weaker one.
      #
      # The guard is a DEFERRABLE constraint trigger, so it fires at COMMIT —
      # which inside the test sandbox never arrives. `SET CONSTRAINTS ALL
      # IMMEDIATE` is how a test reaches the moment the database would check.
      Repo.delete_all(Sense)

      assert {:error, message} = at_commit()
      assert message =~ "object" or message =~ "subtype"
    end

    defp at_commit do
      case Repo.query("SET CONSTRAINTS ALL IMMEDIATE") do
        {:ok, _} -> :ok
        {:error, e} -> {:error, Exception.message(e)}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    test "M1 verifies the selected publication and reports conflicting retained observations",
         ctx do
      source = ctx.sources["wikipedia"]

      raw =
        Fixtures.one_raw("wikipedia", "cat") |> DevilsDictionary.Absorb.Sources.Wikipedia.trim()

      Sources.insert_records(source, [
        %{external_id: "Z-cat", raw: raw},
        %{external_id: "a-cat", raw: Map.put(raw, "extract", "An alternate archived extract.")}
      ])

      DevilsDictionary.Absorb.Batch.run(DevilsDictionary.Absorb.Sources.Wikipedia, source,
        batch_size: 1
      )

      parity = Health.parity("wikipedia")
      assert parity.gaps == 0
      assert parity.alternate_content_observations == 1

      Repo.update_all(from(r in "content_revisions", where: r.is_current),
        set: [body: "CORRUPTED"]
      )

      assert Health.parity("wikipedia").mismatched > 0
    end

    test "M1 fails on the corruption probe (the audit's finding)", ctx do
      source = ctx.sources["wordnet"]
      raw = Fixtures.one_raw("wordnet", "oyster")

      Sources.insert_records(source, [%{external_id: raw["id"], url: "https://x", raw: raw}])

      record =
        Repo.one!(from r in SourceRecord, where: r.source_id == ^source.id)
        |> Sources.with_raw()

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Wordnet)
      assert Health.parity("wordnet").gaps == 0

      # Every gloss replaced with a string that is not the gloss. The MVP-0
      # check returned zero gaps for exactly this, because every natural key was
      # still present. Semantic parity has to see it.
      Repo.update_all(
        from(r in "sense_revisions", where: r.is_current),
        set: [gloss: "CORRUPTED"]
      )

      result = Health.parity("wordnet")

      assert result.mismatched > 0
      assert result.gaps == 1
      assert [{external_id, detail}] = result.examples
      assert external_id == raw["id"]
      assert detail[:senses] != []
    end
  end

  describe "Lexicon totals still line up" do
    test "count_lexemes/1 sees what coverage counted", ctx do
      scoped!(ctx.animals, lexeme!("cat", [ctx.sources["wiktionary"].id]))

      assert Lexicon.count_lexemes("en") == 1
    end
  end
end
