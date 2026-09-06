defmodule DevilsDictionary.Absorb.ConceptsTest do
  @moduledoc """
  The encyclopedia half of the `Materializer`: concept merging, the taxon
  bridge, and taxonomy edges whose target is in another batch.

  Uses the two real sources rather than a fake one, because the thing under
  test is exactly that Wikipedia and Wikidata describe one concept from
  different sides and neither may blank the other.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.{Wikidata, Wikipedia}
  alias DevilsDictionary.Encyclopedia.{Concept, ConceptRelation}
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  # Deliberately *not* the real slugs. `Catalog.seed!/0` upserts `wikipedia` and
  # `wikidata` from other async tests, and two transactions touching those rows
  # in different orders deadlock. Neither module reads the slug — they work off
  # `record.source_id` — so a throwaway name is free.
  defp source!(slug, kind) do
    Repo.insert!(%Source{
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      name: slug,
      tier: :middle,
      kind: kind,
      access: :api
    })
  end

  defp record!(source, external_id, raw) do
    Repo.insert!(%SourceRecord{
      source_id: source.id,
      external_id: external_id,
      raw: raw,
      fetched_at: DateTime.utc_now()
    })
  end

  defp wikipedia_record!(lemma) do
    source = source!("wikipedia", :encyclopedia)
    raw = Wikipedia.trim(Fixtures.one_raw("wikipedia", lemma))
    {record!(source, lemma, raw), source}
  end

  defp wikidata_record!(lemma, qid) do
    source = source!("wikidata", :knowledge_graph)
    raw = Fixtures.raw("wikidata", lemma) |> Enum.find(&(&1["id"] == qid)) |> Wikidata.trim()
    {record!(source, qid, raw), source}
  end

  defp concept(qid), do: Repo.get_by!(Concept, qid: qid)

  describe "two sources on one concept" do
    test "Wikipedia then Wikidata composes, and neither blanks the other" do
      {wp, _} = wikipedia_record!("cat")
      {wd, _} = wikidata_record!("cat", "Q146")

      assert {:ok, _} = Materializer.run(wp, Wikipedia)
      assert {:ok, _} = Materializer.run(wd, Wikidata)

      cat = concept("Q146")
      assert cat.wikipedia_title == "Cat"
      assert cat.wikipedia_pageid == 6678
      assert cat.wordnet_ili == "i46593"
      # Wikidata's P18 file, not Wikipedia's article thumbnail. Both now live on
      # upload.wikimedia.org — a Special:FilePath URL will not render as an
      # image — so the file name is what tells them apart.
      assert cat.image_url =~ "Cat_grooming.jpg"
    end

    test "and in the other order, which is the one that used to clobber" do
      {wd, _} = wikidata_record!("cat", "Q146")
      {wp, _} = wikipedia_record!("cat")

      assert {:ok, _} = Materializer.run(wd, Wikidata)
      assert {:ok, _} = Materializer.run(wp, Wikipedia)

      cat = concept("Q146")
      assert cat.wikipedia_pageid == 6678
      # Wikipedia knows nothing about the ILI and must not erase it.
      assert cat.wordnet_ili == "i46593"
    end

    test "a taxon's kind survives a later Wikipedia write" do
      {wd, _} = wikidata_record!("cat", "Q20980826")
      assert {:ok, _} = Materializer.run(wd, Wikidata)
      assert concept("Q20980826").kind == :taxon

      # `\"thing\"` is the no-opinion value, so a source that does not know about
      # taxa can never demote one.
      felis = concept("Q20980826")

      Repo.insert!(%Concept{qid: "Q20980826"},
        on_conflict: {:replace, [:updated_at]},
        conflict_target: [:qid]
      )

      assert Repo.get!(Concept, felis.id).kind == :taxon
    end
  end

  describe "concept-to-concept references across batches" do
    test "a parent named before it exists is picked up on the second pass" do
      {wd, source} = wikidata_record!("cat", "Q20980826")

      assert {:ok, %{concept_relations: 0, concept_relations_offered: offered}} =
               Materializer.run(wd, Wikidata)

      assert offered > 0
      assert Repo.aggregate(ConceptRelation, :count) == 0

      # The parents arrive in a later tier; re-materializing then closes the
      # edges. This is why `Wikidata.absorb/2` runs `Batch.run` twice.
      parent = record!(source, "Q228283", %{"id" => "Q228283", "claims" => %{}})
      assert {:ok, _} = Materializer.run(parent, Wikidata)
      assert {:ok, %{concept_relations: written}} = Materializer.run(wd, Wikidata)

      assert written > 0
      assert Repo.exists?(from r in ConceptRelation, where: r.type == :parent_taxon)
    end

    test "taxon_concept_id links the everyday concept to its taxon item" do
      {wd, source} = wikidata_record!("cat", "Q146")
      taxon = Fixtures.raw("wikidata", "cat") |> Enum.find(&(&1["id"] == "Q20980826"))
      taxon_record = record!(source, "Q20980826", Wikidata.trim(taxon))

      assert {:ok, _} = Materializer.run(taxon_record, Wikidata)
      assert {:ok, _} = Materializer.run(wd, Wikidata)

      assert concept("Q146").taxon_concept_id == concept("Q20980826").id
    end
  end

  describe "Wikipedia's lexeme annotation" do
    test "the probed lexemes get the title and are not marked enriched" do
      lexeme =
        Repo.insert!(%Lexeme{lang: "en", lemma: "cat", pos: "noun", slug: "cat"})

      {wp, _} = wikipedia_record!("cat")
      assert {:ok, _} = Materializer.run(wp, Wikipedia)

      lexeme = Repo.get!(Lexeme, lexeme.id)
      assert lexeme.metadata["wikipedia_title"] == "Cat"

      # Wikipedia's entry hangs off the concept, not the word, so it must not
      # make a bare index row look enriched (the S1 bug, in a new place).
      assert is_nil(lexeme.enriched_at)
    end
  end
end
