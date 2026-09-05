defmodule DevilsDictionary.Absorb.MaterializerTest do
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.FakeSource
  alias DevilsDictionary.Lexicon.{Lexeme, LexicalRelation, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Source, SourceRecord}

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
