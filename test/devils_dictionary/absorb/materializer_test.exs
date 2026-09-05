defmodule DevilsDictionary.Absorb.MaterializerTest do
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.{FakeSource, Fixtures}
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, LexicalRelation, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Person, Source, SourceRecord}

  defp source!(slug \\ "fake") do
    Repo.insert!(%Source{
      slug: slug,
      name: "Fake #{slug}",
      tier: :middle,
      kind: :dictionary,
      access: :dump
    })
  end

  defp record!(source, raw) do
    Repo.insert!(%SourceRecord{
      source_id: source.id,
      external_id: raw["lemma"] <> "/" <> to_string(raw["pos"] || "noun"),
      raw: raw,
      fetched_at: DateTime.utc_now()
    })
  end

  defp counts do
    %{
      lexemes: Repo.aggregate(Lexeme, :count),
      senses: Repo.aggregate(Sense, :count),
      relations: Repo.aggregate(LexicalRelation, :count)
    }
  end

  describe "run/2" do
    test "writes the rows a source materialized and stamps the record" do
      source = source!()
      record = record!(source, %{"lemma" => "monkey", "gloss" => "a primate"})

      assert {:ok, stats} = Materializer.run(record, FakeSource)
      assert stats.lexemes == 1
      assert stats.senses == 1
      assert stats.relations == 1

      lexeme = Repo.get_by!(Lexeme, lemma: "monkey")
      assert lexeme.slug == "monkey"
      assert lexeme.pos == "noun"

      sense = Repo.get_by!(Sense, external_id: "fake-monkey")
      assert sense.gloss == "a primate"
      assert sense.lexeme_id == lexeme.id
      assert sense.source_record_id == record.id

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

      relation = Repo.one!(LexicalRelation)
      assert relation.to_lemma == "seabird"
      assert relation.to_lexeme_id == nil
      assert relation.type == :hypernym
    end
  end

  describe "idempotence (scorecard M2)" do
    test "running the same record twice changes no counts" do
      source = source!()
      record = record!(source, %{"lemma" => "badger"})

      {:ok, _} = Materializer.run(record, FakeSource)
      before = counts()

      {:ok, _} = Materializer.run(Repo.get!(SourceRecord, record.id) |> with_raw(), FakeSource)

      assert counts() == before
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

      record =
        Repo.insert!(%SourceRecord{
          source_id: source.id,
          external_id: "CAT/n",
          # A lemma longer than the column allows: the failure lands deep inside
          # the writes, after the entry row has been prepared, which is the only
          # place worth testing.
          raw: %{raw | "headword" => String.duplicate("CAT", 200)},
          fetched_at: DateTime.utc_now()
        })

      before = counts()

      assert_raise Postgrex.Error, fn ->
        Materializer.run(with_raw(record), DevilsDictionary.Absorb.Sources.Bierce)
      end

      assert counts() == before
      refute Repo.get!(SourceRecord, record.id).materialized_at
      assert Repo.aggregate(Entry, :count) == 0
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

      person =
        Repo.insert!(%Person{
          name: "Ambrose Bierce",
          slug: "ambrose-bierce",
          source_id: source.id
        })

      record =
        Repo.insert!(%SourceRecord{
          source_id: source.id,
          external_id: "CAT/n",
          raw: Fixtures.one_raw("bierce", "cat"),
          fetched_at: DateTime.utc_now()
        })

      {:ok, _} = Materializer.run(with_raw(record), DevilsDictionary.Absorb.Sources.Bierce)

      assert Repo.one(from e in Entry, select: e.author_id) == person.id
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

      person = Repo.insert!(%Person{name: "Ambrose Bierce", slug: "ambrose-bierce"})

      record =
        Repo.insert!(%SourceRecord{
          source_id: source.id,
          external_id: "CAT/n",
          raw: Fixtures.one_raw("bierce", "cat"),
          fetched_at: DateTime.utc_now()
        })

      {:ok, _} = Materializer.run(with_raw(record), DevilsDictionary.Absorb.Sources.Bierce)
      {:ok, _} = Materializer.run(with_raw(record), DevilsDictionary.Absorb.Sources.Bierce)

      assert Repo.one(from e in Entry, select: e.author_id) == person.id
      assert Repo.aggregate(Entry, :count) == 1
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

  # `raw` is load_in_query: false, so a reloaded record needs it fetched back.
  defp with_raw(%SourceRecord{id: id} = record) do
    %{record | raw: Repo.one!(from r in SourceRecord, where: r.id == ^id, select: r.raw)}
  end
end
