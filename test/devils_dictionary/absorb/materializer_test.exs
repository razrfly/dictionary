defmodule DevilsDictionary.Absorb.MaterializerTest do
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Claims.{AssertionRevision, PendingRelation}
  alias DevilsDictionary.Registry.{ContentItem, Lexeme, Sense}
  alias DevilsDictionary.{Claims, FakeSource, Fixtures, Registry, Repo, Sources}
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  setup do
    Claims.Catalog.seed!()
    :ok
  end

  defp source!(slug \\ "fake") do
    Repo.insert!(%Source{
      slug: slug,
      name: "Fake #{slug}",
      tier: :middle,
      kind: :dictionary,
      access: :dump
    })
  end

  # Identity and payload are two tables: the record, then the revision that
  # carries what the source said. `raw` is virtual and filled from it.
  defp record!(source, raw) do
    external_id = raw["lemma"] <> "/" <> to_string(raw["pos"] || "noun")
    Sources.insert_records(source, [%{external_id: external_id, raw: raw}])

    Repo.one!(
      from r in SourceRecord,
        where: r.source_id == ^source.id and r.external_id == ^external_id
    )
    |> Sources.with_raw()
  end

  defp counts do
    %{
      lexemes: Repo.aggregate(Lexeme, :count),
      senses: Repo.aggregate(Sense, :count),
      relations: Repo.aggregate(AssertionRevision, :count),
      pending: Repo.aggregate(PendingRelation, :count),
      content: Repo.aggregate(ContentItem, :count)
    }
  end

  describe "run/2" do
    test "writes the rows a source materialized and stamps the record" do
      source = source!()
      record = record!(source, %{"lemma" => "monkey", "gloss" => "a primate"})

      assert {:ok, stats} = Materializer.run(record, FakeSource)
      assert stats.lexemes == 1
      assert stats.senses == 1
      # The fake source's edge names a word nothing has introduced, so it is
      # held rather than asserted — see the `to_lemma` test below.
      assert stats.relations == 0
      assert stats.relations_pending == 1

      lexeme = Repo.get_by!(Lexeme, lemma: "monkey")
      assert lexeme.slug == "monkey"
      assert lexeme.part_of_speech == "noun"

      sense = Repo.get_by!(Sense, external_key: "fake-monkey")
      assert Registry.current_sense_revision(sense.object_id).gloss == "a primate"
      assert sense.lexeme_id == lexeme.object_id

      # The sense cites a *revision* of the record, which is what makes "what did
      # this rest on" answerable after the source rewords its entry.
      assert Repo.one!(
               from r in DevilsDictionary.Registry.SenseRevision,
                 where: r.sense_id == ^sense.object_id and r.is_current,
                 select: r.source_record_revision_id
             )

      assert Repo.get!(SourceRecord, record.id).materialized_at
    end

    test "caches the attesting source on the lexeme" do
      source = source!()
      record = record!(source, %{"lemma" => "otter"})

      {:ok, _} = Materializer.run(record, FakeSource)

      assert Repo.get_by!(Lexeme, lemma: "otter").source_ids == [source.id]
    end

    test "marks a lexeme enriched once a source has said something about it" do
      source = source!()
      record = record!(source, %{"lemma" => "heron"})

      {:ok, _} = Materializer.run(record, FakeSource)

      assert Repo.get_by!(Lexeme, lemma: "heron").enriched_at
    end

    test "keeps to_lemma on a relation whose target we have never seen" do
      source = source!()
      record = record!(source, %{"lemma" => "gannet", "to_lemma" => "seabird"})

      {:ok, _} = Materializer.run(record, FakeSource)

      # An edge with no target word is not an assertion with a missing end — both
      # endpoints are real objects and NOT NULL. It waits in `pending_relations`
      # with its evidence, which is where #69 §4's "to_lemma is kept forever"
      # lives now, and where R2 counts it.
      pending = Repo.one!(from p in PendingRelation, preload: [:predicate])
      assert pending.to_lemma == "seabird"
      assert pending.predicate.key == "hypernym"
    end

    test "bounds an origin_key a source's relation target would overrun" do
      source = source!()

      # `origin_key` is varchar(255) and is built by interpolating strings the
      # source chose. Wiktionary's `coordinate_terms` can name a whole series in
      # a single target — "A-shaped - B-shaped - … - Z-shaped" is 315 bytes of
      # key — which no test scope ever held, so the first unscoped absorb aborted
      # the entire materialize transaction with a 22001 (#79 W1).
      long = Enum.map_join(?A..?Z, " - ", &"#{<<&1>>}-shaped")
      assert byte_size(long) > 255

      record = record!(source, %{"lemma" => "a-shaped", "to_lemma" => long})

      {:ok, _} = Materializer.run(record, FakeSource)

      pending = Repo.one!(from(p in PendingRelation))

      # The target itself is `text` and is kept whole; only the key is bounded.
      assert pending.to_lemma == long
      assert byte_size(pending.origin_key) <= 255

      # Truncation alone would collide two long targets sharing a prefix and
      # break the upsert, so the tail is a digest of the whole key.
      assert pending.origin_key =~ ~r/~[0-9a-f]{16}$/

      # And it has to be *stable*, or a re-import writes a second row for the
      # same edge instead of upserting onto the first.
      key = pending.origin_key

      {:ok, _} =
        Materializer.run(Repo.get!(SourceRecord, record.id) |> Sources.with_raw(), FakeSource)

      assert Repo.one!(from(p in PendingRelation)).origin_key == key
    end
  end

  describe "idempotence (scorecard M2)" do
    test "running the same record twice changes no counts" do
      source = source!()
      record = record!(source, %{"lemma" => "badger"})

      {:ok, _} = Materializer.run(record, FakeSource)
      before = counts()

      {:ok, _} = Materializer.run(Repo.get!(SourceRecord, record.id) |> with_raw(), FakeSource)

      # Not merely the same row counts: the same *revision* counts. Identical
      # input produces zero new semantic revisions, which is what M2 measures.
      assert counts() == before
    end

    test "a non-empty examples object is not mistaken for an empty list" do
      source = source!()

      record =
        record!(source, %{
          "lemma" => "map-example",
          "examples" => %{"note" => "must trigger a later revision"}
        })

      {:ok, _} = Materializer.run(record, FakeSource)
      sense = Repo.get_by!(Sense, external_key: "fake-map-example")
      assert Registry.current_sense_revision(sense.object_id).revision_number == 1

      replacement = record!(source, %{"lemma" => "map-example", "examples" => []})
      {:ok, _} = Materializer.run(replacement, FakeSource)

      current = Registry.current_sense_revision(sense.object_id)
      assert current.revision_number == 2
      assert current.examples == []
    end

    test "a second source attesting the same word adds to source_ids, not rows" do
      first = source!("fake-a")
      second = source!("fake-b")

      {:ok, _} = Materializer.run(record!(first, %{"lemma" => "vole"}), FakeSource)
      {:ok, _} = Materializer.run(record!(second, %{"lemma" => "vole"}), FakeSource)

      lexeme = Repo.get_by!(Lexeme, lemma: "vole")
      assert Enum.sort(lexeme.source_ids) == Enum.sort([first.id, second.id])
      assert Repo.aggregate(Lexeme, :count) == 1
      assert Repo.aggregate(Sense, :count) == 2
    end
  end

  describe "atomicity (scorecard M3)" do
    test "a failure inside materialization leaves no rows and no stamp" do
      source = source!()
      record = record!(source, %{"lemma" => "quoll", "mode" => "poison"})

      before = counts()

      assert_raise Postgrex.Error, fn ->
        Materializer.run(record, FakeSource)
      end

      assert counts() == before
      refute Repo.get!(SourceRecord, record.id).materialized_at
      assert Repo.get_by(Lexeme, lemma: "quoll") == nil
    end
  end

  describe "atomicity on a real source (M3)" do
    test "a Bierce entry whose lexeme cannot be written leaves no entry either" do
      source =
        Repo.insert!(%Source{
          slug: "bierce",
          name: "Bierce",
          tier: :aristocracy,
          kind: :dictionary,
          access: :static
        })

      raw = Fixtures.one_raw("bierce", "cat")

      # A headword longer than `content_revisions.headword` allows: the failure
      # lands deep inside the writes, after the content item has been prepared,
      # which is the only place worth testing.
      record = bierce_record!(source, %{raw | "headword" => String.duplicate("CAT", 200)})

      before = counts()

      assert_raise Postgrex.Error, fn ->
        Materializer.run(record, DevilsDictionary.Absorb.Sources.Bierce)
      end

      assert counts() == before
      refute Repo.get!(SourceRecord, record.id).materialized_at
      assert Repo.aggregate(ContentItem, :count) == 0
    end
  end

  describe "entries carry their author (S3)" do
    test "an author named by slug is resolved inside the same transaction" do
      source =
        Repo.insert!(%Source{
          slug: "bierce",
          name: "Bierce",
          tier: :aristocracy,
          kind: :dictionary,
          access: :static
        })

      person = person!(source)
      record = bierce_record!(source)

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Bierce)

      # An author is a claim now: `authored_by` from the definition to the
      # person, which is the same object id his biography would be `about`.
      assert authored_by() == person.object_id
    end

    test "a rebuild keeps the author, because it is resolved on every write" do
      # The entries upsert is `replace_all_except`, so an author stamped outside
      # this transaction would be blanked by the next `--all`. That would fail
      # M2 for this source, silently.
      source =
        Repo.insert!(%Source{
          slug: "bierce",
          name: "Bierce",
          tier: :aristocracy,
          kind: :dictionary,
          access: :static
        })

      person = person!(source)
      record = bierce_record!(source)

      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Bierce)
      {:ok, _} = Materializer.run(record, DevilsDictionary.Absorb.Sources.Bierce)

      assert authored_by() == person.object_id
      assert Repo.aggregate(ContentItem, :count) == 1
    end
  end

  describe "enriched_at" do
    test "only the lexemes a batch actually said something about are marked enriched" do
      source = source!("fake")

      # One record declares two lexemes but only says something about one of
      # them — the shape a scoped Wiktionary batch produces. Marking the silent
      # one enriched would inflate A3 and put an empty card on its page.
      spoken = record!(source, %{"lemma" => "cat", "gloss" => "a cat", "also_lexeme" => "feline"})

      {:ok, _} = Materializer.run_batch([with_raw(spoken)], FakeSource)

      cat = Repo.get_by!(Lexeme, lemma: "cat")
      feline = Repo.get_by!(Lexeme, lemma: "feline")

      assert cat.enriched_at
      refute feline.enriched_at
    end
  end

  describe "run_batch/2" do
    test "dedupes a lexeme that several records introduce" do
      source = source!()

      records = [
        record!(source, %{"lemma" => "shrew", "pos" => "noun"}),
        record!(source, %{"lemma" => "shrew", "pos" => "verb"})
      ]

      assert {:ok, stats} = Materializer.run_batch(records, FakeSource)
      assert stats.lexemes == 2
      assert Repo.aggregate(Lexeme, :count) == 2

      assert Enum.map(records, &Repo.get!(SourceRecord, &1.id).materialized_at)
             |> Enum.all?(& &1)
    end
  end

  # `raw` is virtual, so a reloaded record needs it filled from its revision.
  defp with_raw(%SourceRecord{} = record), do: Sources.with_raw(record)

  # A person is an entity plus `person_details`, named by the catalog slug an
  # adapter emits — the same object id that would carry his biography.
  defp person!(_source) do
    {:ok, person} =
      Registry.create_person(%{entity_kind: :person, preferred_label: "Ambrose Bierce"})

    {:ok, _} = Registry.add_name(person.object_id, "ambrose-bierce", name_kind: "catalog_slug")
    person
  end

  defp bierce_record!(source, raw \\ nil) do
    Sources.insert_records(source, [
      %{external_id: "CAT/n", raw: raw || Fixtures.one_raw("bierce", "cat")}
    ])

    Repo.one!(from r in SourceRecord, where: r.source_id == ^source.id) |> Sources.with_raw()
  end

  defp authored_by do
    Repo.one(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: p.key == "authored_by" and r.is_current,
        select: r.object_object_id
    )
  end
end
